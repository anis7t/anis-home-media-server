import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../domain/intro_timeline.dart';

/// The brand opening sequence - the FX.
///
/// A Dart port of the canonical renderer, `web/src/lib/intro/fx.ts`, which is
/// itself a faithful port of the archived original's `drawFX(t)`
/// (`docs/opening-sequence/source/intro-overlay.html`, source 372-493): the
/// build-up beams, the particles converging on the mark, the impact burst,
/// the shockwave rings, the impact flash, the standing brand glow, the
/// settling embers and the specular sheen.
///
/// ## The canvas's `lighter` is Flutter's `BlendMode.plus`
///
/// The original drew every effect with `globalCompositeOperation = 'lighter'`
/// - additive. Flutter's `BlendMode.plus` is the same operation: the source
/// and the destination are added, and the alpha is added and clamped. So
/// every paint in here carries `BlendMode.plus`, and the alpha the canvas
/// would have applied through `globalAlpha` is baked into the colour instead.
class IntroFxPainter extends CustomPainter {
  IntroFxPainter({
    required this.t,
    required this.geometry,
    required this.reduced,
  });

  /// The time in the sequence.
  final double t;

  /// The stage's geometry and the measured rectangles.
  final IntroFxGeometry geometry;

  /// Whether the user asked for reduced motion.
  final bool reduced;

  @override
  void paint(Canvas canvas, Size size) {
    final g = geometry;
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final diag = math.sqrt(w * w + h * h);
    final origin = fxOrigin(g, w, h);
    final cx = origin.dx;
    final cy = origin.dy;

    _paintBeams(canvas, w, h, diag);
    _paintConverging(canvas, diag, cx, cy);
    _paintBurst(canvas, diag, cx, cy);
    _paintRings(canvas, diag, cx, cy);
    _paintFlash(canvas, w, h, diag, cx, cy);
    _paintGlow(canvas, w, h, diag, cx, cy);
    _paintEmbers(canvas, w, h);
    _paintSheen(canvas, g);
  }

  /* build-up light beams (source 378-392) */
  void _paintBeams(Canvas canvas, double w, double h, double diag) {
    final p = seg(t, IntroT.streak, IntroT.impact);
    if (p <= 0 || p >= 1) return;
    final alpha = 0.3 * math.sin(p * math.pi);
    for (var i = 0; i < 3; i++) {
      final ph = i / 3;
      final px = lerpNum(-w * 0.35, w * 0.35, (p + ph) % 1);
      final bw = w * 0.09;
      canvas.save();
      canvas.translate(w / 2 + px, h / 2);
      canvas.rotate(-0.22);
      final mid = i == 1
          ? const Color(0xFFFF5A6E)
          : const Color(0xFFFFFFFF);
      final paint = Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.linear(
          ui.Offset(-bw, 0),
          ui.Offset(bw, 0),
          [
            mid.withValues(alpha: 0),
            mid.withValues(alpha: (i == 1 ? 0.5 : 0.38) * alpha),
            mid.withValues(alpha: 0),
          ],
          const [0.0, 0.5, 1.0],
        );
      canvas.drawRect(
        Rect.fromLTWH(-bw, -diag * 0.8, bw * 2, diag * 1.6),
        paint,
      );
      canvas.restore();
    }
  }

  /* particles converging on the mark (source 394-407) */
  void _paintConverging(Canvas canvas, double diag, double cx, double cy) {
    final p = seg(t, IntroT.streak, IntroT.impact);
    if (p <= 0 || p >= 1) return;
    final r0 = diag * 0.62;
    final e1 = eOutCubic(p);
    final e2 = eOutCubic(math.max(0, p - 0.07));
    for (final c in kConverging) {
      final r1 = lerpNum(c.r0 * r0, diag * 0.008, e1);
      final r2 = lerpNum(c.r0 * r0, diag * 0.008, e2);
      final x = cx + math.cos(c.a) * r1;
      final y = cy + math.sin(c.a) * r1;
      final paint = Paint()
        ..blendMode = BlendMode.plus
        ..style = PaintingStyle.stroke
        ..strokeWidth = c.s * (0.5 + 0.9 * e1)
        ..color = Color.fromRGBO(
          c.c.r.toInt(),
          c.c.g.toInt(),
          c.c.b.toInt(),
          clampNum(0.1 + 0.55 * e1, 0, 1) * c.sp,
        );
      canvas.drawLine(
        Offset(cx + math.cos(c.a) * r2, cy + math.sin(c.a) * r2),
        Offset(x, y),
        paint,
      );
    }
  }

