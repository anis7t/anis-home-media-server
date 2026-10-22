import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../domain/intro_frame.dart';
import '../../domain/intro_score.dart';
import '../../domain/intro_timeline.dart';
import '../../infrastructure/intro_video_player.dart';
import '../controllers/intro_score_controller.dart';
import '../painters/intro_fx_painter.dart';
import '../painters/intro_veil_painter.dart';
import 'brand_mark.dart';

/// The brand opening sequence - the Flutter overlay.
///
/// A port of the canonical overlay (`web/src/components/brand/BrandIntroOverlay.tsx`
/// and `brand-intro.css`), which is pixel-identical to the archived original
/// (`docs/opening-sequence/source/intro-overlay.html`). The canonical
/// specification is `docs/OPENING_SEQUENCE.md` Part I.
///
/// ## The layer stack
///
/// The canonical z-order is `veilL/veilR (z2) -> seam (z3) -> FX canvas (z4)
/// -> vignette (z5) -> grain (z6) -> lockup (z7)`. **The FX canvas is ABOVE the
/// curtain** - the previous Flutter implementation put it at the bottom of
/// the stack, where the opaque curtain hid the whole 0.12 - 1.95 s build-up.
/// In a Flutter `Stack` the first child is at the bottom, so the order below
/// is the reverse of the z-order.
///
/// ## The stage paints nothing
///
/// The stage is transparent and carries an **opaque** curtain over the live
/// app. The app is revealed by the two halves **sliding apart** - never by
/// removing an opaque panel, which would make the outro a flash.
class BrandIntroOverlay extends StatefulWidget {
  const BrandIntroOverlay({
    super.key,
    required this.onFinished,
    this.score = const SilentIntroScore(),
    this.autoFinishOnError = true,
    this.videoAssetPath,
  });

  /// Called once, when the sequence has finished.
  final VoidCallback onFinished;

  /// The score.
  ///
  /// It is a parameter rather than something the overlay looks up, so that the
  /// widget's tests can hand it a fake and never touch an audio platform. The
  /// default is silent, which is also what a device with no audio gets.
  final IntroScore score;

  /// Retained for API compatibility.
  final bool autoFinishOnError;

  /// The asset to play the sequence from, instead of painting it.
  ///
  /// When it is null the sequence is **painted** - the canonical's renderer,
  /// ported to Flutter, which is what the phone does. When it is set the
  /// sequence is **played** from a pre-rendered video, which is what the
  /// television does: its GPU cannot paint the sequence at an interactive
  /// frame rate, because it compiles each new draw program at runtime and has
  /// no Vulkan for Impeller.
  ///
  /// The video is rendered from the canonical itself, so the picture is the
  /// canonical's either way. See [IntroVideoPlayer].
  final String? videoAssetPath;

  @override
  State<BrandIntroOverlay> createState() => BrandIntroOverlayState();
}

