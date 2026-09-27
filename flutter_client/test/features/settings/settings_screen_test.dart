import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:media_server_client/app/routes.dart';
import 'package:media_server_client/core/storage/settings_service.dart';
import 'package:media_server_client/features/settings/presentation/screens/settings_screen.dart';
import 'package:media_server_client/features/updater/presentation/controllers/update_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../updater/update_controller_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late SettingsService settingsService;
  late MockInstallerBridge mockBridge;
  late FakeUpdateRepository fakeRepo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'server_base_url': 'http://127.0.0.1:8000',
      'device_id': 'test-device-uuid-5555',
      'update_channel': 'production',
    });
    prefs = await SharedPreferences.getInstance();
    settingsService = SettingsService(prefs);
    mockBridge = MockInstallerBridge();
    fakeRepo = FakeUpdateRepository();
  });

  Widget buildSubject({
    required ProviderContainer container,
    void Function()? onNavigatedToConnection,
  }) {
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsScreen(),
        ),
        GoRoute(
          path: AppRoutes.connection,
          builder: (context, state) {
            onNavigatedToConnection?.call();
            return const Scaffold(body: Text('Connection Screen'));
          },
        ),
      ],
    );

    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
      ),
    );
  }

  testWidgets(
    'SettingsScreen displays server, version, channel and update controls',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final container = ProviderContainer(
        overrides: [
          settingsServiceProvider.overrideWithValue(settingsService),
          appInstallerBridgeProvider.overrideWithValue(mockBridge),
          updateRepositoryProvider.overrideWithValue(fakeRepo),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(updateControllerProvider.notifier);
      await controller.init();

      await tester.pumpWidget(buildSubject(container: container));
      await tester.pumpAndSettle();

      expect(find.text('Settings & Updates'), findsOneWidget);
      expect(find.text('SERVER & CONNECTION'), findsOneWidget);
      expect(find.text('http://127.0.0.1:8000'), findsOneWidget);
      expect(find.text('APPLICATION VERSION'), findsOneWidget);
      expect(find.text('Version 1.0.0'), findsOneWidget);
      expect(find.text('UPDATE CHANNEL'), findsOneWidget);
      expect(find.textContaining('Production (Stable)'), findsOneWidget);
      expect(find.text('Developer'), findsWidgets);
      expect(find.text('Check for Updates'), findsOneWidget);
    },
  );

  testWidgets('Change server button navigates to ConnectionScreen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    var navigated = false;
    final container = ProviderContainer(
      overrides: [
        settingsServiceProvider.overrideWithValue(settingsService),
        appInstallerBridgeProvider.overrideWithValue(mockBridge),
        updateRepositoryProvider.overrideWithValue(fakeRepo),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(updateControllerProvider.notifier);
    await controller.init();

    await tester.pumpWidget(
      buildSubject(
        container: container,
        onNavigatedToConnection: () => navigated = true,
      ),
    );
    await tester.pumpAndSettle();

    final changeBtn = find.text('Change');
    expect(changeBtn, findsOneWidget);
    await tester.tap(changeBtn);
    await tester.pumpAndSettle();

    expect(navigated, isTrue);
    expect(find.text('Connection Screen'), findsOneWidget);
  });
}
