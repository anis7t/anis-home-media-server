import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/app/app.dart';
import 'package:media_server_client/app/routes.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/core/storage/settings_service.dart'
    hide serverBaseUrlProvider;
// Same library, second view: the async (FutureProvider) origin that
// settings_content.dart watches, which otherwise shows the production default until it
// resolves and makes the displayed origin depend on microtask timing.
import 'package:media_server_client/core/storage/settings_service.dart'
    as settings show serverBaseUrlProvider;
import 'package:media_server_client/features/library/data/models/library_response.dart';
import 'package:media_server_client/features/library/data/repositories/library_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_network_guard.dart';

class MockSecureStorage extends FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
  }) async => data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
  }) async {
    if (value != null) data[key] = value;
  }
}

/// Stands in for the real library repository. Without it the Home screen watched the
/// live one and issued `GET /api/movies` against https://media.anisparvez.in.
class FakeLibraryRepository extends LibraryRepository {
  FakeLibraryRepository()
      : super(
          ApiClient(
            baseUrl: testOrigin,
            authInterceptor: DeviceAuthInterceptor(
              DeviceIdentityService(secureStorage: MockSecureStorage()),
            ),
          ),
        );

  @override
  Future<LibraryResponse> getMovies() async {
    return const LibraryResponse(movies: [], watching: [], total: 0);
  }

  @override
  Future<bool> triggerScan() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // NOTE: media_kit is deliberately NOT initialised here. Nothing this file renders
    // (ConnectionScreen, HomeScreen, AppShell) constructs a PlayerScreen or any
    // PlayerController, so no native libmpv player is ever created. Calling
    // MediaKit.ensureInitialized() anyway made this file a participant in media_kit's
    // NativeReferenceHolder race - a process-wide file keyed on $pid that is written
    // non-atomically, which intermittently threw FormatException and left
    // _completer uncompleted (hanging add()/remove()). Removing an unnecessary
    // participant is the cheapest mitigation; `flutter test --concurrency=1` is the
    // reliable full-suite command. See AGENTS.md for the media_kit init invariant.
    //
    // Installed after the binding so a stray request fails loudly instead of being
    // swallowed by the binding's 400-returning HTTP mock.
    installTestNetworkGuard();
  });

  late SettingsService settingsService;

  setUp(() async {
    resetBlockedRequests();
    // Proof that no test in this file even attempts non-sentinel traffic.
    addTearDown(() {
      expect(
        blockedRequests,
        isEmpty,
        reason: 'ordinary tests must not attempt traffic outside $testOrigin',
      );
    });
    SharedPreferences.setMockInitialValues({'server_base_url': testOrigin});
    settingsService = SettingsService(await SharedPreferences.getInstance());
  });

  /// Every screen in the router chain needs an origin and a library source, otherwise
  /// both fall through to production defaults.
  Widget subject(String initialRoute) {
    return ProviderScope(
      overrides: [
        settingsServiceProvider.overrideWithValue(settingsService),
        serverBaseUrlProvider.overrideWithValue(testOrigin),
        settings.serverBaseUrlProvider.overrideWith((ref) => testOrigin),
        libraryRepositoryProvider.overrideWithValue(FakeLibraryRepository()),
      ],
      child: MediaServerApp(initialRoute: initialRoute),
    );
  }

  testWidgets('Default app launch route is AppRoutes.home', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1440);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(subject(AppRoutes.home));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify Home tab destination in bottom navigation bar is rendered
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('ConnectionScreen renders branding, server input, and device identity without dev options', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1440);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(subject(AppRoutes.connection));

    // Let any initial microtasks and provider initialization settle
    await tester.pumpAndSettle();

    // Verify brand headers (using findRichText: true for RichText spans)
    expect(find.textContaining("Anis'", findRichText: true), findsWidgets);
    expect(find.textContaining("Home Media Server", findRichText: true), findsWidgets);
    expect(find.text('PLAY • ORGANIZE • ENJOY'), findsOneWidget);

    // Verify Server Origin card
    expect(find.text('Server Origin'), findsOneWidget);
    expect(find.text('Test Connection'), findsOneWidget);

    // Verify WAN preset chip is available
    expect(find.text('WAN (Cloudflare)'), findsOneWidget);

    // Verify Client Device Identity card
    expect(find.text('Client Device Identity'), findsOneWidget);
    expect(find.text('CSPRNG Verified'), findsOneWidget);

    // Verify Save & Set Active Server and Enter Media Server buttons
    expect(find.text('Save & Set Active Server'), findsOneWidget);
    expect(find.text('Enter Media Server (Home)'), findsOneWidget);

    // Verify dev options are completely absent
    expect(find.text('Launch Production Video Player (Phase 3A)'), findsNothing);
    expect(find.text('Launch Player POC Test Harness (Phase 2)'), findsNothing);
    expect(find.text('Browse Movie Library (Phase 4)'), findsNothing);
  });

  testWidgets('Enter Media Server navigates to HomeScreen in AppShell', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1440);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(subject(AppRoutes.connection));
    await tester.pumpAndSettle();

    final btn = find.text('Enter Media Server (Home)');
    expect(btn, findsOneWidget);
    await tester.tap(btn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify navigation into Home tab in shell
    expect(find.text('Home'), findsOneWidget);
  });
}