class BrandIntroOverlayState extends State<BrandIntroOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _finished = false;
  bool _handover = false;

  /// Whether the score has been started.
  ///
  /// It starts with the controller's first tick, which is the first frame
  /// after the sequence's first frame has been presented - see the note at the
  /// start of the sequence.
  bool _scoreStarted = false;


  /// The measured geometry the FX are drawn from.
  Offset? _iconOrigin;
  Rect? _lockupRect;

  /// A frame held for the comparison oracle, if one has been requested.
  double? _manualTime;

  late final IntroScoreController _score;

  final GlobalKey _stageKey = GlobalKey();
  final GlobalKey iconKey = GlobalKey();
  final GlobalKey _lockupKey = GlobalKey();

  /// The word column's key.
  ///
  /// The comparison oracle needs it: a Flutter widget test renders text with
  /// the Ahem test font, whose glyphs are solid squares, so the wordmarks
  /// cannot be compared as pictures - and the column's rectangle is what says
  /// where they are.
  final GlobalKey wordColumnKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );
    _ctrl.addListener(_onTick);

    final videoPath = widget.videoAssetPath;
    if (videoPath != null) {
      // The VIDEO rendering. The sequence is played, not painted, and the
      // clock is the video's own playback position - so the score is anchored
      // to the picture exactly as it is in the painted rendering.
      final video = _openVideo(videoPath);
      if (video != null) {
        _video = video;
        _score = IntroScoreController(
          score: widget.score,
          elapsedAt: () => _video?.position ?? Duration.zero,
          duration: const Duration(milliseconds: 3000),
        );
        return;
      }
      // The video could not be created: fall through to the painted sequence,
      // which is slower on a television but is better than a black screen.
    }

    _score = IntroScoreController(
      score: widget.score,
      elapsedAt: () => Duration(milliseconds: (_ctrl.value * kIntroDuration * 1000).round()),
      duration: const Duration(milliseconds: 3000),
    );
    // The score starts with the sequence, and NOTHING waits for it: the
    // animation is already running.
    //
    // THE SEQUENCE'S CLOCK STARTS WHEN THE SEQUENCE IS ON SCREEN, not when the
    // widget tree is built.
    //
    // A `Ticker` measures its elapsed time from its FIRST TICK, and the first
    // tick is the first frame after the one that is being built. The engine
    // does not begin a new frame until the previous one has been rastered, so
    // on a slow start the first frame is presented long after it was built -
    // and the SECOND frame's tick then carries that whole gap in one step.
    // The controller would jump straight to two seconds in, the viewer would
    // see the sequence start in its middle, and the last second would race
    // through. That is the "rushed" sequence.
    //
    // So the controller is not started until the first frame has been built.
    // Its first tick is then the first frame after the first presentation, and
    // the sequence's zero is the frame the viewer sees first.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ctrl.forward();
    });
  }

  /// The video rendering's player.
  IntroVideoPlayer? _video;

  /// Creates the player and starts the video.
  ///
  /// It returns null when the video cannot be created or played, and the
  /// caller then falls back to the painted sequence - a television that cannot
  /// play the video is slow, but a black screen is worse.
  IntroVideoPlayer? _openVideo(String assetPath) {
    try {
      final video = IntroVideoPlayer();
      unawaited(_startVideo(video, assetPath));
      return video;
    } catch (e) {
      debugPrint('[intro] the video could not be created: $e');
      return null;
    }
  }

  /// Starts the video, and the score beside it.
  Future<void> _startVideo(IntroVideoPlayer video, String assetPath) async {
    try {
      await video.open(assetPath);
    } catch (e) {
      // A television that cannot play the video must still finish the
      // sequence rather than hang on a black screen.
      debugPrint('[intro] the video could not be played: $e');
      if (mounted) _finish();
      return;
    }
    if (!mounted) return;
    // The score starts with the video, and is anchored to the video's own
    // position - so the sound and the picture agree about where the sequence
    // is.
    _scoreStarted = true;
    _score.start();
    final player = video.videoController.player;
    _videoSubscription = player.stream.completed.listen((_) {
      if (mounted) _finish();
    });
    // The handover is the canonical's: from 2.57 s the application underneath
    // is live. The video's own position is the clock, so the handover is
    // driven from it rather than from a timer.
    _positionSubscription = player.stream.position.listen((position) {
      if (!mounted || _handover) return;
      final handoverAt = Duration(milliseconds: (kIntroHandoverAt * 1000).round());
      if (position >= handoverAt) {
        setState(() => _handover = true);
      }
    });
  }

  StreamSubscription<bool>? _videoSubscription;
  StreamSubscription<Duration>? _positionSubscription;

  void _onTick() {
    final t = _ctrl.value * kIntroDuration;
    if (!_scoreStarted) {
      _scoreStarted = true;
      // The score starts with the controller's FIRST TICK, and not with the
      // widget tree: the sound must not be heard before there is anything to
      // see. The score is anchored to the controller's value at the moment it
      // starts, so the sound and the picture agree about where the sequence
      // is - which is the canonical's rule (docs/OPENING_SEQUENCE.md Part I
      // section 7: "The score is anchored, not orphaned").
      _score.start();
    }
    if (t >= kIntroHandoverAt && !_handover) {
      _handover = true;
      // The app underneath is live from here on. The overlay still takes the
      // keyboard, so a remote cannot navigate the app behind the intro.
      setState(() {});
    }
    if (t >= kIntroDuration && !_finished) {
      _finish();
    }
  }

  @override
  void dispose() {
    // The overlay can be removed without ever finishing - the app can be
    // torn down mid-sequence - and the score must not outlive it.
    _score.stop();
    _videoSubscription?.cancel();
    _positionSubscription?.cancel();
    _video?.dispose();
    _ctrl
      ..removeListener(_onTick)
      ..dispose();
    super.dispose();
  }

  /// Render one exact frame, for the comparison oracle.
  ///
  /// It stops the playback and holds the frame, so it is not immediately
  /// overwritten. This is how the Flutter client is compared against the
  /// archived original's own frames.
  void renderAt(double t) {
    _ctrl.stop();
    setState(() {
      _manualTime = t;
    });
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    _ctrl.stop();
    _score.stop();
    widget.onFinished();
  }


  bool _reduced = false;


  /// Measure the mark and the lockup.
  ///
  /// The design unit and the orientation come from the viewport directly, and
  /// are available during the build. Only the two rectangles need the layout
  /// to have happened - and they are measured one frame late on purpose,
  /// because the canonical's canvas is drawn before the DOM is written, so
  /// the FX see the PREVIOUS frame's geometry.
  void _measure() {
    final stageBox = _stageKey.currentContext?.findRenderObject() as RenderBox?;
    final iconBox = iconKey.currentContext?.findRenderObject() as RenderBox?;
    final lockupBox = _lockupKey.currentContext?.findRenderObject() as RenderBox?;

    Rect? toLocal(RenderBox? box) {
      if (box == null || !box.hasSize || stageBox == null) return null;
      final origin = box.localToGlobal(Offset.zero, ancestor: stageBox);
      return origin & box.size;
    }

    // The FX are centred on the mark's MIDDLE, and the middle does not move
    // while the mark scales and rotates - so measuring the middle rather than
    // the rectangle keeps this from rebuilding the tree on every frame of
    // the landing.
    Offset? centreOf(RenderBox? box) {
      final rect = toLocal(box);
      if (rect == null) return null;
      return rect.center;
    }

    final origin = centreOf(iconBox);
    final lockup = toLocal(lockupBox);
    if (origin != _iconOrigin || lockup != _lockupRect) {
      setState(() {
        _iconOrigin = origin;
        _lockupRect = lockup;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    _reduced = MediaQuery.disableAnimationsOf(context);
    final size = MediaQuery.sizeOf(context);
    // The design unit: `min(w, h) / 100` (source 358, 547).
    final u = math.min(size.width, size.height) / 100;
    // The lockup's layout is a BREAKPOINT rule on the stage's aspect - side
    // by side in landscape, stacked in portrait (source 98-100, 355). It is
    // never the device type: a phone in landscape gets the side-by-side
    // layout, and a television in portrait would get the stacked one.
    final portrait = size.height > size.width;

    final video = _video;
    if (video != null) {
      return _IntroVideoStage(
        controller: video.videoController,
        handover: _handover,
        onDismiss: _finish,
      );
    }

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _manualTime ?? _ctrl.value * kIntroDuration;
        final frame = computeIntroFrame(
          t,
          IntroFrameOptions(u: u, reduced: _reduced),
        );
        WidgetsBinding.instance.addPostFrameCallback((_) => _measure());

        return _IntroStage(
          controller: _ctrl,
          wordColumnKey: wordColumnKey,
          frame: frame,
          t: t,
          u: u,
          portrait: portrait,
          handover: _handover,
          stageKey: _stageKey,
          iconKey: iconKey,
          lockupKey: _lockupKey,
          iconOrigin: _iconOrigin,
          lockupRect: _lockupRect,
          onDismiss: _finish,
        );
      },
    );
  }
}

