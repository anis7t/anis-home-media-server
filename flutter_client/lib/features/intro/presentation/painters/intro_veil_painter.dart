import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The brand opening sequence - the curtain.
///
/// A Dart port of the canonical curtain
/// (`web/src/components/brand/brand-intro.css`, itself a port of the archived
/// source's stylesheet, source 107-121).
///
/// ## The two halves are ONE backdrop
///
/// The source's curtain is not two panels with two gradients. It is one
/// image, `200% 100%`, drawn with **opposite** `background-position`s on the
/// two halves, so the halves' gradients line up into a single continuous
/// picture with a 1 px overlap at the centre. The Flutter port reproduces
/// that by giving each half the SAME stage-wide image, offset by half a stage
/// to the left or the right - so the left half shows the image's left portion
/// and the right half its right portion.
///
/// The image is defined in the stage's coordinates, and each half's painter
/// is told where its own copy of the image sits. That is what keeps the
/// picture continuous across the seam.
///
/// ## The gradient's shape
///
/// The source's blooms are **ellipses** (`ellipse 70% 55% at 50% 42%`).
/// Flutter's `RadialGradient` is a circle, so each bloom is drawn as a
/// circular gradient and then squashed by a canvas transform - which is the
/// same construction the CSS uses, where the gradient is defined in the
/// unsqueezed space and the shape is applied afterwards.
class IntroVeilPainter extends CustomPainter {
  const IntroVeilPainter({
    required this.isLeft,
    required this.stageWidth,
    required this.stageHeight,
    required this.imageLeft,
  });

  /// Whether this is the left half.
  final bool isLeft;

  /// The stage's width, in logical pixels.
  final double stageWidth;

  /// The stage's height, in logical pixels.
  final double stageHeight;

  /// Where this half's copy of the stage-wide image starts, in the half's own
  /// coordinates. The two halves' offsets are not symmetric, and getting them
  /// wrong puts a visible seam down the middle of the curtain.
  final double imageLeft;

  /// The source's three blooms (source 110-113).
  ///
  /// `ellipse Rx% Ry% at X% Y%`, with the colour fading to transparent at
  /// the given stop.
  static const List<_Bloom> _blooms = [
    _Bloom(0.70, 0.55, 0.50, 0.42, 0x1AE50914, 0.68),
    _Bloom(0.55, 0.45, 0.78, 0.84, 0x0D38BDF8, 0.62),
    _Bloom(0.45, 0.40, 0.16, 0.18, 0x0AA855F7, 0.60),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final half = stageWidth / 2 + 0.5; // the 1 px overlap at the centre
    // The image is the stage's width, carried by both halves so that they
    // line up into one continuous picture.
    final image = Rect.fromLTWH(
      imageLeft,
      0,
      half * 2,
      stageHeight,
    );

    // The opaque obsidian base. The stage itself paints nothing; the curtain
    // is what is opaque (spec Part I section 5).
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF05060A),
    );

    for (final bloom in _blooms) {
      _paintBloom(canvas, image, bloom);
    }
  }

  void _paintBloom(Canvas canvas, Rect image, _Bloom bloom) {
    final rx = bloom.rx * image.width;
    final ry = bloom.ry * image.height;
    final centre = Offset(
      image.left + bloom.cx * image.width,
      image.top + bloom.cy * image.height,
    );
    // A circle of the mean radius, squashed into the ellipse. The CSS
    // defines the gradient in the unsqueezed space and applies the shape
    // afterwards, so the stop positions follow the ray.
    final radius = (rx + ry) / 2;
    if (radius <= 0) return;
    final colour = Color(bloom.colour);
    final shader = ui.Gradient.radial(
      centre,
      radius,
      [
        colour,
        colour.withValues(alpha: 0),
      ],
      [0.0, bloom.stop],
    );

    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(rx / radius, ry / radius);
    canvas.translate(-centre.dx, -centre.dy);
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..shader = shader
        ..blendMode = BlendMode.plus,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant IntroVeilPainter oldDelegate) =>
      oldDelegate.isLeft != isLeft ||
      oldDelegate.stageWidth != stageWidth ||
      oldDelegate.stageHeight != stageHeight;
}

class _Bloom {
  const _Bloom(
    this.rx,
    this.ry,
    this.cx,
    this.cy,
    this.colour,
    this.stop,
  );

  /// The ellipse's horizontal radius, as a fraction of the image's width.
  final double rx;

  /// The ellipse's vertical radius, as a fraction of the image's height.
  final double ry;

  /// The centre, as a fraction of the image.
  final double cx;
  final double cy;

  /// The bloom's colour.
  final int colour;

  /// Where the colour has faded to nothing.
  final double stop;
}

/// The mask that feathers a curtain half's inner edge.
///
/// The source's mask is `linear-gradient(90deg,#000 (100 - feather)%,transparent
/// 100%)` for the left half and `270deg` for the right - and the feather only
/// appears once the halves are actually parting, so the opening frames remain
/// one unbroken backdrop (source 552-557).
///
/// `feather` is the width of the feathered band, as a percentage of the
/// half's width.
class IntroVeilMask extends StatelessWidget {
  const IntroVeilMask({super.key, required this.isLeft, required this.feather});

  final bool isLeft;

  /// The feathered band's width, as a percentage of the half's width.
  final double feather;

  @override
  Widget build(BuildContext context) {
    if (feather <= 0) return const SizedBox.expand();
    // The band is the LAST `feather` percent of the half: opaque up to
    // (100 - feather)%, then fading to nothing at the edge.
    final edge = (100 - feather) / 100;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => LinearGradient(
        begin: isLeft ? Alignment.centerLeft : Alignment.centerRight,
        end: isLeft ? Alignment.centerRight : Alignment.centerLeft,
        colors: const [Colors.black, Colors.black, Colors.transparent],
        stops: [0.0, edge, 1.0],
      ).createShader(bounds),
      child: const SizedBox.expand(),
    );
  }
}
