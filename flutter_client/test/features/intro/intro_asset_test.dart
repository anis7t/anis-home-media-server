import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shipped score, and the asset tree it replaced.
///
/// The Flutter client ships the canonical's **offline render** of the score -
/// the web synthesises its own instead (decision D8) - so the file that goes
/// into the APK has to be the canonical's file, byte for byte. A WAV that
/// was re-encoded, re-sampled or truncated would be a different score.
void main() {
  group('the score asset', () {
    test('is the canonical\'s, byte for byte', () {
      final shipped = File('assets/audio/intro-theme.wav');
      final canonical =
          File('../docs/opening-sequence/assets/intro-theme.wav');

      expect(shipped.existsSync(), isTrue, reason: 'the score is not shipped');
      expect(canonical.existsSync(), isTrue, reason: 'the canonical is gone');

      final shippedHash = sha256.convert(shipped.readAsBytesSync()).toString();
      final canonicalHash =
          sha256.convert(canonical.readAsBytesSync()).toString();

      expect(
        shippedHash,
        canonicalHash,
        reason: 'the shipped score is not the canonical\'s file',
      );
    });

    test('is the one the pubspec declares', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('assets/audio/intro-theme.wav'));
    });

    test('is 44.1 kHz, 16-bit, stereo, and 3.070 s long', () {
      // The canonical's measurements: 3.070 s, 44.1 kHz stereo, peak
      // -2.98 dBFS, RMS -19.00 dBFS.
      final bytes = File('assets/audio/intro-theme.wav').readAsBytesSync();
      // A RIFF/WAVE header: "RIFF" .... "WAVE" "fmt " ... "data"
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');

      final channels = bytes[22] | (bytes[23] << 8);
      final sampleRate = bytes[24] |
          (bytes[25] << 8) |
          (bytes[26] << 16) |
          (bytes[27] << 24);
      final bitsPerSample = bytes[34] | (bytes[35] << 8);

      expect(channels, 2, reason: 'the canonical is stereo');
      expect(sampleRate, 44100, reason: 'the canonical is 44.1 kHz');
      expect(bitsPerSample, 16, reason: 'the canonical is 16-bit');

      final dataSize = bytes[40] |
          (bytes[41] << 8) |
          (bytes[42] << 16) |
          (bytes[43] << 24);
      final seconds = dataSize / (sampleRate * channels * bitsPerSample / 8);
      expect(seconds, closeTo(3.070, 0.001));
    });
  });

  group('the asset tree', () {
    test('no longer carries the dead video', () {
      // `assets/videos/intro-demo-portrait.mp4` was declared in the pubspec,
      // never played, and cost 2.4 MB in every APK.
      expect(
        File('assets/videos/intro-demo-portrait.mp4').existsSync(),
        isFalse,
      );
      expect(Directory('assets/videos').existsSync(), isFalse);
    });

    test('declares the score and the television\'s sequence', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final assets = pubspec
          .split('assets:')
          .last
          .split('\n')
          .where((l) => l.trim().startsWith('- '))
          .map((l) => l.trim().substring(2).trim())
          .toList();
      expect(assets, [
        'assets/audio/intro-theme.wav',
        'assets/intro/intro-tv-1080p.mp4',
      ]);
    });

    test('carries nothing but the score and the television\'s sequence', () {
      final files = Directory('assets')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.replaceAll('\\', '/'))
          .toList();
      expect(files, [
        'assets/audio/intro-theme.wav',
        'assets/intro/intro-tv-1080p.mp4',
      ]);
    });
  });

  group('the television\'s sequence', () {
    test('is shipped, and it is an H.264 MP4', () {
      final video = File('assets/intro/intro-tv-1080p.mp4');
      expect(video.existsSync(), isTrue, reason: 'the video is not shipped');
      expect(
        video.lengthSync(),
        greaterThan(100 * 1024),
        reason: 'the video is too small to be three seconds of 1080p',
      );

      // An MP4 starts with an "ftyp" box, and the brand's file is H.264 -
      // which is the only profile every Android device decodes, and the
      // television's decoder is nine years old.
      final head = video.readAsBytesSync().sublist(0, 64);
      expect(String.fromCharCodes(head.sublist(4, 8)), 'ftyp');
      final brand = String.fromCharCodes(head);
      expect(brand, contains('avc1'), reason: 'the video is not H.264');
    });
  });
}
