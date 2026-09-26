import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/models/app_channel.dart';
import 'package:media_server_client/core/storage/settings_service.dart';
import 'package:media_server_client/features/updater/data/models/update_manifest.dart';
import 'package:media_server_client/features/updater/data/repositories/update_repository.dart';
import 'package:media_server_client/features/updater/infrastructure/app_installer_bridge.dart';
import 'package:media_server_client/features/updater/presentation/controllers/update_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockInstallerBridge implements AppInstallerBridge {
  AppPlatformInfo currentInfo;
  bool canInstall = true;
  String? lastInstalledPath;

  MockInstallerBridge({this.currentInfo = const AppPlatformInfo(
    packageName: 'in.anisparvez.media_server_client',
    versionName: '1.0.0',
    versionCode: 100,
  )});

  @override
  Future<AppPlatformInfo> getAppInfo() async => currentInfo;

  @override
  Future<bool> canInstallUnknownPackages() async => canInstall;

  @override
  Future<void> openInstallPermissionSettings() async {}

  @override
  Future<bool> installApk(String filePath) async {
    lastInstalledPath = filePath;
    return true;
  }
}

class FakeUpdateRepository extends UpdateRepository {
  ManifestValidationResult? manifestToReturn;
  bool downloadSuccess = true;
  bool checksumSuccess = true;

  FakeUpdateRepository() : super(Dio());

  @override
  Future<ManifestValidationResult> fetchAndValidateManifest({
    required AppChannel channel,
    required int installedVersionCode,
    String expectedPackageId = 'in.anisparvez.media_server_client',
    int currentSdk = 36,
  }) async {
    if (manifestToReturn != null) return manifestToReturn!;
    return const ManifestValidationResult.invalid('No update manifest configured');
  }