  /* impact burst (source 409-420) - suppressed under reduced motion */
  void _paintBurst(Canvas canvas, double diag, double cx, double cy) {
    final q = seg(t, IntroT.impact, IntroT.impact + 0.42);
    if (q <= 0 || q >= 1 || reduced) return;
    final eb = eOutQuint(q);
    for (final cb in kConverging) {
      final rb = diag * 0.008 + eb * (cb.r0 * diag * 0.3 + 150);
      final x = cx + math.cos(cb.a) * rb;
      final y = cy + math.sin(cb.a) * rb;
      final a = (1 - q) * (1 - q) * 0.85 * cb.sp;
      canvas.drawCircle(
        Offset(x, y),
        cb.s * 1.7 * (1 - q * 0.45),
        Paint()
          ..blendMode = BlendMode.plus
          ..color = Color.fromRGBO(
            cb.c.r.toInt(),
            cb.c.g.toInt(),
            cb.c.b.toInt(),
            a,
          ),
      );
    }
  }

  /* shockwave rings (source 422-433) */
  void _paintRings(Canvas canvas, double diag, double cx, double cy) {
    for (var i = 0; i < 2; i++) {
      final q = seg(t, IntroT.impact + i * 0.07, IntroT.impact + 0.8 + i * 0.07);
      if (q <= 0 || q >= 1) continue;
      final rr = eOutQuint(q) * diag * 0.44;
      final alpha = i == 0
          ? math.pow(1 - q, 1.8).toDouble() * 0.7
          : math.pow(1 - q, 1.6).toDouble() * 0.75;
      final colour = i == 0 ? const Color(0xFFFFFFFF) : const Color(0xFFFF2A4B);
      canvas.drawCircle(
        Offset(cx, cy),
        rr,
        Paint()
          ..blendMode = BlendMode.plus
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1 + 7 * (1 - q)
          ..color = colour.withValues(alpha: alpha),
      );
    }
  }

