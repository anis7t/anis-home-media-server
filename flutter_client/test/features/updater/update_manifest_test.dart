import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/models/app_channel.dart';
import 'package:media_server_client/features/updater/data/models/update_manifest.dart';

void main() {
  group('UpdateManifest Fail-Closed Validation Tests', () {
    const validJson = {
      'channel': 'developer',
      'version': '1.1.0-dev.101',
      'versionCode': 101,
      'releaseDate': '2026-09-26T04:00:00Z',
      'minAndroidSdk': 26,
      'targetAndroidSdk': 36,
      'packageId': 'in.anisparvez.media_server_client',
      'apkUrl': '/api/app/download?channel=developer',
      'sha256': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'fileSizeBytes': 52428800,
      'releaseNotes': '• Test update feature\n• Minor fixes',
      'mandatory': false,
      'minSupportedVersionCode': 1,
    };

    test('accepts valid manifest with strictly higher versionCode', () {
      final res = UpdateManifest.fromJson(
        validJson,
        expectedChannel: AppChannel.developer,
        installedVersionCode: 100,
      );

      expect(res.isValid, isTrue);
      expect(res.manifest, isNotNull);
      expect(res.manifest!.version, '1.1.0-dev.101');
      expect(res.manifest!.versionCode, 101);
      expect(res.manifest!.formattedFileSize, '50.0 MB');
    });

    test('rejects manifest with channel mismatch', () {
      final res = UpdateManifest.fromJson(
        validJson,
        expectedChannel: AppChannel.production,
        installedVersionCode: 100,
      );

      expect(res.isValid, isFalse);
      expect(res.errorMessage, contains('Channel mismatch'));
    });

    test('rejects manifest with package ID mismatch', () {
      final badPkg = Map<String, dynamic>.from(validJson)..['packageId'] = 'com.other.app';
      final res = UpdateManifest.fromJson(
        badPkg,
        expectedChannel: AppChannel.developer,
        installedVersionCode: 100,
      );

      expect(res.isValid, isFalse);
      expect(res.errorMessage, contains('Package ID mismatch'));
    });

    test('rejects manifest with versionCode <= installed (downgrade / equal)', () {
      // Equal version
      final equalRes = UpdateManifest.fromJson(
        validJson,
        expectedChannel: AppChannel.developer,
        installedVersionCode: 101,
      );
      expect(equalRes.isValid, isFalse);
      expect(equalRes.errorMessage, contains('not newer'));

      // Downgrade
      final downRes = UpdateManifest.fromJson(
        validJson,
        expectedChannel: AppChannel.developer,
        installedVersionCode: 105,
      );
      expect(downRes.isValid, isFalse);
      expect(downRes.errorMessage, contains('not newer'));
    });

    test('rejects manifest when device Android SDK is below minAndroidSdk', () {
      final res = UpdateManifest.fromJson(
        validJson,
        expectedChannel: AppChannel.developer,
        installedVersionCode: 100,
        currentSdk: 24, // below minSdk 26
      );

      expect(res.isValid, isFalse);
      expect(res.errorMessage, contains('lower than required minimum SDK'));
    });

    test('rejects manifest with invalid or truncated SHA-256', () {
      final badHash = Map<String, dynamic>.from(validJson)..['sha256'] = 'too_short';
      final res = UpdateManifest.fromJson(
        badHash,
        expectedChannel: AppChannel.developer,
        installedVersionCode: 100,
      );

      expect(res.isValid, isFalse);
      expect(res.errorMessage, contains('invalid SHA-256'));
    });

    test('rejects manifest with empty or invalid file size', () {
      final zeroSize = Map<String, dynamic>.from(validJson)..['fileSizeBytes'] = 0;
      final res = UpdateManifest.fromJson(
        zeroSize,
        expectedChannel: AppChannel.developer,
        installedVersionCode: 100,
      );

      expect(res.isValid, isFalse);
      expect(res.errorMessage, contains('invalid file size'));
    });
  });
}
