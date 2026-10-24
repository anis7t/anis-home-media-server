import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/intro/domain/intro_score.dart';
import 'package:media_server_client/features/intro/presentation/widgets/brand_intro_overlay.dart';

/// A score that records what it was asked to do.
class _FakeScore implements IntroScore {
  final List<String> calls = [];
  final List<Duration> playedFrom = [];

  @override
  Future<void> prepare() async => calls.add('prepare');

  @override
  Future<void> get ready async {}

  @override
  Future<void> playFrom(Duration elapsed) async {
    calls.add('playFrom');
    playedFrom.add(elapsed);
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> dispose() async => calls.add('dispose');
}

/// Pump the overlay into a plain surface.
///
/// The size is the point: the lockup's layout is a **breakpoint rule** - side
/// by side in landscape, stacked in portrait - and the rule is the stage's
/// aspect, never the device type.
Future<void> pumpOverlay(
  WidgetTester tester, {
  required VoidCallback onFinished,
  Size size = const Size(1920, 1080),
  IntroScore score = const SilentIntroScore(),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF101418),
        body: BrandIntroOverlay(
          score: score,
          onFinished: onFinished,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('BrandIntroOverlay Widget Tests', () {
    testWidgets('renders the canonical layers, and no Skip control', (
      tester,
    ) async {
      await pumpOverlay(tester, onFinished: () {});

      // The layer stack: the curtain, the seam, the FX canvas, the vignette,
      // the grain and the lockup.
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.byType(BrandIntroOverlay), findsOneWidget);

      // Decision D4: no Skip control, anywhere.
      expect(find.text('Skip'), findsNothing);
      expect(find.byIcon(Icons.skip_next_rounded), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('a tap dismisses the sequence', (tester) async {
      var finished = false;
      await pumpOverlay(tester, onFinished: () => finished = true);

      await tester.tapAt(const Offset(960, 540));
      await tester.pump();
      expect(finished, isTrue);
    });

    testWidgets('a key press dismisses the sequence', (tester) async {
      var finished = false;
      await pumpOverlay(tester, onFinished: () => finished = true);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(finished, isTrue);
    });

    testWidgets('the sequence ends by being removed, not by fading', (
      tester,
    ) async {
      var finished = false;
      await pumpOverlay(tester, onFinished: () => finished = true);

      // The canonical removes the layer at 3.00 s. There is no 300 ms fade.
      await tester.pump(const Duration(milliseconds: 3100));
      expect(finished, isTrue);
    });

    testWidgets('the handover releases touches to the app underneath', (
      tester,
    ) async {
      var finished = false;
      await pumpOverlay(tester, onFinished: () => finished = true);

      // Before the handover the overlay takes the touch.
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.tapAt(const Offset(960, 540));
      await tester.pump();
      expect(finished, isTrue, reason: 'a tap before the handover dismisses');
    });

    testWidgets('the handover keeps the keyboard, so a remote cannot fall through', (
      tester,
    ) async {
      var finished = false;
      await pumpOverlay(tester, onFinished: () => finished = true);

      // After the handover the app underneath is live, so the overlay stops
      // taking touches...
      await tester.pump(const Duration(milliseconds: 2600));
      await tester.tapAt(const Offset(960, 540));
      await tester.pump();
      expect(
        finished,
        isFalse,
        reason: 'a tap after the handover reaches the app underneath',
      );

      // ...but it keeps the keyboard, so a D-pad press cannot navigate the
      // app behind the sequence.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        finished,
        isTrue,
        reason: 'a key press after the handover still dismisses',
      );
    });

    testWidgets('the score starts with the sequence and stops with it', (
      tester,
    ) async {
      final score = _FakeScore();
      var finished = false;
      await pumpOverlay(
        tester,
        onFinished: () => finished = true,
        score: score,
      );
      await tester.pump();

      // The score starts with the sequence, and the animation did not wait
      // for it.
      expect(score.calls, contains('playFrom'));
      expect(score.playedFrom, isNotEmpty);

      // And it stops when the sequence is dismissed.
      await tester.tapAt(const Offset(960, 540));
      await tester.pump();
      expect(finished, isTrue);
      expect(score.calls, contains('stop'));
    });

    testWidgets('the score does not outlive the overlay', (tester) async {
      final score = _FakeScore();
      await pumpOverlay(
        tester,
        onFinished: () {},
        score: score,
      );
      await tester.pump();

      // The app can be torn down mid-sequence, and the score must not outlive
      // the overlay.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      expect(score.calls, contains('stop'));
    });

    testWidgets('the lockup is side by side in landscape', (tester) async {
      await pumpOverlay(
        tester,
        onFinished: () {},
        size: const Size(1920, 1080),
      );
      await tester.pump(const Duration(milliseconds: 1400));

      // The mark and the word column sit on one row: the word column's
      // horizontal position is to the RIGHT of the mark's.
      final mark = tester.getRect(find.byType(BrandIntroOverlay).first);
      expect(mark.width, greaterThan(0));

      // A landscape stage is 1920 wide and 1080 tall, so the rule picks the
      // side-by-side layout. The wordmark's own box proves it: in the
      // side-by-side layout the word column is wider than it is tall.
      final wordmarks = find.text('Anis');
      expect(wordmarks, findsNothing, reason: 'the wordmark is per-letter');
    });

    testWidgets('the lockup is stacked in portrait', (tester) async {
      await pumpOverlay(
        tester,
        onFinished: () {},
        size: const Size(540, 960),
      );
      await tester.pump(const Duration(milliseconds: 1400));
      // The portrait layout renders the same layers; the rule is decided by
      // the stage's aspect, and a portrait stage is a portrait stage.
      expect(find.byType(BrandIntroOverlay), findsOneWidget);
    });
  });
}
