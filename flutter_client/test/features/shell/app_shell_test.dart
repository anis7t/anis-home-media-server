import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_server_client/app/app.dart';
import 'package:media_server_client/app/routes.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/core/storage/settings_service.dart'
    hide serverBaseUrlProvider;
import 'package:media_server_client/features/library/data/models/library_response.dart';
import 'package:media_server_client/features/library/data/models/movie_details.dart';
import 'package:media_server_client/features/library/data/models/movie_extended_details.dart';
import 'package:media_server_client/features/library/data/models/movie_item.dart';
import 'package:media_server_client/features/library/data/models/movie_specs.dart';
import 'package:media_server_client/features/library/data/repositories/library_repository.dart';
import 'package:media_server_client/features/updater/presentation/controllers/update_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../updater/update_controller_test.dart';

const String libmpvPath =
    'E:/MediaServer/flutter_client/build/windows/x64/runner/Release/libmpv-2.dll';

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

class FakeShellLibraryRepository extends LibraryRepository {
  final List<MovieItem> movies;
  final List<MovieItem> watching;

  FakeShellLibraryRepository({
    this.movies = const [],
    this.watching = const [],
  }) : super(
         ApiClient(
           baseUrl: 'http://127.0.0.1:8000',
           authInterceptor: DeviceAuthInterceptor(
             DeviceIdentityService(secureStorage: MockSecureStorage()),
           ),
         ),
       );

  @override
  Future<LibraryResponse> getMovies() async {
    return LibraryResponse(
      movies: movies,
      watching: watching,
      total: movies.length,
    );
  }

  @override
  Future<MovieDetails> getMovieDetails(String filename) async {
    final movie = movies.firstWhere(
      (m) => m.filename == filename,
      orElse: () => const MovieItem(
        filename: 'test.mp4',
        title: 'Test Movie',
        year: 2026,
      ),
    );
    return MovieDetails(
      movie: movie,
      specs: const MovieSpecs(
        resolution: '1920x1080',
        videoCodec: 'H.264',
        audioCodec: 'AAC',
        audioChannels: '2',
        container: 'mp4',
        fileSize: '1.2 GB',
      ),
      extended: const MovieExtendedDetails(
        tagline: 'Test Tagline',
        certification: 'PG-13',
      ),
      formattedRuntime: '1h 45m',
    );
  }