/// The stage of the **video** rendering.
///
/// The video carries the whole sequence - the curtain, the effects and the
/// lockup - so the stage is the video itself, and the only thing this widget
/// adds is the behaviour the canonical's own overlay has: a tap dismisses,
/// the keyboard is absorbed for the whole sequence, and from the handover the
/// application underneath takes the touches.
class _IntroVideoStage extends StatelessWidget {
  const _IntroVideoStage({
    required this.controller,
    required this.handover,
    required this.onDismiss,
  });

  final VideoController controller;
  final bool handover;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        // The keyboard is absorbed for the WHOLE sequence, even after the
        // handover: a D-pad press must not navigate the app behind the
        // sequence. (The web releases both at 2.57 s; on a television that
        // would let the remote drive the app while the sequence is still on
        // screen. See the canonical specification, Part I section 3.1.)
        if (event is KeyDownEvent) {
          onDismiss();
        }
        return KeyEventResult.handled;
      },
      child: IgnorePointer(
        // From the handover the app underneath is live, so the overlay stops
        // taking touches. `IgnorePointer` - rather than a null `onTap` - is
        // what actually stops the touches.
        ignoring: handover,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onDismiss,
          child: SizedBox.expand(
            child: Video(
              controller: controller,
              fit: BoxFit.cover,
              // The sequence's own aspect is the television's; the video is
              // 1920x1080 and the stage is whatever the device is.
              alignment: Alignment.center,
              // The curtain's own colour, so the frame before the first
              // decoded one is the colour the sequence opens on.
              fill: const Color(0xFF05060A),
              // The player controls are the PLAYER's, and this is the
              // sequence: there are no controls, and the canonical exposes
              // no Skip and no Replay anywhere.
              controls: NoVideoControls,
            ),
          ),
        ),
      ),
    );
  }
}

