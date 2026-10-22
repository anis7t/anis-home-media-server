import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/intro/presentation/widgets/brand_intro_overlay.dart';

/// The visual comparison: the Flutter client against the archived original.
///
/// The archived frames are the canonical pictures: 90 per aspect, at 30 fps,
/// captured from the archived original over the running application
/// (`docs/opening-sequence/frames/`, `frames-portrait/`).
///
/// ## What is compared, and why only that
///
/// The comparison covers the **closed-curtain window** - every frame up to
/// t = 1.90 s, which is 58 of the 90 frames in each aspect. That window is
/// the whole build-up: the beams, the converging particles, the impact, the
/// burst, the flash, the shockwaves, the standing glow, the sheen, the
/// wordmarks, the subtitle, the rule, the embers, the mark's landing - every
/// effect the previous Flutter implementation painted and then hid under an
/// opaque curtain.
///
/// It is also the window in which the comparison is *exact in principle*:
/// the curtain is opaque, so what is behind it does not matter. The Flutter
/// client and the archived original are two different applications, and the
/// archived frames show the web app through the parting curtain - so the
/// parting window cannot be compared as pictures.
///
/// The parting is not left unproven. Its **geometry** is pinned exactly by
/// the frame fixture (`intro_frame_golden_test.dart`): both halves' travel,
/// both halves' feather, the seam's opacity, the lockup's dismissal, the
/// vignette and the grain, at 69 instants. What the picture comparison adds
/// is that the geometry is not merely right but *drawn* right.
///
/// ## The two frames are compared at the LOGICAL scale
///
/// The archived portrait frames are 1080x1920 **pixels** - a 540x960 layout
/// viewport at a device pixel ratio of 2. A widget test can only capture at
/// the logical size (the golden machinery captures at 1x, and a direct
/// `RenderRepaintBoundary.toImage` never completes inside the test's
/// fake-async zone), so the archived frame is scaled down to the logical size
/// to match. The landscape is at a device pixel ratio of 1 and is compared
/// exactly.
///
/// The scaling is a box average, so the archived frame's one-pixel features -
/// the particles, the embers, the text's edges - are halved in intensity
/// while the Flutter client's are not. That is a real difference in the
/// comparison, and it is part of why the portrait's numbers are a little
/// worse than the landscape's.
///
/// ## What is not compared: the word column
///
/// A Flutter widget test renders text with the **Ahem** test font, whose
/// glyphs are solid squares. The wordmarks therefore cannot be compared as
/// pictures at all - and under Ahem the column is twice as wide as the real
/// one, which would drag the rule out of shape as well. The word column's
/// rectangle is excluded from the comparison; the text's *parameters* are
/// pinned exactly by the frame fixture instead, and this tier is about the
/// curtain, the FX and the mark.
///
/// ## The threshold
///
/// Chromium's rasteriser and Flutter's are not the same, and they never will
/// be: font metrics, gradient interpolation, antialiasing and blend modes all
/// differ. So this is a **perceptual** comparison, not an equality one, and
/// the thresholds were **measured** over every frame of the closed-curtain
/// window and are recorded in the canonical specification - not guessed.
///
/// Two numbers are asserted, and both have to hold:
///  * the **mean** absolute error over the frame, which catches a missing
///    layer or a wrong colour, and
///  * the **share of pixels** within a tolerance, which catches a small but
///    badly wrong region - a missing FX layer would move the mean only a
///    little, but it would move a lot of pixels a lot.
const String kArchivedDir = '../docs/opening-sequence';

/// The tolerance per channel, in 0-255.
const int kPixelTolerance = 32;

/// The last frame in which the curtain is still closed.
const int kLastClosedFrame = 57;

/// The instants the comparison covers by default.
///
/// The full closed-curtain window is available with
/// `MEDIA_SERVER_INTRO_VISUAL=all`.
const List<int> kDefaultFrames = [
  0, 4, 8, 12, 16, 19, 22, 26, 30, 34, 38, 42, 47, 52, 57,
];

