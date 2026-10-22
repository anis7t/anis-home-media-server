import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player/domain/quality_option.dart';

void main() {
  group('QualityOption Unit Tests', () {
    test('QualityOption.auto defaults', () {
      const auto = QualityOption.auto;
      expect(auto.quality, 'auto');
      expect(auto.label, 'Auto (Adaptive)');
      expect(auto.isDirect, isFalse);
      expect(auto.isReady, isTrue);
      expect(auto.shortBadge, 'HD');
      expect(auto.dimensionsLabel, '');
      expect(auto.formattedBitrate, '');
    });

    test('QualityOption.source helper', () {
      final source = QualityOption.source(height: 1080, width: 1920, bitrate: 8000000);
      expect(source.quality, 'source');
      expect(source.label, 'Original (1080p Direct)');
      expect(source.isDirect, isTrue);
      expect(source.isReady, isTrue);
      expect(source.shortBadge, 'SRC');
      expect(source.dimensionsLabel, '1920×1080');
      expect(source.formattedBitrate, '8.0 Mbps');
    });

    test('QualityOption JSON serialization and deserialization', () {
      final json = {
        'label': '1080p FHD',
        'quality': '1080p',
        'height': 1080,
        'width': 1920,
        'bitrate': 4500000,
        'is_direct': false,
        'is_ready': true,
        'hls_url': '/hls/movie.mkv/1080p/playlist.m3u8',
      };

      final opt = QualityOption.fromJson(json);
      expect(opt.label, '1080p FHD');
      expect(opt.quality, '1080p');
      expect(opt.height, 1080);
      expect(opt.width, 1920);
      expect(opt.bitrate, 4500000);
      expect(opt.isDirect, isFalse);
      expect(opt.isReady, isTrue);
      expect(opt.hlsUrl, '/hls/movie.mkv/1080p/playlist.m3u8');
      expect(opt.shortBadge, '1080P');
      expect(opt.dimensionsLabel, '1920×1080');
      expect(opt.formattedBitrate, '4.5 Mbps');

      final serialized = opt.toJson();
      expect(serialized['label'], '1080p FHD');
      expect(serialized['quality'], '1080p');
      expect(serialized['is_ready'], isTrue);
    });

    test('QualityOption bitrate formatting handles kbps and large mbps', () {
      const kbpsOpt = QualityOption(
        label: '360p',
        quality: '360p',
        height: 360,
        width: 640,
        bitrate: 450000,
        isDirect: false,
        isReady: false,
      );
      expect(kbpsOpt.formattedBitrate, '450 kbps');

      const highMbpsOpt = QualityOption(
        label: '4K',
        quality: '4k',
        height: 2160,
        width: 3840,
        bitrate: 22000000,
        isDirect: false,
        isReady: false,
      );
      expect(highMbpsOpt.formattedBitrate, '22 Mbps');
      expect(highMbpsOpt.shortBadge, '4K');
    });

    test('QualityOption equality and hashing', () {
      const opt1 = QualityOption(
        label: '720p HD',
        quality: '720p',
        height: 720,
        width: 1280,
        bitrate: 2500000,
        isDirect: false,
        isReady: true,
      );
      const opt2 = QualityOption(
        label: '720p HD',
        quality: '720p',
        height: 720,
        width: 1280,
        bitrate: 2500000,
        isDirect: false,
        isReady: true,
      );
      expect(opt1, equals(opt2));
      expect(opt1.hashCode, equals(opt2.hashCode));
    });
  });
}