/// The stage and everything on it.
class _IntroStage extends StatelessWidget {
  const _IntroStage({
    required this.controller,
    required this.wordColumnKey,
    required this.frame,
    required this.t,
    required this.u,
    required this.portrait,
    required this.handover,
    required this.stageKey,
    required this.iconKey,
    required this.lockupKey,
    required this.iconOrigin,
    required this.lockupRect,
    required this.onDismiss,
  });

  final AnimationController controller;
  final GlobalKey wordColumnKey;
  final IntroFrame frame;
  final double t;
  final double u;
  final bool portrait;
  final bool handover;
  final Key stageKey;
  final Key iconKey;
  final Key lockupKey;
  final Offset? iconOrigin;
  final Rect? lockupRect;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final stage = Stack(
      fit: StackFit.expand,
      children: [
        // z2 - the curtain: two halves of ONE backdrop.
        _IntroCurtain(
          frame: frame,
          portrait: portrait,
          u: u,
        ),

        // z3 - the seam: warm light spilling through the opening.
        if (frame.seamOpacity > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: frame.seamOpacity,
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: const _IntroSeam(),
                ),
              ),
            ),
          ),

        // z4 - the FX canvas. ABOVE the curtain.
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: IntroFxPainter(
                  t: t,
                  reduced: MediaQuery.disableAnimationsOf(context),
                  geometry: IntroFxGeometry(
                    iconOrigin: iconOrigin,
                    lockupRect: lockupRect,
                  ),
                ),
                size: Size.infinite,
              ),
            ),
          ),
        ),

        // z5 - the vignette, and z6 - the grain. Both take their alpha as a
        // PARAMETER rather than through an `Opacity`, because an `Opacity` is a
        // `saveLayer` with a blend mode - and these two cover the whole stage,
        // so each one is a full-screen offscreen buffer, every frame.
        Positioned.fill(
          child: IgnorePointer(
            child: _IntroVignette(opacity: frame.vignetteOpacity),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: _IntroGrain(opacity: frame.grainOpacity),
          ),
        ),

        // z7 - the lockup, dismissed gently as the curtain opens.
        Positioned.fill(
          child: IgnorePointer(
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..translateByDouble(
                  frame.lockupTranslateXPx,
                  frame.lockupTranslateYPx,
                  0,
                  1,
                )
                ..scaleByDouble(frame.lockupScale, frame.lockupScale, 1, 1),
              child: Opacity(
                opacity: frame.lockupOpacity,
                child: Center(
                  child: _IntroLockup(
                    frame: frame,
                    u: u,
                    portrait: portrait,
                    iconKey: iconKey,
                    lockupKey: lockupKey,
                    wordColumnKey: wordColumnKey,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        // The keyboard is absorbed for the WHOLE sequence, even after the
        // handover: a D-pad press must not navigate the app behind the
        // intro. (The web releases both at 2.57 s; on a television that
        // would let the remote drive the app while the sequence is still on
        // screen. See the canonical specification, Part I section 3.1.)
        if (event is KeyDownEvent) {
          onDismiss();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: IgnorePointer(
        // From the handover the app underneath is live, so the overlay stops
        // taking touches. `IgnorePointer` - rather than a null `onTap` - is
        // what lets them THROUGH, instead of swallowing them on the way to
        // the app.
        ignoring: handover,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onDismiss,
          child: KeyedSubtree(
            key: stageKey,
            child: stage,
          ),
        ),
      ),
    );
  }
}

/// The curtain: two halves of one backdrop.
class _IntroCurtain extends StatelessWidget {
  const _IntroCurtain({
    required this.frame,
    required this.portrait,
    required this.u,
  });

  final IntroFrame frame;
  final bool portrait;
  final double u;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final stageWidth = size.width;
    final half = stageWidth / 2 + 0.5;
    final feather = frame.veilFeatherPct < 100 ? frame.veilFeatherPct : 0;

    Widget buildHalf(bool isLeft) {
      // The image is the stage's width, and it must be centred on the STAGE's
      // centre - not on the half's. The halves are half a stage wide plus a
      // 1 px overlap, and the right half's own origin is a stage-width minus
      // a half-width from the left, so the two offsets are not symmetric.
      // Getting this wrong by a pixel puts a visible seam down the middle.
      final imageLeft = isLeft
          ? stageWidth / 2 - half
          : half - stageWidth / 2;
      return Positioned(
        top: 0,
        bottom: 0,
        left: isLeft ? 0 : null,
        right: isLeft ? null : 0,
        width: half,
        child: Transform.translate(
          offset: Offset(
            (isLeft ? frame.veilLTranslatePct : frame.veilRTranslatePct) /
                100 *
                half,
            0,
          ),
          // The mask is a no-op until the curtain starts parting - the
          // feather is zero before that - and a `ShaderMask` is a `saveLayer`
          // with a blend mode, so applying one to each half of a full-screen
          // curtain for the whole build-up is two offscreen buffers per frame
          // for nothing.
          child: feather <= 0
              ? CustomPaint(
                  painter: IntroVeilPainter(
                    isLeft: isLeft,
                    stageWidth: stageWidth,
                    stageHeight: size.height,
                    imageLeft: imageLeft,
                  ),
                  size: Size(half, size.height),
                )
              : ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) => LinearGradient(
              begin: isLeft ? Alignment.centerLeft : Alignment.centerRight,
              end: isLeft ? Alignment.centerRight : Alignment.centerLeft,
              colors: const [Colors.black, Colors.black, Colors.transparent],
              stops: [0.0, (100 - feather) / 100, 1.0],
            ).createShader(bounds),
            child: CustomPaint(
              painter: IntroVeilPainter(
                isLeft: isLeft,
                stageWidth: stageWidth,
                stageHeight: size.height,
                imageLeft: imageLeft,
              ),
              size: Size(half, size.height),
            ),
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [buildHalf(true), buildHalf(false)],
    );
  }
}

/// The seam: warm light spilling through the opening.
class _IntroSeam extends StatelessWidget {
  const _IntroSeam();

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Center(
      child: SizedBox(
        width: size.width * 0.38,
        height: size.height,
        child: CustomPaint(painter: _SeamPainter(), size: Size.infinite),
      ),
    );
  }
}

class _SeamPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // `radial-gradient(ellipse 46% 78% at 50% 48%, ...)`, squashed into the
    // ellipse the way the curtain's blooms are.
    final rx = size.width * 0.46;
    final ry = size.height * 0.78;
    final centre = Offset(size.width * 0.5, size.height * 0.48);
    final radius = (rx + ry) / 2;
    if (radius <= 0) return;
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(rx / radius, ry / radius);
    canvas.translate(-centre.dx, -centre.dy);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          centre,
          radius,
          const [
            Color(0x9EFFF0F2),
            Color(0x3DFF788C),
            Color(0x00FF788C),
          ],
          const [0.0, 0.4, 0.74],
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// The vignette: the radial darkening at the edges.
class _IntroVignette extends StatelessWidget {
  const _IntroVignette({required this.opacity});

  /// The vignette's alpha, applied to the gradient's colours rather than
  /// through an `Opacity` - see the note at the call site.
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _VignettePainter(opacity: opacity),
      size: Size.infinite,
    );
  }
}

