import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player/domain/playback_mode.dart';
import 'package:media_server_client/features/player/infrastructure/player_media_resolver.dart';

void main() {
  group('PlayerMediaResolver.resolveQualityUrl Tests', () {
    const serverOrigin = 'http://192.168.1.100:8000';
    const filename = 'Ghost.in.the.Cell.2026.2160p.NF.WEB-DL.DDP5.1.H.265-PandaQT.mkv';
    final encoded = Uri.encodeComponent(filename);

    test('resolves explicit source quality to /media/ endpoint', () {
      final url = PlayerMediaResolver.resolveQualityUrl(
        serverOrigin: serverOrigin,
        filename: filename,
        quality: 'source',
        mode: PlaybackMode.directPlay,
      );
      expect(url, '$serverOrigin/media/$encoded');
    });

    test('resolves auto quality in directPlay mode to /media/ endpoint', () {
      final url = PlayerMediaResolver.resolveQualityUrl(
        serverOrigin: serverOrigin,
        filename: filename,
        quality: 'auto',
        mode: PlaybackMode.directPlay,
      );
      expect(url, '$serverOrigin/media/$encoded');
    });

    test('resolves auto quality in hls mode to master.m3u8', () {
      final url = PlayerMediaResolver.resolveQualityUrl(
        serverOrigin: serverOrigin,
        filename: filename,
        quality: 'auto',
        mode: PlaybackMode.hls,
      );
      expect(url, '$serverOrigin/hls/$encoded/master.m3u8');
    });

    test('smart-routes 2160p to Direct Play when isNative4K is true and mode is directPlay', () {
      final url = PlayerMediaResolver.resolveQualityUrl(
        serverOrigin: serverOrigin,
        filename: filename,
        quality: '2160p',
        mode: PlaybackMode.directPlay,
        isNative4K: true,
      );
      expect(url, '$serverOrigin/media/$encoded');
    });

    test('routes 2160p to HLS playlist when mode is hls', () {
      final url = PlayerMediaResolver.resolveQualityUrl(
        serverOrigin: serverOrigin,
        filename: filename,
        quality: '2160p',
        mode: PlaybackMode.hls,
        isNative4K: true,
      );
      expect(url, '$serverOrigin/hls/$encoded/2160p/playlist.m3u8');
    });

    test('routes 1080p to HLS tier playlist regardless of isNative4K', () {
      final url = PlayerMediaResolver.resolveQualityUrl(
        serverOrigin: serverOrigin,
        filename: filename,
        quality: '1080p',
        mode: PlaybackMode.directPlay,
        isNative4K: true,
      );
      expect(url, '$serverOrigin/hls/$encoded/1080p/playlist.m3u8');
    });
  });
}
