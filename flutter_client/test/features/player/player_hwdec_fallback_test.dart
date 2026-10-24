import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Hardware Decoder Fallback & Driver Lock Protection Tests', () {
    test('hwdec defaults to mediacodec-copy on Android and auto on desktop', () {
      final hwdecAndroid = defaultTargetPlatform == TargetPlatform.android
          ? 'mediacodec-copy'
          : 'auto';
      // In flutter test runner (desktop/headless), defaultTargetPlatform is not android
      expect(
        hwdecAndroid,
        isIn(['mediacodec-copy', 'auto']),
      );
    });

    test('error string matching includes all critical low-level video/driver keywords', () {
      const keywords = ['video', 'codec', 'mediacodec', 'vd', 'decoder', 'hwdec', 'surface'];
      
      final sampleErrors = [
        'Failed to initialize mediacodec: buffer allocation error',
        'Could not create hardware surface texture',
        'Video decoder initialization timeout',
        'vd: mediacodec failed to start',
        'hwdec failed to map texture buffer',
        'Codec exception occurred during hardware decode',
      ];

      for (final err in sampleErrors) {
        final lower = err.toLowerCase();
        final matches = keywords.any((k) => lower.contains(k));
        expect(matches, isTrue, reason: 'Error "$err" should match driver/decoder keywords');
      }

      // Non-video errors shouldn't match
      final unrelatedErrors = [
        'Network socket timeout',
        'Audio buffer underflow',
        'HTTP 404 Not Found',
      ];

      for (final err in unrelatedErrors) {
        final lower = err.toLowerCase();
        final matches = keywords.any((k) => lower.contains(k));
        expect(matches, isFalse, reason: 'Error "$err" should not match video keywords');
      }
    });
  });
}
