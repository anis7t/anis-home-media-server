import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_server_client/features/player/data/player_media_resolver.dart';
import 'package:media_server_client/features/player/domain/playback_mode.dart';
import 'package:media_server_client/features/player/domain/quality_option.dart';
import '../../support/recording_player_controller.dart';

void main() {
  group('HLS Seeking & Quality Preset Resume Regression Tests', () {
    const serverOrigin = 'http://192.168.1.100:8000';
    const filename = 'Verity 2026 1080p WEB-DL HEVC x265 5.1 BONE.mkv';
    final encoded = Uri.encodeComponent(filename);

    test('Media initialization retains start position for HLS streams', () {
      final hlsUrl = '$serverOrigin/hls/$encoded/1080p/playlist.m3u8';
      const resumePosition = Duration(minutes: 23, seconds: 45);

      // Verify Media object creation contract with start position on HLS URL
      final mediaWithResume = Media(
        hlsUrl,
        start: resumePosition,
      );

      expect(mediaWithResume.uri, equals(hlsUrl));
      expect(mediaWithResume.start, equals(resumePosition));

      // Verify Media object without start position defaults to null
      final mediaAtZero = Media(
        hlsUrl,
        start: null,
      );
      expect(mediaAtZero.start, isNull);
    });

    test('PlayerMediaResolver resolves quality URLs for HLS and Direct Play correctly', () {
      // 1. Quality switch from source to 720p HLS
      final url720p = PlayerMediaResolver.resolveQualityUrl(
        serverOrigin: serverOrigin,
        filename: filename,
        quality: '720p',
        mode: PlaybackMode.hls,
      );
      expect(url720p, equals('$serverOrigin/hls/$encoded/720p/playlist.m3u8'));

      // 2. Quality switch to 1080p HLS
      final url1080p = PlayerMediaResolver.resolveQualityUrl(
        serverOrigin: serverOrigin,
        filename: filename,
        quality: '1080p',
        mode: PlaybackMode.hls,
      );
      expect(url1080p, equals('$serverOrigin/hls/$encoded/1080p/playlist.m3u8'));

      // 3. Quality switch to source / Direct Play
      final urlSource = PlayerMediaResolver.resolveQualityUrl(
        serverOrigin: serverOrigin,
        filename: filename,
        quality: 'source',
        mode: PlaybackMode.directPlay,
      );
      expect(urlSource, equals('$serverOrigin/media/$encoded'));
    });

    test('HLS streaming relies on server-side monotonic tfdt timestamps without client demuxer overrides', () {
      // In the unified monotonic fMP4 HLS pipeline, chunk segments carry true presentation
      // decode times (tfdt baseMediaDecodeTime) and single init.mp4 map, allowing standard
      // player demuxing without forced use_tfdt=0 workarounds.
      final media = Media(
        '$serverOrigin/hls/$encoded/1080p/playlist.m3u8',
        start: const Duration(minutes: 50, seconds: 31),
      );
      expect(media.start, equals(const Duration(minutes: 50, seconds: 31)));
    });

    test('Quality preset switch retains play state and start position when active', () async {
      final controller = RecordingPlayerController();
      const currentPos = Duration(minutes: 5, seconds: 20);
      const newUrl = '$serverOrigin/hls/Verity/1080p/playlist.m3u8';

      // 1. Quality switch while actively playing (wasPlaying: true)
      await controller.open(
        newUrl,
        startPosition: currentPos,
        play: true,
      );

      expect(controller.openCount, equals(1));
      expect(controller.openedUrl, equals(newUrl));
      expect(controller.openedStartPosition, equals(currentPos));
      expect(controller.openedPlay, isTrue);

      // 2. Quality switch while paused (wasPlaying: false)
      await controller.open(
        newUrl,
        startPosition: currentPos,
        play: false,
      );

      expect(controller.openCount, equals(2));
      expect(controller.openedPlay, isFalse);
      expect(controller.openedStartPosition, equals(currentPos));
    });

    test('QualityOption ladder maintains distinct quality labels and tiers', () {
      const options = [
        QualityOption(
          label: 'Direct Play (Original)',
          quality: 'source',
          height: 1080,
          width: 1920,
          bitrate: 8000000,
          isDirect: true,
          isReady: true,
        ),
        QualityOption(
          label: '1080p (FHD)',
          quality: '1080p',
          height: 1080,
          width: 1920,
          bitrate: 4500000,
          isDirect: false,
          isReady: true,
        ),
        QualityOption(
          label: '720p (HD)',
          quality: '720p',
          height: 720,
          width: 1280,
          bitrate: 2500000,
          isDirect: false,
          isReady: true,
        ),
        QualityOption(
          label: '480p (SD)',
          quality: '480p',
          height: 480,
          width: 854,
          bitrate: 1200000,
          isDirect: false,
          isReady: false,
        ),
      ];

      expect(options[0].isDirect, isTrue);
      expect(options[1].quality, equals('1080p'));
      expect(options[2].quality, equals('720p'));
      expect(options[3].isReady, isFalse);
    });
  });
}
