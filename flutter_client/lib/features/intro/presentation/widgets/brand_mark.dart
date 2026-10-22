import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The Anis' brand mark - the canonical artwork.
///
/// The exact SVG the brand opening sequence was authored against
/// (`docs/opening-sequence/source/intro-overlay.html`, section "2. brand art
/// (from repo)"). It is the richer of the two marks that existed in the
/// codebase: the app header and the remote-login screen carried a
/// simplified re-creation with a single path and no shadow, while the
/// original mark has three paths, a specular highlight and a drop shadow.
///
/// The Flutter client's previous mark was a re-implementation, and it was
/// **wrong**: its specular highlight used the path
/// `M12 9.2 ... v 19.4 ... L23.2 18.0`, where the canonical's is
/// `M12 9.2 ... v8.5 l14.2-1.4 L12 9.2z` - so the highlight covered roughly
/// twice the area it should. Its shadow was a hard `drawShadow` at six
/// units, where the canonical's is a soft `feDropShadow dy=2 stdDeviation=3`.
///
/// The web's `web/src/components/BrandMark.tsx` carries the same artwork.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key});

  @override
  Widget build(BuildContext context) {
    // `Size.infinite` makes the canvas take the whole of its constraints. A
    // `CustomPaint` with no child and no size is ZERO-sized, and the mark
    // disappears - which is what happened the first time.
    return CustomPaint(painter: _BrandMarkPainter(), size: Size.infinite);
  }
}

class _BrandMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 36;

    // The background plate.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Radius.circular(9 * s),
      ),
      Paint()..color = const Color(0xFF141822),
    );

    // The border.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0.5 * s, 0.5 * s, 35 * s, 35 * s),
        Radius.circular(8.5 * s),
      ),
      Paint()
        ..color = const Color(0x14FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s,
    );

    // The play triangle.
    final play = _playPath(s);

    // The drop shadow: `feDropShadow dx=0 dy=2 stdDeviation=3` in the
    // source's #e50914 at 40 %.
    canvas.drawPath(
      play.shift(Offset(0, 2 * s)),
      Paint()
        ..color = const Color(0x66E50914)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 * s),
    );

    // The gradient fill.
    canvas.drawPath(
      play,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(9 * s, 9 * s),
          Offset(26.5 * s, 27 * s),
          const [
            Color(0xFFFF334B),
            Color(0xFFE50914),
            Color(0xFF990014),
          ],
          const [0.0, 0.45, 1.0],
        ),
    );

    // The specular highlight: the top of the triangle, fading downward.
    canvas.drawPath(
      _highlightPath(s),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(9 * s, 9 * s),
          Offset(9 * s, 20 * s),
          const [
            Color(0x59FFFFFF),
            Color(0x05FFFFFF),
          ],
        ),
    );

    // The hairline edge.
    canvas.drawPath(
      play,
      Paint()
        ..color = const Color(0x2EFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.75 * s,
    );
  }

  /// `M12 9.2C10.7 8.4 9 9.3 9 10.9v14.2c0 1.6 1.7 2.5 3 1.7l13.5-7.1c1.3-.8 1.3-2.6 0-3.4L12 9.2z`
  Path _playPath(double s) {
    final path = Path()
      ..moveTo(12 * s, 9.2 * s)
      ..cubicTo(10.7 * s, 8.4 * s, 9 * s, 9.3 * s, 9 * s, 10.9 * s)
      ..lineTo(9 * s, 25.1 * s)
      ..cubicTo(9 * s, 26.7 * s, 10.7 * s, 27.6 * s, 12 * s, 26.8 * s)
      ..lineTo(25.5 * s, 19.7 * s)
      ..cubicTo(26.8 * s, 18.9 * s, 26.8 * s, 17.1 * s, 25.5 * s, 16.3 * s)
      ..lineTo(12 * s, 9.2 * s)
      ..close();
    return path;
  }

  /// `M12 9.2C10.7 8.4 9 9.3 9 10.9v8.5l14.2-1.4L12 9.2z`
  Path _highlightPath(double s) {
    final path = Path()
      ..moveTo(12 * s, 9.2 * s)
      ..cubicTo(10.7 * s, 8.4 * s, 9 * s, 9.3 * s, 9 * s, 10.9 * s)
      ..lineTo(9 * s, 19.4 * s)
      ..lineTo(23.2 * s, 18.0 * s)
      ..lineTo(12 * s, 9.2 * s)
      ..close();
    return path;
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