/// The archived frames are at 30 fps.
const double kFps = 30;

class _Aspect {
  const _Aspect(this.name, this.dir, this.logical, this.dpr);

  final String name;
  final String dir;

  /// The layout viewport, in logical pixels.
  final Size logical;

  /// The device pixel ratio the archived frames were captured at.
  final double dpr;
}

const _aspects = [
  _Aspect('landscape', 'frames', Size(1920, 1080), 1.0),
  _Aspect('portrait', 'frames-portrait', Size(540, 960), 2.0),
];

Future<ui.Image> _decodePng(File file) async {
  final codec = await ui.instantiateImageCodec(file.readAsBytesSync());
  final frame = await codec.getNextFrame();
  return frame.image;
}

Future<ui.Image> _decodePngBytes(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

/// One frame's comparison.
class _Result {
  const _Result(this.t, this.mean, this.within);

  final double t;
  final double mean;
  final double within;
}

/// Compares each rendered frame with the archived original's.
///
/// The golden-file machinery is used as a **capture**: the comparator is handed
/// the rendered image, and it does the real work. That is deliberate - the
/// golden machinery already knows how to rasterise a widget tree inside the
/// test's fake-async zone, which a direct `toImage` does not.
class _ArchivedComparator extends GoldenFileComparator {
  _ArchivedComparator(this.aspect, this.results, this.exclude);

  final _Aspect aspect;
  final List<_Result> results;

  /// The word column's rectangle, in logical pixels, which is not compared.
  final Rect? exclude;

  @override
  Uri getTestUri(Uri key, int? version) => key;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final name = golden.pathSegments.last;
    final index = int.parse(name.replaceAll('.png', '').replaceAll('f_', ''));
    final t = index / kFps;

    final rendered = await _decodePngBytes(imageBytes);
    final archived = await _decodePng(File('$kArchivedDir/${aspect.dir}/$name'));
    final result = await _compare(rendered, archived, exclude: exclude);
    rendered.dispose();
    archived.dispose();
    results.add(_Result(t, result.mean, result.within));

    // A dump, for looking at a frame that does not match.
    if (Platform.environment['MEDIA_SERVER_INTRO_DUMP'] == '1') {
      final dir = Directory('build/intro-dump/${aspect.name}');
      dir.createSync(recursive: true);
      File('${dir.path}/$name').writeAsBytesSync(imageBytes);
    }
    return true;
  }

  @override
  Future<bool> update(Uri golden, Uint8List imageBytes) =>
      compare(imageBytes, golden);
}

/// The mean absolute error, and the share of pixels within the tolerance.
Future<({double mean, double within})> _compare(
  ui.Image rendered,
  ui.Image archived, {
  Rect? exclude,
}) async {
  final ba = await rendered.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bb = await archived.toByteData(format: ui.ImageByteFormat.rawRgba);
  final da = ba!.buffer.asUint8List();
  final db = bb!.buffer.asUint8List();
  final width = rendered.width;
  final height = rendered.height;
  final factor = archived.width ~/ width;
  if (factor < 1 || archived.height ~/ height != factor) {
    throw StateError(
      'the frames are not in proportion: ${rendered.width}x${rendered.height} '
      'and ${archived.width}x${archived.height}',
    );
  }
  var sum = 0;
  var within = 0;
  var pixels = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (exclude != null &&
          x >= exclude.left &&
          x <= exclude.right &&
          y >= exclude.top &&
          y <= exclude.bottom) {
        continue;
      }
      var worst = 0;
      for (var c = 0; c < 3; c++) {
        // The archived frame's pixel, averaged over the block that maps onto
        // this one.
        var value = 0;
        for (var dy = 0; dy < factor; dy++) {
          for (var dx = 0; dx < factor; dx++) {
            final index =
                (((y * factor + dy) * archived.width) + (x * factor + dx)) * 4;
            value += db[index + c];
          }
        }
        value = (value / (factor * factor)).round();
        final d = (da[(y * width + x) * 4 + c] - value).abs();
        if (d > worst) worst = d;
        sum += d;
      }
      if (worst <= kPixelTolerance) within++;
      pixels++;
    }
  }
  return (
    mean: sum / (pixels * 3),
    within: pixels == 0 ? 0.0 : within / pixels,
  );
}

