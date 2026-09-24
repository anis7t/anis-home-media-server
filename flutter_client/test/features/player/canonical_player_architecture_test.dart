import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player/domain/player_controller_interface.dart'
    as prod_domain;
import 'package:media_server_client/features/player/domain/seek_preview_controller.dart'
    as prod_preview;
import 'package:media_server_client/features/player_poc/domain/player_controller_interface.dart'
    as poc_domain;
import 'package:media_server_client/features/player_poc/domain/seek_preview_controller.dart'
    as poc_preview;

void main() {
  group('Phase 3A: Canonical Player Architecture Reconciliation Tests', () {
    test('PlayerControllerInterface exports match across canonical and POC re-exports', () {
      // Test type equivalence through assignment
      const prodTrack = prod_domain.PlayerSubtitleTrack(id: '1', title: 'English');
      const poc_domain.PlayerSubtitleTrack pocTrack = prodTrack;
      expect(pocTrack.id, equals('1'));
      expect(pocTrack.title, equals('English'));

      const prodAudio = prod_domain.PlayerAudioTrack(
        id: '2',
        title: 'English 5.1',
        channels: '5.1',
        codec: 'eac3',
      );
      const poc_domain.PlayerAudioTrack pocAudio = prodAudio;
      expect(pocAudio.id, equals('2'));
      expect(pocAudio.channels, equals('5.1'));

      const prodState = prod_domain.PlayerPlaybackState.playing;
      const poc_domain.PlayerPlaybackState pocState = prodState;
      expect(pocState, equals(poc_domain.PlayerPlaybackState.playing));

      const prodDim = prod_domain.VideoDimensions(1920, 1080);
      const poc_domain.VideoDimensions pocDim = prodDim;
      expect(pocDim.aspectRatio, closeTo(16 / 9, 0.01));
    });

    test('SeekPreviewController functions identically via canonical and POC re-exports', () async {
      final controller = prod_preview.SeekPreviewController(
        debounceDuration: const Duration(milliseconds: 20),
        urlResolver: (frameIndex, seqId) async => 'http://test/thumb_$frameIndex.jpg',
      );

      // Verify type equivalence with POC re-export
      expect(controller, isA<poc_preview.SeekPreviewController>());

      final events = <prod_preview.SeekPreviewState>[];
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
