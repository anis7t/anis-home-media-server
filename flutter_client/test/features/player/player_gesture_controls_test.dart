import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player/presentation/widgets/double_tap_seek_detector.dart';

/// Vertical-swipe controls: the left half of the surface drives brightness and
/// the right half volume. The property that matters is that they coexist with
/// the gestures already in place - a drag must never be mistaken for a tap
/// (which toggles the controls / play-pause) or a double-tap (which seeks).
///
/// The detector reports a *cumulative* fraction: the caller applies it as an
/// offset from the value captured at drag start, so the last value is what
/// matters, not the sum.
void main() {
  const box = Size(500, 300);

  Future<void> pumpDetector(
    WidgetTester tester, {
    void Function(double fraction, bool fromLeftHalf)? onDelta,
    void Function(bool fromLeftHalf)? onBegin,
    VoidCallback? onTap,
    VoidCallback? onRewind,
    VoidCallback? onForward,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: box.width,
              height: box.height,
              child: DoubleTapSeekDetector(
                onDoubleTapRewind: onRewind ?? () {},
                onDoubleTapForward: onForward ?? () {},
                onTap: onTap,
                onVerticalDragBegin: onBegin,
                onVerticalDragDelta: onDelta,
                child: Container(color: Colors.blue),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Offset pointIn(WidgetTester tester, double x, double y) =>
      tester.getTopLeft(find.byType(DoubleTapSeekDetector)) + Offset(x, y);

  testWidgets('swiping up on the left half reports a positive fraction', (tester) async {
    var last = 0.0;
    bool? fromLeft;
    await pumpDetector(
      tester,
      onBegin: (left) => fromLeft = left,
      onDelta: (fraction, left) => last = fraction,
    );

    await tester.dragFrom(pointIn(tester, 100, 200), const Offset(0, -120));
    await tester.pump(const Duration(milliseconds: 400));

    expect(fromLeft, isTrue);
    expect(
      last,
      greaterThan(0.25),
      reason: '120 px of a 300 px surface, less touch slop',
    );
    expect(last, lessThan(0.45));
  });

  testWidgets('swiping up on the right half reports a positive fraction', (tester) async {
    var last = 0.0;
    bool? fromLeft;
    await pumpDetector(
      tester,
      onBegin: (left) => fromLeft = left,
      onDelta: (fraction, left) => last = fraction,
    );

    await tester.dragFrom(pointIn(tester, 400, 200), const Offset(0, -120));
    await tester.pump(const Duration(milliseconds: 400));

    expect(fromLeft, isFalse);
    expect(last, greaterThan(0.25));
  });

  testWidgets('a drag accumulates rather than reporting one frame', (tester) async {
    final values = <double>[];
    await pumpDetector(tester, onDelta: (fraction, left) => values.add(fraction));

    // A real finger drag arrives as many move events; tester.dragFrom sends one,
    // so drive the gesture step by step. The reported fraction must be the running
    // total of the whole drag, not the last frame's movement.
    final gesture = await tester.startGesture(pointIn(tester, 100, 260));
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));

    expect(values.length, greaterThanOrEqualTo(2),
        reason: 'the drag is reported as it moves');
    expect(
      values.last,
      greaterThan(values.first),
      reason: 'later reports must include the earlier travel, not just one frame',
    );
    expect(values.last, greaterThan(0.3), reason: 'a meaningful fraction of the surface');
  });

  testWidgets('swiping down reports a negative fraction', (tester) async {
    var last = 0.0;
    await pumpDetector(tester, onDelta: (fraction, left) => last = fraction);

    await tester.dragFrom(pointIn(tester, 100, 100), const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 400));

    expect(last, lessThan(-0.25));
  });

  testWidgets('a vertical drag never fires tap or double-tap seeking', (tester) async {
    var taps = 0;
    var rewinds = 0;
    var forwards = 0;
    await pumpDetector(
      tester,
      onDelta: (fraction, left) {},
      onTap: () => taps++,
      onRewind: () => rewinds++,
      onForward: () => forwards++,
    );

    await tester.dragFrom(pointIn(tester, 100, 220), const Offset(0, -150));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.dragFrom(pointIn(tester, 400, 220), const Offset(0, 150));
    await tester.pump(const Duration(milliseconds: 400));

    expect(taps, 0);
    expect(rewinds, 0);
    expect(forwards, 0);
  });

  testWidgets('tap and double-tap still work with the drag gesture enabled', (tester) async {
    var taps = 0;
    var rewinds = 0;
    await pumpDetector(
      tester,
      onDelta: (fraction, left) {},
      onTap: () => taps++,
      onRewind: () => rewinds++,
    );

    await tester.tap(find.byType(DoubleTapSeekDetector));
    await tester.pump(const Duration(milliseconds: 400));
    expect(taps, 1, reason: 'a tap still toggles the controls');

    final left = pointIn(tester, 100, 150);
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(left);
    await tester.pump(const Duration(milliseconds: 400));
    expect(rewinds, 1, reason: 'a double-tap on the left still seeks back');
  });

  testWidgets('without a drag callback the gesture stays inert', (tester) async {
    var taps = 0;
    await pumpDetector(tester, onTap: () => taps++);

    await tester.dragFrom(pointIn(tester, 100, 200), const Offset(0, -120));
    await tester.pump(const Duration(milliseconds: 400));

    expect(taps, 0, reason: 'a drag is not a tap, wired or not');
  });
}
