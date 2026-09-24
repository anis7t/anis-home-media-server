import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player/presentation/widgets/double_tap_seek_detector.dart';

void main() {
  group('DoubleTapSeekDetector Widget Tests', () {
    testWidgets('double-tap on left 40% invokes onDoubleTapRewind and shows ripple', (tester) async {
      int rewindCalls = 0;
      int forwardCalls = 0;
      int tapCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 500,
                height: 300,
                child: DoubleTapSeekDetector(
                  onDoubleTapRewind: () => rewindCalls++,
                  onDoubleTapForward: () => forwardCalls++,
                  onTap: () => tapCalls++,
                  child: Container(color: Colors.blue),
                ),
              ),
            ),
          ),
        ),
      );

      final detectorFinder = find.byType(DoubleTapSeekDetector);
      final topLeft = tester.getTopLeft(detectorFinder);

      // Left 20% point (x = 100 on 500w box)
      final leftPoint = topLeft + const Offset(100, 150);

      // Perform double tap
      await tester.tapAt(leftPoint);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(leftPoint);
      await tester.pump();

      expect(rewindCalls, equals(1));
      expect(forwardCalls, equals(0));
      expect(find.byIcon(Icons.fast_rewind_rounded), findsOneWidget);
      expect(find.text('10 seconds'), findsOneWidget);

      // Fast forward past ripple dismiss timer (650ms)
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byIcon(Icons.fast_rewind_rounded), findsNothing);
    });

    testWidgets('double-tap on right 40% invokes onDoubleTapForward and shows ripple', (tester) async {
      int rewindCalls = 0;
      int forwardCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 500,
                height: 300,
                child: DoubleTapSeekDetector(
                  onDoubleTapRewind: () => rewindCalls++,
                  onDoubleTapForward: () => forwardCalls++,
                  child: Container(color: Colors.blue),
                ),
              ),
            ),
          ),
        ),
      );

      final detectorFinder = find.byType(DoubleTapSeekDetector);
      final topLeft = tester.getTopLeft(detectorFinder);

      // Right 80% point (x = 400 on 500w box)
      final rightPoint = topLeft + const Offset(400, 150);

      // Perform double tap
      await tester.tapAt(rightPoint);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(rightPoint);
      await tester.pump();

      expect(forwardCalls, equals(1));
      expect(rewindCalls, equals(0));
      expect(find.byIcon(Icons.fast_forward_rounded), findsOneWidget);
      expect(find.text('10 seconds'), findsOneWidget);

      // Fast forward past ripple dismiss timer
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byIcon(Icons.fast_forward_rounded), findsNothing);
    });

    testWidgets('double-tap in center 20% does not seek', (tester) async {
      int rewindCalls = 0;
      int forwardCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 500,
                height: 300,
                child: DoubleTapSeekDetector(
                  onDoubleTapRewind: () => rewindCalls++,
                  onDoubleTapForward: () => forwardCalls++,
                  child: Container(color: Colors.blue),
                ),
              ),
            ),
          ),
        ),
      );

      final detectorFinder = find.byType(DoubleTapSeekDetector);
      final topLeft = tester.getTopLeft(detectorFinder);

      // Center 50% point (x = 250 on 500w box)
      final centerPoint = topLeft + const Offset(250, 150);

      // Perform double tap in center
      await tester.tapAt(centerPoint);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(centerPoint);
      await tester.pump();

      expect(rewindCalls, equals(0));
      expect(forwardCalls, equals(0));
      expect(find.byIcon(Icons.fast_rewind_rounded), findsNothing);
      expect(find.text('10 seconds'), findsNothing);

      // Advance clock past double tap timeout to clear pending timers
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('single tap triggers onTap callback', (tester) async {
      int tapCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 500,
                height: 300,
                child: DoubleTapSeekDetector(
                  onDoubleTapRewind: () {},
                  onDoubleTapForward: () {},
                  onTap: () => tapCalls++,
                  child: Container(color: Colors.blue),
                ),
              ),
            ),
          ),
        ),
      );

      final detectorFinder = find.byType(DoubleTapSeekDetector);
      await tester.tap(detectorFinder);
      // Wait for double-tap disambiguation timeout (300ms in Flutter GestureDetector)
      await tester.pump(const Duration(milliseconds: 350));

      expect(tapCalls, equals(1));
    });
  });
}
