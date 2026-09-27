import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';

/// The server's `parse_user_agent` classifies this client from the UA string:
/// `Android <ver>` gives the OS, and only a `Mobile` token makes it a phone
/// (without it the Connected Devices dashboard reports "Android Tablet").
void main() {
  group('buildClientUserAgent', () {
    test('Android reports the version and the Mobile token', () {
      expect(
        buildClientUserAgent(
          isWeb: false,
          platformName: 'Android',
          operatingSystemVersion: 'Android 16, API level 36',
        ),
        'MediaServer-Flutter/1.0 (Android 16; Mobile; Dart)',
      );
    });

    test('Android without a parseable version still declares Mobile', () {
      expect(
        buildClientUserAgent(
          isWeb: false,
          platformName: 'Android',
          operatingSystemVersion: 'unknown build',
        ),
        'MediaServer-Flutter/1.0 (Android; Mobile; Dart)',
      );
    });

    test('Android API-36 style version strings still yield the version', () {
      // The device reports "16, API level 36" - no "Android" prefix.
      expect(
        buildClientUserAgent(
          isWeb: false,
          platformName: 'Android',
          operatingSystemVersion: '16, API level 36',
        ),
        'MediaServer-Flutter/1.0 (Android 16; Mobile; Dart)',
      );
    });

    test('desktop and web platforms keep the plain form', () {
      expect(
        buildClientUserAgent(
          isWeb: false,
          platformName: 'Windows',
          operatingSystemVersion: 'Windows 10.0.22631',
        ),
        'MediaServer-Flutter/1.0 (Windows; Dart)',
      );
      expect(
        buildClientUserAgent(
          isWeb: true,
          platformName: 'Web',
          operatingSystemVersion: '',
        ),
        'MediaServer-Flutter/1.0 (Web; Dart)',
      );
    });
  });
}
