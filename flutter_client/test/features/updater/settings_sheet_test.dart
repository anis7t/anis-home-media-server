import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/models/app_channel.dart';
import 'package:media_server_client/core/storage/settings_service.dart';
import 'package:media_server_client/features/updater/data/models/update_manifest.dart';
import 'package:media_server_client/features/updater/infrastructure/app_installer_bridge.dart';
import 'package:media_server_client/features/updater/presentation/controllers/update_controller.dart';
import 'package:media_server_client/features/updater/presentation/widgets/settings_sheet.dart';
import 'package:media_server_client/features/updater/presentation/widgets/update_prompt_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'update_controller_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late SettingsService settingsService;
  late MockInstallerBridge mockBridge;
  late FakeUpdateRepository fakeRepo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'server_base_url': 'http://127.0.0.1:8000',
      'device_id': 'test-device-uuid-1234',
      'update_channel': 'production',
    });
    prefs = await SharedPreferences.getInstance();
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

  Widget buildTestableWidget(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: SettingsSheet(),
        ),
      ),
    );
  }

  testWidgets('SettingsSheet displays server, device ID, channel, and version info', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final container = createContainer();
    addTearDown(container.dispose);
    final controller = container.read(updateControllerProvider.notifier);
    await controller.init();

    await tester.pumpWidget(buildTestableWidget(container));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('SERVER & CONNECTION'), findsOneWidget);
    expect(find.text('http://127.0.0.1:8000'), findsOneWidget);
    expect(find.text('APPLICATION VERSION'), findsOneWidget);
    expect(find.text('Version 1.0.0'), findsOneWidget);
    expect(find.text('Build 100'), findsOneWidget);
    expect(find.text('UPDATE CHANNEL'), findsOneWidget);
    expect(find.textContaining('Production'), findsWidgets);
    expect(find.text('Developer'), findsWidgets);
    expect(find.text('Check for Updates'), findsOneWidget);
  });

  testWidgets('Selecting Developer channel displays confirmation dialog', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final container = createContainer();
    addTearDown(container.dispose);
    final controller = container.read(updateControllerProvider.notifier);
    await controller.init();

    await tester.pumpWidget(buildTestableWidget(container));
    await tester.pumpAndSettle();

    // Tap Developer channel option
    await tester.tap(find.text('Developer').first);
    await tester.pumpAndSettle();

    // Confirmation dialog should be displayed
    expect(find.text('Enable Developer Channel?'), findsOneWidget);
    expect(find.text('Switch to Developer'), findsOneWidget);

    // Confirm switch
    await tester.tap(find.text('Switch to Developer'));
    await tester.pumpAndSettle();

    expect(await settingsService.getUpdateChannel(), AppChannel.developer);
  });

  testWidgets('Switching from Developer to Production displays downgrade warning dialog', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await settingsService.setUpdateChannel(AppChannel.developer);
    mockBridge.currentInfo = const AppPlatformInfo(
      packageName: 'in.anisparvez.media_server_client',
      versionName: '1.0.2',
      versionCode: 102,
    );

    final container = createContainer();
    addTearDown(container.dispose);
    final controller = container.read(updateControllerProvider.notifier);
    await controller.init();

    await tester.pumpWidget(buildTestableWidget(container));
    await tester.pumpAndSettle();

    // Tap Production channel option
    await tester.tap(find.textContaining('Production (Stable)'));
    await tester.pumpAndSettle();

    expect(find.text('Switch to Production Channel?'), findsOneWidget);
    expect(find.textContaining('You are returning to the stable release channel'), findsOneWidget);
    expect(find.text('Switch to Production'), findsOneWidget);

    // Confirm switch
    await tester.tap(find.text('Switch to Production'));
    await tester.pumpAndSettle();

    expect(await settingsService.getUpdateChannel(), AppChannel.production);
  });

  testWidgets('UpdatePromptDialog renders update details and handles user actions', (tester) async {
    const manifest = UpdateManifest(
      channel: AppChannel.developer,
      version: '1.0.1',
      versionCode: 101,
      releaseDate: '2026-09-26T00:00:00Z',
      minAndroidSdk: 26,
      targetAndroidSdk: 35,
      packageId: 'in.anisparvez.media_server_client',
      apkUrl: '/api/app/download?channel=developer',
      sha256: 'deadbeef1234567890abcdefdeadbeef1234567890abcdefdeadbeef12345678',
      fileSizeBytes: 15728640,
      releaseNotes: 'Fixed subtitle sync\nAdded dual GPU acceleration',
      mandatory: false,
    );
    await settingsService.setUpdateChannel(AppChannel.developer);
    fakeRepo.manifestToReturn = const ManifestValidationResult.valid(manifest);

    final container = createContainer();
    addTearDown(container.dispose);

    final controller = container.read(updateControllerProvider.notifier);
    await controller.init();
    await controller.checkForUpdates(isManual: true);

    expect(container.read(updateControllerProvider).status, UpdateStatus.updateAvailable);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: UpdatePromptDialog(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Update Available:'), findsOneWidget);
    expect(find.text('DEVELOPER'), findsOneWidget);
    expect(find.textContaining('Build 101'), findsOneWidget);
    expect(find.textContaining('Fixed subtitle sync'), findsOneWidget);
    expect(find.text('Update Now'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
  });
}