class _VignettePainter extends CustomPainter {
  const _VignettePainter({required this.opacity});

  /// The vignette's alpha, scaled into the gradient's colours.
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final rx = size.width * 0.78;
    final ry = size.height * 0.70;
    final centre = Offset(size.width * 0.5, size.height * 0.5);
    final radius = (rx + ry) / 2;
    if (radius <= 0) return;
    final a = opacity.clamp(0.0, 1.0);
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(rx / radius, ry / radius);
    canvas.translate(-centre.dx, -centre.dy);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          centre,
          radius,
          const [
            Color(0x00000000),
            Color(0x00000000),
            Color(0x8C000000),
            Color(0xD9000000),
          ].map((c) => c.withValues(alpha: c.a * a)).toList(),
          const [0.0, 0.42, 0.82, 1.0],
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// The grain: 5 % film grain over the FX, fading to 0 as the curtain opens.
///
/// The canonical's grain is an SVG `feTurbulence` filter, which Flutter cannot
/// render - there is no SVG filter support. This is a seeded white-noise
/// texture with the same tile size and the same colour matrix (white, with
/// the alpha taken from the noise), so it reads as grain. It is a recorded
/// divergence: the two are the same *kind* of texture, not the same pixels.
class _IntroGrain extends StatelessWidget {
  const _IntroGrain({required this.opacity});

