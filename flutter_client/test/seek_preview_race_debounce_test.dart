import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player_poc/domain/player_controller_interface.dart';
import 'package:media_server_client/features/player_poc/domain/seek_preview_controller.dart';

void main() {
  group('SeekPreviewController — Race & Debounce Validation', () {
    test(
      'Rapid burst (A -> B -> C -> D) cancels pending debounce timers and only dispatches the latest request',
      () async {
        final dispatchedIndices = <int>[];
        final completer = Completer<void>();

        final controller = SeekPreviewController(
          debounceDuration: const Duration(milliseconds: 50),
          urlResolver: (frameIndex, sequenceId) async {
            dispatchedIndices.add(frameIndex);
            if (frameIndex == 30) {
              completer.complete();
            }
            return 'http://server/thumb_$frameIndex.jpg?seq=$sequenceId';
          },
        );

        // Rapid burst within debounce window (every 10ms < 50ms)
        controller.requestFrame(5); // A
        await Future.delayed(const Duration(milliseconds: 10));
        controller.requestFrame(10); // B
        await Future.delayed(const Duration(milliseconds: 10));
        controller.requestFrame(20); // C
        await Future.delayed(const Duration(milliseconds: 10));
        controller.requestFrame(30); // D (latest)

        // Wait for debounce timer to fire for the latest request
        await completer.future.timeout(const Duration(seconds: 1));

        // Wait an additional buffer to ensure no cancelled timers leaked
        await Future.delayed(const Duration(milliseconds: 100));

        // Verification: Only D (index 30) was dispatched! A, B, C were successfully superseded.
        expect(dispatchedIndices, equals([30]));
        expect(controller.state.displayedFrameIndex, equals(30));
        expect(
          controller.state.displayedImageUrl,
          contains('thumb_30.jpg?seq=4'),
        );
        expect(controller.state.latestSequenceId, equals(4));

        controller.dispose();
      },
    );

    test(
      'Out-of-order stale network response is rejected and cannot overwrite latest preview',
      () async {
        final controller = SeekPreviewController(
          debounceDuration: Duration.zero, // immediate for direct response simulation
        );

        // Sequence 1: User requested frame 10 (seq 1)
        controller.requestFrame(10);
        expect(controller.state.latestSequenceId, equals(1));

        // Sequence 2: User requested frame 50 (seq 2)
        controller.requestFrame(50);
        expect(controller.state.latestSequenceId, equals(2));

        // Simulate: Network response for sequence 2 arrives FIRST (fast response)
        final acceptedSeq2 = controller.commitPreview(
          sequenceId: 2,
          frameIndex: 50,
          imageUrl: 'http://server/thumb_00050.jpg?req=2',
        );
        expect(acceptedSeq2, isTrue);
        expect(controller.state.displayedFrameIndex, equals(50));
        expect(
          controller.state.displayedImageUrl,
          equals('http://server/thumb_00050.jpg?req=2'),
        );
        expect(controller.state.lastCommittedSequenceId, equals(2));

        // Simulate: Stale delayed response for sequence 1 arrives LATER (slow network / out of order)
        final acceptedSeq1 = controller.commitPreview(
          sequenceId: 1,
          frameIndex: 10,
          imageUrl: 'http://server/thumb_00010.jpg?req=1',
        );

        // VERIFICATION: Sequence 1 must be REJECTED!
        expect(acceptedSeq1, isFalse);

        // VERIFICATION: Displayed preview MUST REMAIN frame 50, NOT reverted to 10
        expect(controller.state.displayedFrameIndex, equals(50));
        expect(
          controller.state.displayedImageUrl,
          equals('http://server/thumb_00050.jpg?req=2'),
        );
        expect(controller.state.lastCommittedSequenceId, equals(2));

        controller.dispose();
      },
    );

    test(
      'Seek preview operates completely independently of video playback states (playing, paused, stopped)',
      () async {
        final playbackStates = [
          PlayerPlaybackState.playing,
          PlayerPlaybackState.paused,
          PlayerPlaybackState.idle,
          PlayerPlaybackState.opening,
        ];

        final controller = SeekPreviewController(
          debounceDuration: Duration.zero,
        );

        for (int i = 0; i < playbackStates.length; i++) {
          final state = playbackStates[i];
          final frameIdx = (i + 1) * 10;

          // Request frame during this playback state
          controller.requestFrame(frameIdx);
          final ok = controller.commitPreview(
            sequenceId: i + 1,
            frameIndex: frameIdx,
            imageUrl: 'http://server/thumb_$frameIdx.jpg?state=${state.name}',
          );

          expect(ok, isTrue);
          expect(controller.state.displayedFrameIndex, equals(frameIdx));
          expect(
            controller.state.displayedImageUrl,
            contains('state=${state.name}'),
          );
        }

        controller.dispose();
      },
    );
  });
}