  /* impact flash (source 435-445) */
  void _paintFlash(
    Canvas canvas,
    double w,
    double h,
    double diag,
    double cx,
    double cy,
  ) {
    final q = seg(t, IntroT.impact - 0.05, IntroT.impact + 0.34);
    if (q <= 0 || q >= 1) return;
    final a = (q < 0.09 ? q / 0.09 : math.pow(1 - (q - 0.09) / 0.91, 2.2)) * 0.72;
    final centre = Offset(cx, cy);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.radial(
          centre,
          diag * 0.55,
          [
            const Color(0xFFFFFFFF).withValues(alpha: a),
            const Color(0xFFFF8C9B).withValues(alpha: a * 0.55),
            const Color(0xFFE50914).withValues(alpha: a * 0.22),
            const Color(0xFFE50914).withValues(alpha: 0),
          ],
          const [0.0, 0.22, 0.6, 1.0],
        ),
    );
  }

  /* standing brand glow (source 447-457) */
  void _paintGlow(
    Canvas canvas,
    double w,
    double h,
    double diag,
    double cx,
    double cy,
  ) {
    final p = seg(t, IntroT.impact, IntroT.curtain);
    if (p <= 0) return;
    final gp = 1 - seg(t, IntroT.curtain, IntroT.curtain + 0.3);
    final a = (0.16 + 0.05 * math.sin(t * 7)) * p * gp;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.radial(
          Offset(cx, cy),
          diag * 0.3,
          [
            const Color(0xFFFF3C50).withValues(alpha: a),
            const Color(0xFFE50914).withValues(alpha: a * 0.42),
            const Color(0xFFE50914).withValues(alpha: 0),
          ],
          const [0.0, 0.45, 1.0],
        ),
    );
  }

  /* settling embers (source 459-472) */
  void _paintEmbers(Canvas canvas, double w, double h) {
    final q2 = seg(t, IntroT.settle - 0.35, IntroT.settle + 0.7);
    if (q2 <= 0) return;
    final fadeOut = 1 - seg(t, IntroT.curtain + 0.1, IntroT.curtainEnd + 0.05);
    for (final em in kEmbers) {
      final tt = t - 1.2;
      final yn = (((em.y - (tt * em.sp) / h) % 1.4) + 1.4) % 1.4 - 0.2;
      final x = (em.x + math.sin(tt * em.f + em.ph) * 0.02 * em.dx) * w;
      final y = yn * h;
      final a = q2 *
          fadeOut *
          (0.35 + 0.4 * math.sin(t * em.f * 2 + em.ph).abs()) *
          0.8;
      canvas.drawCircle(
        Offset(x, y),
        em.s,
        Paint()
          ..blendMode = BlendMode.plus
          ..color = Color.fromRGBO(
            em.c.r.toInt(),
            em.c.g.toInt(),
            em.c.b.toInt(),
            a,
          ),
      );
    }
  }

  /* specular sheen sweeping the lockup (source 474-491) */
  void _paintSheen(Canvas canvas, IntroFxGeometry g) {
    final q = seg(t, IntroT.sheen, IntroT.sheen + 0.5);
    if (q <= 0 || q >= 1) return;
    final lr = g.lockupRect;
    if (lr == null || lr.width <= 0) return;
    canvas.save();
    canvas.translate(
      lr.left + lr.width * lerpNum(-0.25, 1.25, eInOutCubic(q)),
      lr.top + lr.height / 2,
    );
    canvas.rotate(-0.3);
    final sw = lr.width * 0.3;
    final sh = lr.height * 2.2;
    final alpha = math.sin(q * math.pi) * 0.85;
    canvas.drawRect(
      Rect.fromLTWH(-sw, -sh / 2, sw * 2, sh),
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.linear(
          ui.Offset(-sw, 0),
          ui.Offset(sw, 0),
          [
            const Color(0xFFFFFFFF).withValues(alpha: 0),
            const Color(0xFFFFFFFF).withValues(alpha: 0.55 * alpha),
            const Color(0xFFFFFFFF).withValues(alpha: 0),
          ],
          const [0.0, 0.5, 1.0],
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant IntroFxPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.reduced != reduced ||
      oldDelegate.geometry != geometry;
}

/// Where the FX are centred, and what they need to know about the stage.
///
/// The mark's rectangle and the lockup's rectangle are in the stage's own
/// coordinates, measured by the overlay - the same way the original measured
/// them from the live DOM (source 367-371, 474-491).
class IntroFxGeometry {
  const IntroFxGeometry({this.iconOrigin, this.lockupRect});

  /// The middle of the mark - where the FX are centred - or null if the mark
  /// has no size yet.
  ///
  /// It is the mark's *centre* and not its rectangle, because the centre does
  /// not move while the mark scales and rotates, and the FX are re-centred on
  /// every frame: a rectangle would change on every frame of the landing and
  /// cost a rebuild for nothing.
  final Offset? iconOrigin;

  /// The lockup's rectangle, or null.
  final Rect? lockupRect;

  @override
  bool operator ==(Object other) =>
      other is IntroFxGeometry &&
      other.iconOrigin == iconOrigin &&
      other.lockupRect == lockupRect;

  @override
  int get hashCode => Object.hash(iconOrigin, lockupRect);
}

/// Where the FX are centred: the middle of the mark, or the middle of the
/// stage if the mark has no size yet (source 367-371).
Offset fxOrigin(IntroFxGeometry g, double w, double h) {
  final origin = g.iconOrigin;
  if (origin != null) return origin;
  return Offset(w / 2, h / 2);
}
