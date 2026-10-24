import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/intro/presentation/widgets/brand_intro_overlay.dart';

/// The responsive sweep (decision D7).
///
/// The sequence is resolution-independent by construction - everything is
/// expressed in the design unit, `min(w, h) / 100`, with clamps - and this is
/// what proves it at the aspects the sweep visits.
///
/// The **breakpoint** is the stage's own aspect, never the device type: a
/// phone in landscape gets the side-by-side lockup, and a television would get
/// the stacked one if it were ever held in portrait.
class _Aspect {
  const _Aspect(this.name, this.size, this.dpr, this.portrait);

  final String name;

  /// The layout viewport, in logical pixels.
  final Size size;

  final double dpr;

  /// Whether the stage is portrait, and so whether the lockup stacks.
  final bool portrait;

  /// The design unit: `min(w, h) / 100`.
  double get u => (size.width < size.height ? size.width : size.height) / 100;
}

const _aspects = [
  _Aspect('portrait', Size(540, 960), 2.0, true),
  _Aspect('landscape', Size(1920, 1080), 1.0, false),
  _Aspect('ultrawide', Size(2560, 1080), 1.0, false),
  _Aspect('tablet', Size(1024, 1366), 2.0, true),
  _Aspect('phone-tall', Size(1080, 2400), 3.0, true),
];

/// Load a real font, so the wordmarks are measured as wordmarks.
///
/// A Flutter widget test renders text in **Ahem** - whose glyphs are solid
/// squares of the font's size - so "Home Media Server" is twice as wide as it
/// is on any device, and a layout test measures a layout nothing has. The
/// canonical's own font stack names Segoe UI, and the archived frames were
/// captured on a Windows host, so Segoe UI is both realistic and the closest
/// match to the reference.
const String kTestFontFamily = 'Segoe UI';

Future<void> _loadRealFont() async {
  const candidates = [
    r'C:\Windows\Fonts\segoeui.ttf',
    r'C:\Windows\Fonts\arial.ttf',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = file.readAsBytesSync();
    final loader = FontLoader(kTestFontFamily)
      ..addFont(
        Future<ByteData>.value(ByteData.view(bytes.buffer)),
      );
    await loader.load();
    return;
  }
  // No real font on this host: the test still runs, in Ahem.
}

void main() {
  setUpAll(_loadRealFont);

  for (final aspect in _aspects) {
    group('the ${aspect.name} stage (${aspect.size.width.toInt()}x'
        '${aspect.size.height.toInt()} at DPR ${aspect.dpr})', () {
      testWidgets('lays the lockup out on the breakpoint, and it fits', (
        tester,
      ) async {
        tester.view.physicalSize = aspect.size * aspect.dpr;
        tester.view.devicePixelRatio = aspect.dpr;
        addTearDown(tester.view.reset);

        final overlayKey = GlobalKey<BrandIntroOverlayState>();
        await tester.pumpWidget(
          DefaultTextStyle(
            style: const TextStyle(fontFamily: kTestFontFamily),
            child: MaterialApp(
              home: Scaffold(
                backgroundColor: const Color(0xFF101418),
                body: BrandIntroOverlay(
                  key: overlayKey,
                  onFinished: () {},
                ),
              ),
            ),
          ),
        );
        // A second frame, so the layout has settled and the measurements are
        // of the real thing.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1400));

        // The mark and the word column.
        final mark = tester.getRect(
          find.byKey(overlayKey.currentState!.iconKey),
        );
        final words = tester.getRect(
          find.byKey(overlayKey.currentState!.wordColumnKey),
        );

        // **The breakpoint.** Side by side in landscape, stacked in portrait -
        // and the rule is the stage's aspect, not the device.
        if (aspect.portrait) {
          expect(
            words.top,
            greaterThan(mark.bottom),
            reason: 'the lockup stacks in portrait, so the words are BELOW the mark',
          );
          expect(
            words.center.dx,
            closeTo(mark.center.dx, 1.0),
            reason: 'a stacked lockup is centred',
          );
        } else {
          expect(
            words.left,
            greaterThan(mark.right),
            reason: 'the lockup is side by side in landscape, so the words are '
                'to the RIGHT of the mark',
          );
          expect(
            words.center.dy,
            closeTo(mark.center.dy, 1.0),
            reason: 'a side-by-side lockup is centred on its row',
          );
        }

        // **The clamps.** The canonical's sizes are `clamp(min, u * k, max)`.
        expect(
          mark.width,
          inInclusiveRange(64.0, 118.0),
          reason: 'the mark is clamped to 64..118 px',
        );
        expect(
          mark.width,
          closeTo((aspect.u * 10.5).clamp(64.0, 118.0), 0.5),
          reason: 'the mark is u * 10.5, clamped',
        );

        final wordmark = tester.widget<Text>(
          find.descendant(
            of: find.byKey(overlayKey.currentState!.wordColumnKey),
            matching: find.byType(Text),
          ).first,
        );
        final fontSize = wordmark.style?.fontSize ?? 0;
        expect(
          fontSize,
          inInclusiveRange(30.0, 66.0),
          reason: 'the wordmark is clamped to 30..66 px',
        );
        expect(
          fontSize,
          closeTo((aspect.u * 5.7).clamp(30.0, 66.0), 0.01),
          reason: 'the wordmark is u * 5.7, clamped',
        );

        // **It fits.** A RenderFlex that overflows reports an error, and the
        // test framework fails the test on it - so reaching here is the check.
        expect(
          tester.takeException(),
          isNull,
          reason: 'the lockup fits at this aspect',
        );
      });
    });
  }
}
