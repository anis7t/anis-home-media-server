import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/intro_frame.dart';
import '../../domain/intro_score.dart';
import '../../domain/intro_timeline.dart';
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

  @override
  State<BrandIntroOverlay> createState() => BrandIntroOverlayState();
}

class BrandIntroOverlayState extends State<BrandIntroOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _finished = false;
  bool _handover = false;


  /// The measured geometry the FX are drawn from.
  Offset? _iconOrigin;
  Rect? _lockupRect;

  /// A frame held for the comparison oracle, if one has been requested.
  double? _manualTime;

  late final IntroScoreController _score;

  final GlobalKey _stageKey = GlobalKey();
  final GlobalKey _iconKey = GlobalKey();
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
    _score = IntroScoreController(
      score: widget.score,
      elapsedAt: () => Duration(milliseconds: (_ctrl.value * kIntroDuration * 1000).round()),
      duration: const Duration(milliseconds: 3000),
    );
    // The score starts with the sequence, and NOTHING waits for it: the
    // animation is already running.
    _score.start();
    _ctrl.forward();
  }

  void _onTick() {
    final t = _ctrl.value * kIntroDuration;
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
    final iconBox = _iconKey.currentContext?.findRenderObject() as RenderBox?;
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
          iconKey: _iconKey,
          lockupKey: _lockupKey,
          iconOrigin: _iconOrigin,
          lockupRect: _lockupRect,
          onDismiss: _finish,
        );
      },
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

        // z5 - the vignette.
        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: frame.vignetteOpacity,
              child: const _IntroVignette(),
            ),
          ),
        ),

        // z6 - the grain.
        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: frame.grainOpacity,
              child: const _IntroGrain(),
            ),
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
          child: ShaderMask(
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
  const _IntroVignette();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _VignettePainter(), size: Size.infinite);
  }
}

class _VignettePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rx = size.width * 0.78;
    final ry = size.height * 0.70;
    final centre = Offset(size.width * 0.5, size.height * 0.5);
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
            Color(0x00000000),
            Color(0x00000000),
            Color(0x8C000000),
            Color(0xD9000000),
          ],
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
  const _IntroGrain();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _GrainPainter(), size: Size.infinite);
  }
}

class _GrainPainter extends CustomPainter {
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
    final paint = Paint()
      ..shader = ui.ImageShader(
        image,
        TileMode.repeated,
        TileMode.repeated,
        Matrix4.identity().storage,
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

    return DefaultTextStyle(
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.022 * fontSize,
        height: 1.02,
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
    return Opacity(
      opacity: state.opacity.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(0, state.translateYEm * fontSize),
        child: ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => ui.Gradient.linear(
            Offset(bounds.left, bounds.top),
            Offset(bounds.left, bounds.bottom),
            colors,
          ),
          child: Text(
            letter,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w800,
              height: 1.02,
              color: Colors.white,
            ),
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
