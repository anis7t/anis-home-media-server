import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player/domain/seek_preview_controller.dart';
import 'package:media_server_client/features/player/presentation/widgets/video_timeline_bar.dart';

void main() {
  group('VideoTimelineBar Widget Tests', () {
    testWidgets('renders timeline track with minimum 48dp touch target height', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: VideoTimelineBar(
                  position: const Duration(minutes: 10),
                  duration: const Duration(minutes: 60),
                  buffered: const Duration(minutes: 20),
                  onSeek: (_) {},
                ),
              ),
            ),
          ),
        ),
      );

      final barFinder = find.byType(VideoTimelineBar);
      expect(barFinder, findsOneWidget);

      final size = tester.getSize(barFinder);
      expect(size.height, greaterThanOrEqualTo(48.0));
      expect(size.width, equals(400.0));
    });

    testWidgets('touch drag scrubbing updates position, triggers onScrubbingChanged, and commits on release', (tester) async {
      Duration? committedSeek;
      final scrubbingEvents = <bool>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: VideoTimelineBar(
                  position: const Duration(minutes: 10),
                  duration: const Duration(minutes: 100), // 6000 seconds
                  buffered: const Duration(minutes: 30),
                  onSeek: (d) => committedSeek = d,
                  onScrubbingChanged: (s) => scrubbingEvents.add(s),
                ),
              ),
            ),
          ),
        ),
      );

      final barFinder = find.byType(VideoTimelineBar);

      // Start drag at x = 100 (which is 25% of 400 => 25 mins = 1500s)
      final centerLeft = tester.getTopLeft(barFinder) + const Offset(100, 24);
      final gesture = await tester.startGesture(centerLeft);
      await tester.pump();

      expect(scrubbingEvents, contains(true));

      // Move to x = 200 (which is 50% of 400 => 50 mins = 3000s)
      await gesture.moveTo(tester.getTopLeft(barFinder) + const Offset(200, 24));
      await tester.pump();

      // Release drag
      await gesture.up();
      await tester.pump();

      expect(scrubbingEvents.last, isFalse);
      expect(committedSeek, isNotNull);
      // 50% of 100 mins is 50 mins = 3000 seconds
      expect(committedSeek!.inMinutes, equals(50));
    });

    testWidgets('triggers debounced frame requests via canonical SeekPreviewController', (tester) async {
      final requestedFrames = <int>[];
      final controller = SeekPreviewController(
        debounceDuration: const Duration(milliseconds: 80),
        urlResolver: (int frameIndex, int sequenceId) async {
          requestedFrames.add(frameIndex);
          return 'http://127.0.0.1:8000/seek-preview/test/thumb_00000.jpg';
        },
      );

      final previewMeta = {
        'duration': 3600.0,
        'interval': 10.0, // 10s per frame
        'count': 360,
        'base_url': '/seek-preview/test',
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: VideoTimelineBar(
                  position: Duration.zero,
                  duration: const Duration(seconds: 3600),
                  seekPreviewController: controller,
                  previewMeta: previewMeta,
                  onSeek: (_) {},
                ),
              ),
            ),
          ),
        ),
      );

      final barFinder = find.byType(VideoTimelineBar);
      final gesture = await tester.startGesture(tester.getTopLeft(barFinder) + const Offset(100, 24));
      await tester.pump();

      // x = 100 is 25% of 3600s = 900s.
      // frameIndex = 900 / 10 = 90.
      expect(controller.state.targetFrameIndex, equals(90));
      expect(controller.state.isPendingDebounce, isTrue);

      // Fast forward past 80ms debounce
      await tester.pump(const Duration(milliseconds: 100));

      expect(requestedFrames, contains(90));
      expect(controller.state.isPendingDebounce, isFalse);

      await gesture.up();
      await tester.pump();
      controller.dispose();
    });

    testWidgets('preview card clamps within screen horizontal boundaries', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: VideoTimelineBar(
                  position: Duration.zero,
                  duration: const Duration(minutes: 60),
                  onSeek: (_) {},
                ),
              ),
            ),
          ),
        ),
      );

      final barFinder = find.byType(VideoTimelineBar);

      // 1. Drag near left edge (move by > 18px touch slop)
      final gesture = await tester.startGesture(tester.getTopLeft(barFinder) + const Offset(10, 24));
      await gesture.moveTo(tester.getTopLeft(barFinder) + const Offset(40, 24));
      await tester.pump();

      // Find the preview card Container (40/400 * 3600s = 360s = 6:00)
      expect(find.text('6:00'), findsOneWidget);

      // 2. Drag to far right (x = 390 => 390/400 * 3600s = 3510s = 58:30)
      await gesture.moveTo(tester.getTopLeft(barFinder) + const Offset(390, 24));
      await tester.pump();

      expect(find.text('58:30'), findsOneWidget);

      await gesture.up();
      await tester.pump();
    });

    testWidgets('gracefully falls back to timestamp-only preview when metadata is null', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: VideoTimelineBar(
                  position: Duration.zero,
                  duration: const Duration(minutes: 10),
                  previewMeta: null, // No metadata
                  onSeek: (_) {},
                ),
              ),
            ),
          ),
        ),
      );

      final barFinder = find.byType(VideoTimelineBar);
      final gesture = await tester.startGesture(tester.getTopLeft(barFinder) + const Offset(180, 24));
      await gesture.moveTo(tester.getTopLeft(barFinder) + const Offset(200, 24));
      await tester.pump();

      // Timestamp at 50% (x=200 of 400) of 10m is 5:00
      expect(find.text('5:00'), findsOneWidget);
      // No Image widget is rendered
      expect(find.byType(Image), findsNothing);

      await gesture.up();
      await tester.pump();
    });

    testWidgets('Windows mouse hover displays preview card without seeking', (tester) async {
      Duration? seekCommit;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: VideoTimelineBar(
                  position: const Duration(minutes: 2),
                  duration: const Duration(minutes: 20),
                  onSeek: (d) => seekCommit = d,
                ),
              ),
            ),
          ),
        ),
      );

      final barFinder = find.byType(VideoTimelineBar);

      // Simulate mouse hover at 50% (x = 200 => 10:00)
      final testPointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(testPointer.hover(tester.getTopLeft(barFinder) + const Offset(200, 24)));
      await tester.pump();

      // Preview card is visible with 10:00
      expect(find.text('10:00'), findsOneWidget);
      // Seek was NOT committed on hover
      expect(seekCommit, isNull);

      // Move mouse off the widget
      await tester.sendEventToBinding(testPointer.hover(const Offset(10, 10)));
      await tester.pump();

      // Preview card disappears
      expect(find.text('10:00'), findsNothing);
    });
  });
}