  @override
  Future<bool> triggerScan() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    if (File(libmpvPath).existsSync()) {
      MediaKit.ensureInitialized(libmpv: libmpvPath);
    } else {
      MediaKit.ensureInitialized();
    }
  });

  const testMovie1 = MovieItem(
    filename: 'batman.mp4',
    title: 'Batman Knightfall',
    year: 2026,
    genres: 'Action',
    rating: 8.5,
    runtime: 114,
    percent: 45.0,
    position: 3000,
    duration: 6840,
  );

  const testMovie2 = MovieItem(
    filename: 'spiderman.mkv',
    title: 'Spider-Man Brand New Day',
    year: 2025,
    genres: 'Sci-Fi',
    rating: 7.9,
    runtime: 130,
    percent: 0.0,
    position: 0,
    duration: 7800,
  );

  late SharedPreferences prefs;
  late SettingsService settingsService;
  late MockInstallerBridge mockBridge;
  late FakeUpdateRepository fakeUpdateRepo;
  late FakeShellLibraryRepository fakeLibRepo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'server_base_url': 'http://127.0.0.1:8000',
      'device_id': 'test-device-uuid-9999',
      'update_channel': 'production',
    });
    prefs = await SharedPreferences.getInstance();
    settingsService = SettingsService(prefs);
    mockBridge = MockInstallerBridge();
    fakeUpdateRepo = FakeUpdateRepository();
    fakeLibRepo = FakeShellLibraryRepository(
      movies: [testMovie1, testMovie2],
      watching: [testMovie1],
    );
  });

  Widget createSubject({String initialLocation = AppRoutes.home}) {
    return ProviderScope(
      overrides: [
        settingsServiceProvider.overrideWithValue(settingsService),
        appInstallerBridgeProvider.overrideWithValue(mockBridge),
        updateRepositoryProvider.overrideWithValue(fakeUpdateRepo),
        libraryRepositoryProvider.overrideWithValue(fakeLibRepo),
        serverBaseUrlProvider.overrideWithValue('http://127.0.0.1:8000'),
      ],
      child: MediaServerApp(
        initialRoute: initialLocation,
      ),
    );
  }

  group('Persistent Bottom Navigation Shell Tests', () {
    testWidgets('renders all 3 bottom navigation destinations on Home', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(createSubject(initialLocation: AppRoutes.home));
      await tester.pumpAndSettle();

      // Verify bottom navigation destinations
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Library'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);

      // Verify Home content is visible
      expect(find.text('Continue Watching'), findsOneWidget);
      expect(find.text('Recently Added'), findsOneWidget);
      expect(find.text('Browse Full Library'), findsOneWidget);
    });

    testWidgets('switches between Home, Library, and Settings tabs', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(createSubject(initialLocation: AppRoutes.home));
      await tester.pumpAndSettle();

      // Currently on Home
      expect(find.text('Recently Added'), findsOneWidget);

      // Switch to Library tab
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();

      // Verify Library view is displayed with search bar
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Search movies, years, genres...'), findsOneWidget);

      // Switch to Settings tab
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      // Verify Settings view is displayed with channels and update options
      expect(find.text('Settings & Updates'), findsOneWidget);
      expect(find.text('SERVER & CONNECTION'), findsOneWidget);
      expect(find.text('UPDATE CHANNEL'), findsOneWidget);
      expect(find.text('Check for Updates'), findsOneWidget);

      // Switch back to Home tab
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();

      // Home content is back
      expect(find.text('Recently Added'), findsOneWidget);
    });

    testWidgets(
      'navigates from Home to Library via Browse Full Library banner',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(createSubject(initialLocation: AppRoutes.home));
        await tester.pumpAndSettle();

        // Tap Browse Full Library banner
        await tester.tap(find.text('Browse Full Library'));
        await tester.pumpAndSettle();

        // Now on Library tab
        expect(find.text('Search movies, years, genres...'), findsOneWidget);
      },
    );

    testWidgets(
      'taps movie on Home to navigate to MovieDetailsScreen and returns to Home on pop',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(createSubject(initialLocation: AppRoutes.home));
        await tester.pumpAndSettle();

        // Tap Batman Knightfall card in Recently Added
        final cardFinder = find.text('Batman Knightfall');
        expect(cardFinder, findsWidgets);
        await tester.tap(cardFinder.first);
        await tester.pumpAndSettle();

        // MovieDetailsScreen is shown
        expect(find.text('Overview'), findsOneWidget);

        // Tap back to return to Home
        final backButton = find.byKey(const ValueKey('movie_details_back_btn'));
        expect(backButton, findsOneWidget);
        await tester.tap(backButton);
        await tester.pumpAndSettle();

        // Returned to Home in shell
        expect(find.text('Recently Added'), findsOneWidget);
        expect(find.text('Home'), findsOneWidget);
      },
    );

    testWidgets(
      'Production PlayerScreen does NOT display bottom navigation bar',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1440);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        // Direct intent route to /player
        await tester.pumpWidget(
          createSubject(initialLocation: AppRoutes.player),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Player screen is rendered
        expect(find.text('Batman Knightfall Part 1 (2026)'), findsOneWidget);

        // Bottom navigation bar is NOT rendered on player screen
        expect(find.byType(NavigationBar), findsNothing);
      },
    );

    testWidgets(
      'Settings tab provides channel selector and update checking',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(
          createSubject(initialLocation: AppRoutes.settings),
        );
        await tester.pumpAndSettle();

        expect(find.text('SERVER & CONNECTION'), findsOneWidget);
        expect(find.text('http://127.0.0.1:8000'), findsOneWidget);
        expect(find.text('UPDATE CHANNEL'), findsOneWidget);
        expect(find.textContaining('Production (Stable)'), findsOneWidget);
        expect(find.text('Developer'), findsWidgets);

        // Tap Developer channel to open switch confirmation dialog
        await tester.tap(find.text('Developer').first);
        await tester.pumpAndSettle();

        expect(find.text('Enable Developer Channel?'), findsOneWidget);
        expect(find.text('Switch to Developer'), findsOneWidget);

        // Cancel dialog
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      },
    );
  });
}