  /// The grain's alpha, applied through a colour filter rather than through an
  /// `Opacity` - see the note at the call site.
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GrainPainter(opacity: opacity),
      size: Size.infinite,
    );
  }
}

class _GrainPainter extends CustomPainter {
  const _GrainPainter({required this.opacity});

  /// The grain's alpha, applied to the tile with a colour filter.
  final double opacity;

  static ui.Image? _tile;

  /// The source's tile is 180x180 (the CSS `background-size`).
  static const int _tileSize = 180;

  static ui.Image _getTile() {
    final cached = _tile;
    if (cached != null) return cached;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final random = mulberry32(0x1f7a3c);
    for (var y = 0; y < _tileSize; y++) {
      for (var x = 0; x < _tileSize; x++) {
        // The source's colour matrix: white, with 0.6 of the red channel as
        // the alpha.
        final v = random();
        canvas.drawRect(
          Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1),
          Paint()..color = Color.fromRGBO(255, 255, 255, 0.6 * v),
        );
      }
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(_tileSize, _tileSize);
    _tile = image;
    return image;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final image = _getTile();
    final a = opacity.clamp(0.0, 1.0);
    final paint = Paint()
      ..shader = ui.ImageShader(
        image,
        TileMode.repeated,
        TileMode.repeated,
        Matrix4.identity().storage,
      )
      // The tile is white with a varying alpha, so scaling the colour scales
      // the alpha - which is what the canonical's 5 % grain does.
      ..colorFilter = ColorFilter.mode(
        Color.fromRGBO(255, 255, 255, a),
        BlendMode.modulate,
      );
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// The lockup: the mark, the wordmarks, the subtitle and the rule.
class _IntroLockup extends StatelessWidget {
  const _IntroLockup({
    required this.frame,
    required this.u,
    required this.portrait,
    required this.iconKey,
    required this.lockupKey,
    required this.wordColumnKey,
  });

  final IntroFrame frame;
  final double u;
  final bool portrait;
  final Key iconKey;
  final Key lockupKey;
  final Key wordColumnKey;

  @override
  Widget build(BuildContext context) {
    final iconSize = (u * 10.5).clamp(64.0, 118.0);
    final fontSize = (u * 5.7).clamp(30.0, 66.0);

    final mark = _IntroMark(
      frame: frame,
      size: iconSize,
      key: iconKey,
    );

    final words = Column(
      key: wordColumnKey,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          portrait ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        _IntroWordmark(
          frame: frame,
          text: kWordmark1,
          word: frame.w1,
          fontSize: fontSize,
          colors: const [Color(0xFFFFFFFF), Color(0xFFCBD5E1)],
        ),
        SizedBox(height: (u * 0.7).clamp(3.0, 7.0)),
        _IntroWordmark(
          frame: frame,
          text: kWordmark2,
          word: frame.w2,
          fontSize: fontSize,
          colors: const [Color(0xFFFF5F70), Color(0xFFE50914)],
        ),
        SizedBox(height: (u * 0.3).clamp(2.0, 4.0)),
        _IntroSubtitle(frame: frame, u: u),
        SizedBox(height: (u * 0.5).clamp(3.0, 6.0)),
        _IntroRule(frame: frame, u: u),
      ],
    );

    return KeyedSubtree(
      key: lockupKey,
      child: portrait
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                mark,
                SizedBox(height: (u * 1.5).clamp(9.0, 20.0)),
                words,
              ],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                mark,
                SizedBox(width: (u * 3).clamp(10.0, 34.0)),
                words,
              ],
            ),
    );
  }
}