/// The measured limits.
///
/// They are the measured worst cases over the whole closed-curtain window,
/// with a little headroom: the worst mean error is 12.56 (landscape, the
/// impact) and 11.53 (portrait, the impact), and the worst share of pixels
/// within the tolerance is 89.0 % and 86.5 %.
///
/// The two aspects land in the same place, which is the point: the first
/// portrait measurement was an order of magnitude worse, and the cause was
/// not the design at all - it was comparing a 540x960 capture against a
/// 1080x1920 frame, and so comparing the top-left quarter of one with the
/// whole of the other.
const ({double mean, double within}) kLimits = (mean: 14.0, within: 0.85);

void main() {
  final all = Platform.environment['MEDIA_SERVER_INTRO_VISUAL'] == 'all';
  final frames = all
      ? List<int>.generate(kLastClosedFrame + 1, (i) => i)
      : kDefaultFrames;

  for (final aspect in _aspects) {
    testWidgets('the ${aspect.name} render matches the archived original', (
      tester,
    ) async {
      final dir = Directory('$kArchivedDir/${aspect.dir}');
      if (!dir.existsSync()) {
        fail('The archived frames are missing: ${dir.path}');
      }

      // The layout viewport, and the device pixel ratio the archived frames
      // were captured at.
      tester.view.physicalSize = aspect.logical * aspect.dpr;
      tester.view.devicePixelRatio = aspect.dpr;
      addTearDown(tester.view.reset);

      final overlayKey = GlobalKey<BrandIntroOverlayState>();
      final captureKey = GlobalKey();

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: RepaintBoundary(
            key: captureKey,
            child: BrandIntroOverlay(
              key: overlayKey,
              onFinished: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      final results = <_Result>[];
      // The word column, in logical pixels, which is not compared: the test
      // renders text with the Ahem font, whose glyphs are solid squares.
      Rect? exclude;
      final column = overlayKey.currentState?.wordColumnKey.currentContext
          ?.findRenderObject();
      if (column is RenderBox && column.hasSize) {
        final origin = column.localToGlobal(Offset.zero);
        exclude = origin & column.size;
      }
      goldenFileComparator = _ArchivedComparator(aspect, results, exclude);

      for (final index in frames) {
        final t = index / kFps;
        overlayKey.currentState!.renderAt(t);
        // Let the layout settle, so the FX are centred on the measured mark
        // rather than on the stage.
        await tester.pump();
        await tester.pump();

        await expectLater(
          find.byKey(captureKey),
          matchesGoldenFile(
            '${aspect.name}/f_${index.toString().padLeft(4, '0')}.png',
          ),
        );
      }

      // The report comes first, so a failure shows every frame's numbers and
      // not just the one that broke the limit.
      final report = results
          .map(
            (r) =>
              '  t=${r.t.toStringAsFixed(3)}  mean ${r.mean.toStringAsFixed(2)}  '
              'within ${(r.within * 100).toStringAsFixed(1)}%',
          )
          .join('\n');
      // ignore: avoid_print
      print('\nThe ${aspect.name} sequence, against the archived original:\n'
          '$report\n');

      const limits = kLimits;
      for (final r in results) {
        if (r.mean > limits.mean) {
          fail('at t=${r.t} the mean error is ${r.mean.toStringAsFixed(2)}, over '
              'the ${limits.mean} limit');
        }
        if (r.within < limits.within) {
          fail('at t=${r.t} only ${(r.within * 100).toStringAsFixed(1)}% of the '
              'pixels are within $kPixelTolerance, over the '
              '${(limits.within * 100).toStringAsFixed(1)}% limit');
        }
      }
    });
  }
}