  @override
  Future<bool> downloadApk({
    required String downloadUrl,
    required String destinationPath,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (!downloadSuccess) throw Exception('Download failed');
    onProgress?.call(1000, 1000);
    return true;
  }

  @override
  Future<bool> verifyChecksum(String filePath, String expectedSha256) async {
    return checksumSuccess;
  }
}

void main() {
  group('UpdateController & Release Lifecycle Tests', () {
    late SettingsService settingsService;
    late MockInstallerBridge mockBridge;
    late FakeUpdateRepository fakeRepo;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      settingsService = SettingsService(prefs);
      mockBridge = MockInstallerBridge();
      fakeRepo = FakeUpdateRepository();
    });

    ProviderContainer createContainer() {
      return ProviderContainer(
        overrides: [
          settingsServiceProvider.overrideWithValue(settingsService),
          appInstallerBridgeProvider.overrideWithValue(mockBridge),
          updateRepositoryProvider.overrideWithValue(fakeRepo),
        ],
      );
    }

    test('initializes with app info and persisted channel', () async {
      final container = createContainer();
      final controller = container.read(updateControllerProvider.notifier);
      await controller.init();

      final state = container.read(updateControllerProvider);
      expect(state.installedVersionCode, 100);
      expect(state.installedVersionName, '1.0.0');
      expect(state.activeChannel, AppChannel.production);
    });

    test('channel switching persists across restarts and triggers check', () async {
      final container = createContainer();
      final controller = container.read(updateControllerProvider.notifier);
      await controller.init();

      // Switch to Developer
      await controller.switchChannel(AppChannel.developer);
      expect(container.read(updateControllerProvider).activeChannel, AppChannel.developer);

      // Verify persisted value in SettingsService
      final persisted = await settingsService.getUpdateChannel();
      expect(persisted, AppChannel.developer);

      // Re-create container simulating app restart
      final restartedContainer = createContainer();
      final restartedController = restartedContainer.read(updateControllerProvider.notifier);
      await restartedController.init();
      expect(restartedContainer.read(updateControllerProvider).activeChannel, AppChannel.developer);
    });

    test('detects available update and updates status', () async {
      const manifest = UpdateManifest(
        channel: AppChannel.developer,
        version: '1.1.0-dev.101',
        versionCode: 101,
        releaseDate: '2026-09-26T04:00:00Z',
        minAndroidSdk: 26,
        targetAndroidSdk: 36,
        packageId: 'in.anisparvez.media_server_client',
        apkUrl: '/api/app/download?channel=developer',
        sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        fileSizeBytes: 52428800,
        releaseNotes: '• New feature',
      );
      fakeRepo.manifestToReturn = const ManifestValidationResult.valid(manifest);

      final container = createContainer();
      final controller = container.read(updateControllerProvider.notifier);
      await controller.init();

      await controller.checkForUpdates(isManual: true);

      final state = container.read(updateControllerProvider);
      expect(state.status, UpdateStatus.updateAvailable);
      expect(state.availableManifest?.versionCode, 101);
    });

    test('verifies Production 100 -> Dev 101 -> Dev 102 -> Dev 103 -> Prod 104 lifecycle', () async {
      // Sequence requirement from user prompt:
      // Production 100 -> Dev 101 -> Dev 102 -> Dev 103 -> Prod 104
      // Rule: Production 100 cannot replace Dev 103
      // Rule: Production 104 CAN replace Dev 103

      // Current installation: Developer 103
      mockBridge.currentInfo = const AppPlatformInfo(
        packageName: 'in.anisparvez.media_server_client',
        versionName: '1.1.0-dev.103',
        versionCode: 103,
      );

      final container = createContainer();
      final controller = container.read(updateControllerProvider.notifier);
      await controller.init();
      expect(container.read(updateControllerProvider).installedVersionCode, 103);

      // User switches to Production channel
      await controller.switchChannel(AppChannel.production);
      expect(container.read(updateControllerProvider).activeChannel, AppChannel.production);

      // Case 1: Server offers older Production 100
      // Manifest validation must reject this (versionCode 100 <= 103)
      const oldProdManifestJson = {
        'channel': 'production',
        'version': '1.0.0',
        'versionCode': 100,
        'releaseDate': '2026-09-25T00:00:00Z',
        'minAndroidSdk': 26,
        'targetAndroidSdk': 36,
        'packageId': 'in.anisparvez.media_server_client',
        'apkUrl': '/api/app/download?channel=production',
        'sha256': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        'fileSizeBytes': 50000000,
        'releaseNotes': 'Old release',
      };
      final rejection = UpdateManifest.fromJson(
        oldProdManifestJson,
        expectedChannel: AppChannel.production,
        installedVersionCode: 103,
      );
      expect(rejection.isValid, isFalse);
      expect(rejection.errorMessage, contains('not newer than installed code 103'));

      // Case 2: Server publishes new Production 104
      // Manifest validation MUST accept this (versionCode 104 > 103)
      const newProdManifestJson = {
        'channel': 'production',
        'version': '1.1.0',
        'versionCode': 104,
        'releaseDate': '2026-09-26T06:00:00Z',
        'minAndroidSdk': 26,
        'targetAndroidSdk': 36,
        'packageId': 'in.anisparvez.media_server_client',
        'apkUrl': '/api/app/download?channel=production',
        'sha256': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        'fileSizeBytes': 52000000,
        'releaseNotes': 'New Production 104 release',
      };
      final acceptance = UpdateManifest.fromJson(
        newProdManifestJson,
        expectedChannel: AppChannel.production,
        installedVersionCode: 103,
      );
      expect(acceptance.isValid, isTrue);
      expect(acceptance.manifest?.versionCode, 104);
      expect(acceptance.manifest?.version, '1.1.0');

      // Execute update check with acceptance manifest
      fakeRepo.manifestToReturn = acceptance;
      await controller.checkForUpdates(isManual: true);
      expect(container.read(updateControllerProvider).status, UpdateStatus.updateAvailable);
      expect(container.read(updateControllerProvider).availableManifest?.versionCode, 104);
    });
  });
}
