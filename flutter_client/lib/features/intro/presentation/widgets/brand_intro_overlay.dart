import 'dart:math' as math;
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../app/theme/app_colors.dart';

// ============================================================================
// Timeline constants — mirroring the web client's intro-overlay.html cues
// ============================================================================
const double _kImpact = 0.62;
const double _kW1 = 0.80;
const double _kW2 = 0.92;
const double _kSub = 1.24;
const double _kRule = 1.42;
const double _kCurtain = 1.95;
const double _kCurtainEnd = 2.75;
const double _kDuration = 3.0;

// Easing helpers matching the web's eOutCubic / eOutQuint / eInOutCubic / eOutBack
double _eOutCubic(double t) => 1.0 - math.pow(1.0 - t, 3).toDouble();
double _eOutQuint(double t) => 1.0 - math.pow(1.0 - t, 5).toDouble();
double _eInOutCubic(double t) =>
    t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3).toDouble() / 2;
double _eOutBack(double t) {
  const c1 = 1.9;
  const c3 = c1 + 1;
  return 1 + c3 * math.pow(t - 1, 3) + c1 * math.pow(t - 1, 2);
}

double _seg(double t, double a, double b) {
  if (b <= a) return t >= b ? 1.0 : 0.0;
  return ((t - a) / (b - a)).clamp(0.0, 1.0);
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// Fullscreen 3.0-second brand intro overlay using native Flutter animations.
/// The curtain parts to reveal the live HomeScreen underneath — no baked video.
/// Tapping anywhere or pressing Skip immediately hands control back to the app.
class BrandIntroOverlay extends StatefulWidget {
  final VoidCallback onFinished;
  // Retained for API compat — no longer used for media_kit injection
  final dynamic customPlayer;
  final dynamic customVideoController;
  final bool autoFinishOnError;

  const BrandIntroOverlay({
    super.key,
    required this.onFinished,
    this.customPlayer,
    this.customVideoController,
    this.autoFinishOnError = true,
  });

  @override
  State<BrandIntroOverlay> createState() => _BrandIntroOverlayState();
}

class _BrandIntroOverlayState extends State<BrandIntroOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  Timer? _safetyTimeout;
  bool _isExiting = false;
  double _opacity = 1.0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (_kDuration * 1000).round()),
    );
    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_isExiting && mounted) {
        _handleFinish();
      }
    });
    // Safety timeout: 3.0s ident + 500ms grace threshold
    _safetyTimeout = Timer(const Duration(milliseconds: 3500), () {
      if (!_isExiting && mounted) _handleFinish();
    });
    _ctrl.forward();
  }

  void _handleFinish({bool immediate = false}) {
    if (_isExiting) return;
    _isExiting = true;
    _safetyTimeout?.cancel();

    if (immediate || !mounted) {
      widget.onFinished();
      return;
    }

    setState(() => _opacity = 0.0);

    // Fade out over 300ms, then invoke callback
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) widget.onFinished();
    });
  }

  @override
  void dispose() {
    _safetyTimeout?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _opacity,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      child: Material(
        color: Colors.transparent,
        child: Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent) {
              _handleFinish();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _handleFinish(),
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) {
              final t = _ctrl.value * _kDuration;
              final curtainProgress =
                  _eInOutCubic(_seg(t, _kCurtain, _kCurtainEnd).clamp(0, 1));
              final lockupFade = _eInOutCubic(
                  _seg(t, _kCurtain, _kCurtain + 0.62).clamp(0, 1));

              return Stack(
                fit: StackFit.expand,
                children: [
                  // Impact flash + shockwave + seam glow + vignette canvas
                  CustomPaint(
                    painter: _IntroFXPainter(t: t),
                    size: Size.infinite,
                  ),

                  // Left veil
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: MediaQuery.of(context).size.width *
                        (0.5 + 0.002) *
                        (1.0 - curtainProgress),
                    child: const _VeilHalf(isLeft: true),
                  ),

                  // Right veil
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: MediaQuery.of(context).size.width *
                        (0.5 + 0.002) *
                        (1.0 - curtainProgress),
                    child: const _VeilHalf(isLeft: false),
                  ),

                  // Seam glow between curtain halves
                  if (curtainProgress > 0)
                    Center(
                      child: Opacity(
                        opacity: (math
                                    .pow(
                                        math.sin(math.min(
                                                1.0, curtainProgress * 1.06) *
                                            math.pi),
                                        1.25)
                                    .toDouble() *
                                0.9)
                            .clamp(0.0, 1.0),
                        child: Container(
                          width: MediaQuery.of(context).size.width * 0.38,
                          height: double.infinity,
                          decoration: BoxDecoration(
                            gradient: RadialGradient(
                              center: const Alignment(0.0, -0.04),
                              radius: 0.8,
                              colors: [
                                const Color(0x9EFFF0F2),
                                const Color(0x3DFF788C),
                                Colors.transparent,
                              ],
                              stops: const [0.0, 0.4, 0.74],
                            ),
                          ),
                        ),
                      ),
                    ),

                  // Vignette overlay (fades as curtain opens)
                  IgnorePointer(
                    child: Opacity(
                      opacity: (1.0 - curtainProgress).clamp(0.0, 1.0),
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: RadialGradient(
                            center: Alignment.center,
                            radius: 0.95,
                            colors: [
                              Colors.transparent,
                              Color(0x8C000000),
                              Color(0xD9000000),
                            ],
                            stops: [0.42, 0.82, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Brand lockup — icon + wordmark + subtitle + rule
                  Positioned.fill(
                    child: Opacity(
                      opacity: (1.0 - lockupFade).clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: Offset(0, -lockupFade * 24),
                        child: Transform.scale(
                          scale: _lerp(1.0, 0.94, lockupFade),
                          child: Center(
                            child: _BrandLockup(t: t),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Skip pill button in safe area
                  if (!_isExiting)
                    SafeArea(
                      child: Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: TextButton.icon(
                            style: TextButton.styleFrom(
                              backgroundColor:
                                  Colors.black.withValues(alpha: 0.60),
                              foregroundColor: AppColors.textSecondary,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(9999),
                                side: const BorderSide(
                                  color: AppColors.borderSubtle,
                                  width: 1,
                                ),
                              ),
                            ),
                            onPressed: () => _handleFinish(),
                            icon: const Icon(
                              Icons.skip_next_rounded,
                              size: 16,
                              color: AppColors.textSecondary,
                            ),
                            label: const Text(
                              'Skip',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.4,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}
}

// ============================================================================
// Veil half — the dark curtain pane
// ============================================================================
class _VeilHalf extends StatelessWidget {
  final bool isLeft;
  const _VeilHalf({required this.isLeft});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: isLeft
              ? const Alignment(0.0, -0.16)
              : const Alignment(0.0, -0.16),
          radius: 1.2,
          colors: const [
            Color(0x1AE50914), // subtle brand red glow
            Color(0x0D38BDF8), // hint of blue
            Color(0xFF05060A), // deep obsidian base
          ],
          stops: const [0.0, 0.35, 0.68],
        ),
      ),
    );
  }
}

// ============================================================================
// Brand lockup — icon, wordmark, subtitle, rule
// ============================================================================
class _BrandLockup extends StatelessWidget {
  final double t;
  const _BrandLockup({required this.t});

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final u = math.min(screenWidth, MediaQuery.of(context).size.height) / 100;

    // Icon animation
    final iconP = _seg(t, _kImpact - 0.10, _kImpact + 0.26);
    final iconEase = _eOutBack(iconP.clamp(0, 1));
    final iconScale = _lerp(1.55, 1.0, iconEase);
    final iconRotation = _lerp(-7.0, 0.0, iconEase) * math.pi / 180;
    final iconOpacity = iconP > 0 ? (iconEase * 1.4).clamp(0.0, 1.0) : 0.0;

    // Icon glow
    final glowP = _seg(t, _kImpact - 0.04, _kImpact + 0.30);
    final glowOpacity = iconP > 0 ? ((1.0 - glowP) * 0.95 + 0.16) : 0.0;

    final iconSize = (u * 10.5).clamp(64.0, 118.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Brand icon with glow
        Stack(
          alignment: Alignment.center,
          children: [
            // Glow behind icon
            Opacity(
              opacity: glowOpacity.clamp(0.0, 1.0),
              child: Container(
                width: iconSize * 2.8,
                height: iconSize * 2.8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0x8CFF2A4B),
                      const Color(0x47E50914),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.34, 0.70],
                  ),
                ),
              ),
            ),
            // The icon itself
            Opacity(
              opacity: iconOpacity,
              child: Transform.scale(
                scale: iconScale,
                child: Transform.rotate(
                  angle: iconRotation,
                  child: SizedBox(
                    width: iconSize,
                    height: iconSize,
                    child: CustomPaint(
                      painter: _BrandIconPainter(),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),

        SizedBox(height: (u * 1.5).clamp(9.0, 20.0)),

        // Wordmark "Anis'"
        _AnimatedWordmark(
          text: "Anis'",
          t: t,
          startTime: _kW1,
          duration: 0.40,
          letterDelay: 0.014,
          gradientColors: const [Color(0xFFFFFFFF), Color(0xFFCBD5E1)],
          fontSize: (u * 5.7).clamp(30.0, 66.0),
        ),

        SizedBox(height: (u * 0.3).clamp(2.0, 4.0)),

        // Wordmark "Home Media Server"
        _AnimatedWordmark(
          text: "Home Media Server",
          t: t,
          startTime: _kW2,
          duration: 0.42,
          letterDelay: 0.014,
          gradientColors: const [Color(0xFFFF5F70), Color(0xFFE50914)],
          fontSize: (u * 5.7).clamp(30.0, 66.0),
        ),

        SizedBox(height: (u * 0.7).clamp(3.0, 7.0)),

        // Subtitle "PLAY • ORGANIZE • ENJOY"
        Builder(builder: (context) {
          final subP = _seg(t, _kSub, _kSub + 0.46);
          final subEase = _eOutCubic(subP);
          final spacing = _lerp(12.0, 2.2, subEase);
          final subBlur = _lerp(5.0, 0.0, subEase);
          return Opacity(
            opacity: subEase,
            child: ImageFiltered(
              imageFilter:
                  subBlur > 0.1
                      ? _blurFilter(subBlur)
                      : _blurFilter(0),
              child: Text(
                'PLAY  •  ORGANIZE  •  ENJOY',
                style: TextStyle(
                  fontSize: (u * 1.3).clamp(8.5, 13.0),
                  fontWeight: FontWeight.w800,
                  letterSpacing: spacing,
                  color: const Color(0xFF94A3B8),
                ),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }),

        SizedBox(height: (u * 0.5).clamp(3.0, 6.0)),

        // Red rule line
        Builder(builder: (context) {
          final ruleP = _seg(t, _kRule, _kRule + 0.36);
          final ruleScale = _eInOutCubic(ruleP);
          return Transform.scale(
            scaleX: ruleScale,
            child: Container(
              width: screenWidth * 0.5,
              height: 2,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(99),
                gradient: const LinearGradient(
                  colors: [
                    Colors.transparent,
                    Color(0xFFFF2A4B),
                    Color(0xFFE50914),
                    Color(0xFFFF2A4B),
                    Colors.transparent,
                  ],
                  stops: [0.0, 0.22, 0.50, 0.78, 1.0],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0x8CE50914),
                    blurRadius: 12,
                    spreadRadius: 0,
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

// ============================================================================
// Animated wordmark — staggered letter-by-letter reveal with gradient
// ============================================================================
class _AnimatedWordmark extends StatelessWidget {
  final String text;
  final double t;
  final double startTime;
  final double duration;
  final double letterDelay;
  final List<Color> gradientColors;
  final double fontSize;

  const _AnimatedWordmark({
    required this.text,
    required this.t,
    required this.startTime,
    required this.duration,
    required this.letterDelay,
    required this.gradientColors,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    // Overall word blur
    final wordP = _seg(t, startTime, startTime + duration);
    final wordBlur = _lerp(7.0, 0.0, _eOutCubic(wordP));

    return ImageFiltered(
      imageFilter:
          wordBlur > 0.1 ? _blurFilter(wordBlur) : _blurFilter(0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(text.length, (i) {
          final delay = i * letterDelay;
          final letterP = _seg(t, startTime + delay, startTime + delay + 0.34);
          final letterEase = _eOutQuint(letterP);
          final yOffset = _lerp(0.55, 0.0, letterEase) * fontSize;

          return Opacity(
            opacity: letterEase.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, yOffset),
              child: ShaderMask(
                shaderCallback: (bounds) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: gradientColors,
                ).createShader(bounds),
                blendMode: BlendMode.srcIn,
                child: Text(
                  text[i] == ' ' ? '\u00A0' : text[i],
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    height: 1.02,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ============================================================================
// Brand icon painter — matches the SVG from intro-overlay.html
// ============================================================================
class _BrandIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 36;

    // Background rounded rect
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(9 * s),
    );
    canvas.drawRRect(bgRect, Paint()..color = const Color(0xFF141822));

    // Border stroke
    final borderRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.5 * s, 0.5 * s, 35 * s, 35 * s),
      Radius.circular(8.5 * s),
    );
    canvas.drawRRect(
      borderRect,
      Paint()
        ..color = const Color(0x14FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s,
    );

    // Play triangle path: M12 9.2C10.7 8.4 9 9.3 9 10.9v14.2c0 1.6 1.7 2.5 3 1.7l13.5-7.1c1.3-.8 1.3-2.6 0-3.4L12 9.2z
    final playPath = Path();
    playPath.moveTo(12 * s, 9.2 * s);
    playPath.cubicTo(
        10.7 * s, 8.4 * s, 9 * s, 9.3 * s, 9 * s, 10.9 * s);
    playPath.lineTo(9 * s, 25.1 * s);
    playPath.cubicTo(
        9 * s, 26.7 * s, 10.7 * s, 27.6 * s, 12 * s, 26.8 * s);
    playPath.lineTo(25.5 * s, 19.7 * s);
    playPath.cubicTo(
        26.8 * s, 18.9 * s, 26.8 * s, 17.1 * s, 25.5 * s, 16.3 * s);
    playPath.lineTo(12 * s, 9.2 * s);
    playPath.close();

    // Shadow
    canvas.drawShadow(playPath, const Color(0x66E50914), 6 * s, false);

    // Gradient fill
    final gradientPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFF334B), Color(0xFFE50914), Color(0xFF990014)],
        stops: [0.0, 0.45, 1.0],
      ).createShader(Rect.fromLTWH(9 * s, 9 * s, 17.5 * s, 18 * s));
    canvas.drawPath(playPath, gradientPaint);

    // Highlight overlay (top half) — semi-transparent
    final highlightPath = Path();
    highlightPath.moveTo(12 * s, 9.2 * s);
    highlightPath.cubicTo(
        10.7 * s, 8.4 * s, 9 * s, 9.3 * s, 9 * s, 10.9 * s);
    highlightPath.lineTo(9 * s, 19.4 * s);
    highlightPath.lineTo(23.2 * s, 18.0 * s);
    highlightPath.lineTo(12 * s, 9.2 * s);
    highlightPath.close();

    final highlightPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x59FFFFFF), Color(0x05FFFFFF)],
      ).createShader(Rect.fromLTWH(9 * s, 9 * s, 15 * s, 11 * s));
    canvas.drawPath(highlightPath, highlightPaint);

    // Outer stroke on play triangle
    canvas.drawPath(
      playPath,
      Paint()
        ..color = const Color(0x2EFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.75 * s,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ============================================================================
// Canvas FX painter — impact flash, shockwave rings, vignette
// ============================================================================
class _IntroFXPainter extends CustomPainter {
  final double t;
  const _IntroFXPainter({required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final diag = math.sqrt(size.width * size.width + size.height * size.height);

    // Impact flash (t ≈ 0.57 → 0.96)
    final flashP = _seg(t, _kImpact - 0.05, _kImpact + 0.34);
    if (flashP > 0 && flashP < 1) {
      final alpha = (flashP < 0.09
              ? flashP / 0.09
              : math.pow(1.0 - (flashP - 0.09) / 0.91, 2.2).toDouble()) *
          0.72;
      final flashPaint = Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 0.55,
          colors: [
            Color.fromRGBO(255, 255, 255, alpha),
            Color.fromRGBO(255, 140, 155, alpha * 0.55),
            Color.fromRGBO(229, 9, 20, alpha * 0.22),
            const Color(0x00E50914),
          ],
          stops: const [0.0, 0.22, 0.6, 1.0],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
      canvas.drawRect(
          Rect.fromLTWH(0, 0, size.width, size.height), flashPaint);
    }

    // Shockwave rings
    for (int i = 0; i < 2; i++) {
      final ringP =
          _seg(t, _kImpact + i * 0.07, _kImpact + 0.80 + i * 0.07);
      if (ringP > 0 && ringP < 1) {
        final ringR = _eOutQuint(ringP) * diag * 0.44;
        final ringAlpha = i == 0
            ? math.pow(1.0 - ringP, 1.8).toDouble() * 0.7
            : math.pow(1.0 - ringP, 1.6).toDouble() * 0.75;
        final ringColor = i == 0
            ? Color.fromRGBO(255, 255, 255, ringAlpha)
            : Color.fromRGBO(255, 42, 75, ringAlpha);
        canvas.drawCircle(
          Offset(cx, cy),
          ringR,
          Paint()
            ..color = ringColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1 + 7 * (1 - ringP),
        );
      }
    }

    // Standing brand glow (after impact, before curtain)
    final brandGlowP = _seg(t, _kImpact, _kCurtain);
    if (brandGlowP > 0) {
      final fadeOut = 1.0 - _seg(t, _kCurtain, _kCurtain + 0.30);
      final glowAlpha =
          (0.16 + 0.05 * math.sin(t * 7.0)) * brandGlowP * fadeOut;
      if (glowAlpha > 0.001) {
        final glowPaint = Paint()
          ..shader = RadialGradient(
            center: Alignment.center,
            radius: 0.30,
            colors: [
              Color.fromRGBO(255, 60, 80, glowAlpha),
              Color.fromRGBO(229, 9, 20, glowAlpha * 0.42),
              const Color(0x00E50914),
            ],
            stops: const [0.0, 0.45, 1.0],
          ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
        canvas.drawRect(
            Rect.fromLTWH(0, 0, size.width, size.height), glowPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _IntroFXPainter oldDelegate) =>
      oldDelegate.t != t;
}

// ============================================================================
// Helper: create a blur ImageFilter (sigma)
// ============================================================================
ui.ImageFilter _blurFilter(double sigma) {
  return ui.ImageFilter.blur(
    sigmaX: sigma,
    sigmaY: sigma,
    tileMode: TileMode.decal,
  );
}