/// The mark: the icon, its glow, and its landing.
class _IntroMark extends StatelessWidget {
  const _IntroMark({required this.frame, required this.size, super.key});

  final IntroFrame frame;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          // The glow behind the mark.
          Opacity(
            opacity: frame.iconGlowOpacity.clamp(0.0, 1.0),
            child: Container(
              width: size * 2.8,
              height: size * 2.8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const RadialGradient(
                  colors: [
                    Color(0x8CFF2A4B),
                    Color(0x47E50914),
                    Color(0x00E50914),
                  ],
                  stops: [0.0, 0.34, 0.70],
                ),
              ),
            ),
          ),
          // The mark: the icon, its glow, and its landing.
          Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..scaleByDouble(frame.iconScale, frame.iconScale, 1, 1)
              ..rotateZ(frame.iconRotationDeg * math.pi / 180),
            child: Opacity(
              opacity: frame.iconOpacity.clamp(0.0, 1.0),
              child: SizedBox(
                width: size,
                height: size,
                child: const BrandMark(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One wordmark, letter by letter.
class _IntroWordmark extends StatelessWidget {
  const _IntroWordmark({
    required this.frame,
    required this.text,
    required this.word,
    required this.fontSize,
    required this.colors,
  });

  final IntroFrame frame;
  final String text;
  final IntroWordState word;
  final double fontSize;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final letters = splitLetters(text);
    final blur = word.blurPx;
    Widget row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < letters.length; i++)
          _IntroLetter(
            letter: letters[i],
            state: word.letters[i],
            fontSize: fontSize,
            colors: colors,
          ),
      ],
    );

    if (blur != null && blur > 0) {
      row = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: row,
      );
    }

    // MERGED, so the ambient style is inherited - the family included. The
    // canonical's font stack puts the platform's UI font first, and a test
    // that renders the wordmarks in Ahem (solid squares) measures a layout
    // that no device ever has.
    //
    // The DECORATION is not inherited, and it is set to `none` on purpose: a
    // merged style takes the ambient style's decoration with it, and the
    // ambient style is whatever surrounds the sequence. On the phone it
    // carried one, and the sequence showed **double yellow underlines under
    // every wordmark** - which the canonical does not have, in either aspect.
    //
    // The picture oracle cannot see that class of fault: a test's ambient
    // style never carries a decoration, so only a real device shows it.
    return DefaultTextStyle.merge(
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.022 * fontSize,
        height: 1.02,
        decoration: TextDecoration.none,
      ),
      child: row,
    );
  }
}

