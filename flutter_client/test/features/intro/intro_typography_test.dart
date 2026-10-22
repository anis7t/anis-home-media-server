import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/intro/domain/intro_score.dart';
import 'package:media_server_client/features/intro/presentation/widgets/brand_intro_overlay.dart';

/// **The sequence's typography is not the ambient style's to decide** (D27).
///
/// The defect this pins, as it was seen on the phone: **double yellow
/// underlines under every wordmark**, which the canonical has in neither
/// aspect. The cause is `DefaultTextStyle.merge`, which takes the ambient
/// style's decoration with it, and the ambient style on that device carried
/// one.
///
/// **The picture oracle cannot see this class of fault.** A test's ambient
/// style never carries a decoration, so a golden that renders the overlay in a
/// bare `MaterialApp` is clean by construction and stays clean after the rule
/// is deleted. This test therefore supplies the worst ambient style it can -
/// underlined, yellow, double, at a size of its own - and asserts that
/// **nothing the sequence paints inherits any of it**.
///
/// The rule it protects is in `brand_intro_overlay.dart`: the wordmark's
/// merged style sets `decoration: TextDecoration.none`, and so does the
/// subtitle's own style.
void main() {
  /// An ambient style with everything the sequence must refuse.
  const ambient = TextStyle(
    fontSize: 14,
    decoration: TextDecoration.underline,
    decorationColor: Color(0xFFFFFF00),
    decorationStyle: TextDecorationStyle.double,
  );

  /// Pump the overlay with that ambient style directly above it - the same
  /// position the app's own style occupies, inside the material surface.
  Future<void> pumpUnderADecoratedStyle(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DefaultTextStyle(
            style: ambient,
            child: BrandIntroOverlay(
              score: const SilentIntroScore(),
              onFinished: () {},
            ),
          ),
        ),
      ),
    );
    // The wordmarks land at 1.35 s; 1.6 s is inside the sequence, with the
    // lockup at full opacity.
    await tester.pump(const Duration(milliseconds: 1600));
  }

  /// Every text span the sequence has painted, with its **resolved** style.
  ///
  /// `RichText.text.style` is the style after the `Text` widget has merged its
  /// own with the ambient one, so this is what the glyphs are painted with -
  /// not what some widget asked for.
  List<TextSpan> paintedSpans(WidgetTester tester) => [
    for (final rich in tester.widgetList<RichText>(find.byType(RichText)))
      if (rich.text is TextSpan) rich.text as TextSpan,
  ];

  group('the sequence owns its typography', () {
    // Both aspects: the lockup is side by side in landscape and stacked in
    // portrait, and the rule must hold in whichever arrangement the stage
    // chose.
    for (final size in const [Size(1080, 2400), Size(1920, 1080)]) {
      final label = '${size.width.toInt()}x${size.height.toInt()}';
      testWidgets('no painted text inherits a decoration at $label', (
        tester,
      ) async {
        await pumpUnderADecoratedStyle(tester, size);

        final spans = paintedSpans(tester);
        expect(
          spans.length,
          greaterThanOrEqualTo(10),
          reason:
              'the lockup paints its letters individually, so there is no '
              'small set of spans to check by accident',
        );

        for (final span in spans) {
          expect(
            // A span that never set a decoration is the failure: it kept the
            // ambient one.
            span.style?.decoration ?? TextDecoration.none,
            TextDecoration.none,
            reason:
                'this span kept the ambient decoration: "${span.text}"',
          );
        }
      });
    }

    testWidgets('the subtitle keeps its own colour, not the ambient one', (
      tester,
    ) async {
      await pumpUnderADecoratedStyle(tester, const Size(1080, 2400));

      final subtitle = find.textContaining('ORGANIZE');
      expect(subtitle, findsOneWidget);
      final rich = tester.widget<RichText>(
        find.descendant(of: subtitle, matching: find.byType(RichText)),
      );
      final style = (rich.text as TextSpan).style!;

      // #94A3B8, the canonical's subtitle colour, and the sequence's own size.
      expect(style.color, const Color(0xFF94A3B8));
      expect(style.decoration, TextDecoration.none);
      // The ambient style's 14 px must not win either.
      expect(style.fontSize, isNot(14.0));
    });
  });
}
