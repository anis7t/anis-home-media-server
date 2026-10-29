import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The shipped score, and the asset tree it replaced.
///
/// The Flutter client ships the canonical's **offline render** of the score -
/// the web synthesises its own instead (decision D8) - so the file that goes
/// into the APK has to be the canonical's file, byte for byte. A WAV that
/// was re-encoded, re-sampled or truncated would be a different score.
void main() {
  group('the score asset', () {
    test('is shipped as high-bitrate compressed AAC (.m4a)', () {
      final shipped = File('assets/audio/intro-theme.m4a');
      expect(shipped.existsSync(), isTrue, reason: 'the score is not shipped');

      // Verify file is compressed and substantially smaller than the 541KB uncompressed WAV
      final len = shipped.lengthSync();
      expect(len, greaterThan(50 * 1024), reason: 'the score is too small');
      expect(len, lessThan(200 * 1024), reason: 'the score is not properly compressed');

      // Verify MP4/M4A container header (starts with ftyp box)
      final bytes = shipped.readAsBytesSync().sublist(0, 16);
      expect(String.fromCharCodes(bytes.sublist(4, 8)), 'ftyp');
      final ftyp = String.fromCharCodes(bytes.sublist(8, 12));
      expect(ftyp.trim(), anyOf('M4A', 'mp42', 'isom'));
    });

    test('is the one the pubspec declares', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('assets/audio/intro-theme.m4a'));
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
        'assets/audio/intro-theme.m4a',
        'assets/intro/intro-tv-1080p.mp4',
      ]);
    });

    test('carries nothing but the score and the television\'s sequence', () {
      final files = (Directory('assets')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.replaceAll('\\', '/'))
          .toList())
        ..sort();
      expect(files, [
        'assets/audio/intro-theme.m4a',
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