/// One letter of a wordmark.
class _IntroLetter extends StatelessWidget {
  const _IntroLetter({
    required this.letter,
    required this.state,
    required this.fontSize,
    required this.colors,
  });

  final String letter;
  final IntroLetterState state;
  final double fontSize;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    // The gradient is painted as the text's **foreground**, not as a mask.
    //
    // A `ShaderMask` is a `saveLayer` with a blend mode - one offscreen
    // buffer per letter, and there are twenty-one letters, so twenty-one
    // offscreen buffers every frame. On a television's GPU that is the
    // difference between smooth and not.
    //
    // `TextStyle.foreground` paints the gradient through the glyphs' own
    // shape instead, with no offscreen buffer at all - and it is the SAME
    // picture: the canonical's gradient is vertical, so each letter's slice of
    // it depends only on the letter's height, which is the same for every
    // letter of a word.
    // The letter's alpha is baked into the gradient's colours rather than
    // applied with an `Opacity`. An `Opacity` is a `saveLayer` with a blend
    // mode - one offscreen buffer per letter, and there are twenty-one letters,
    // every frame. Scaling the gradient's alpha is the same picture: the
    // canonical's letter is a gradient fill with the element's opacity over
    // it, and the gradient is fully opaque.
    final alpha = state.opacity.clamp(0.0, 1.0);
    final faded = [
      for (final c in colors)
        c.withValues(
          alpha: (c.a * alpha).clamp(0.0, 1.0),
        ),
    ];
    return Transform.translate(
      offset: Offset(0, state.translateYEm * fontSize),
      child: Text(
        letter,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          height: 1.02,
          foreground: Paint()
            ..shader = ui.Gradient.linear(
              Offset.zero,
              Offset(0, fontSize * 1.02),
              faded,
            ),
        ),
      ),
    );
  }
}

/// The subtitle: "PLAY - ORGANIZE - ENJOY".
class _IntroSubtitle extends StatelessWidget {
  const _IntroSubtitle({required this.frame, required this.u});

  final IntroFrame frame;
  final double u;

  @override
  Widget build(BuildContext context) {
    final fontSize = (u * 1.3).clamp(8.5, 13.0);
    final blur = frame.subBlurPx;
    Widget text = Text(
      'PLAY  \u2022  ORGANIZE  \u2022  ENJOY',
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w800,
        letterSpacing: frame.subLetterSpacingEm * fontSize,
        color: const Color(0xFF94A3B8),
        // The sequence's own typography is not the ambient style's to decide:
        // see the note on the wordmark's merged style.
        decoration: TextDecoration.none,
      ),
    );
    if (blur != null && blur > 0) {
      text = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: text,
      );
    }
    return Opacity(opacity: frame.subOpacity.clamp(0.0, 1.0), child: text);
  }
}

/// The red rule.
class _IntroRule extends StatelessWidget {
  const _IntroRule({required this.frame, required this.u});

  final IntroFrame frame;
  final double u;

  @override
  Widget build(BuildContext context) {
    final width = (u * 100 * 0.5).clamp(0.0, double.infinity);
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()..scaleByDouble(frame.ruleScaleX, 1, 1, 1),
      child: Container(
        width: width,
        height: 2,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(99),
          gradient: const LinearGradient(
            colors: [
              Color(0x00FF2A4B),
              Color(0xFFFF2A4B),
              Color(0xFFE50914),
              Color(0xFFFF2A4B),
              Color(0x00FF2A4B),
            ],
            stops: [0.0, 0.22, 0.50, 0.78, 1.0],
          ),
          boxShadow: const [
            BoxShadow(color: Color(0x8CE50914), blurRadius: 12),
          ],
        ),
      ),
    );
  }
}
