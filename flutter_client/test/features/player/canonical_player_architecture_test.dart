import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player/domain/player_controller_interface.dart';
import 'package:media_server_client/features/player/domain/seek_preview_controller.dart';

void main() {
  group('Canonical Player Architecture Tests', () {
    test('PlayerControllerInterface and domain models initialize correctly', () {
      const prodTrack = PlayerSubtitleTrack(id: '1', title: 'English');
      expect(prodTrack.id, equals('1'));
      expect(prodTrack.title, equals('English'));

      const prodAudio = PlayerAudioTrack(
        id: '2',
        title: 'English 5.1',
        channels: '5.1',
        codec: 'eac3',
      );
      expect(prodAudio.id, equals('2'));
      expect(prodAudio.channels, equals('5.1'));

      const prodState = PlayerPlaybackState.playing;
      expect(prodState, equals(PlayerPlaybackState.playing));

      const prodDim = VideoDimensions(1920, 1080);
      expect(prodDim.aspectRatio, closeTo(16 / 9, 0.01));
    });

    test('SeekPreviewController functions correctly in isolation', () async {
      final controller = SeekPreviewController(
        debounceDuration: const Duration(milliseconds: 20),
        urlResolver: (frameIndex, seqId) async => 'http://test/thumb_$frameIndex.jpg',
      );

      final events = <SeekPreviewState>[];
      controller.requestFrame(10);
      events.add(controller.state);

      expect(controller.state.targetFrameIndex, equals(10));
      expect(controller.state.isPendingDebounce, isTrue);

      await Future.delayed(const Duration(milliseconds: 50));
      expect(controller.state.displayedFrameIndex, equals(10));
      expect(controller.state.displayedImageUrl, equals('http://test/thumb_10.jpg'));
      expect(controller.state.isPendingDebounce, isFalse);

      controller.dispose();
    });
  });
}
