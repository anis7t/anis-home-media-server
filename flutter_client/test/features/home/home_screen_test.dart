import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:media_server_client/app/routes.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/errors/app_exception.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/features/home/presentation/screens/home_screen.dart';
import 'package:media_server_client/features/library/data/models/library_response.dart';
import 'package:media_server_client/features/library/data/models/movie_item.dart';
import 'package:media_server_client/features/library/data/repositories/library_repository.dart';

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

class FakeHomeLibraryRepository extends LibraryRepository {
  final Future<LibraryResponse> Function()? onGetMovies;
  final Future<bool> Function()? onTriggerScan;

  FakeHomeLibraryRepository({this.onGetMovies, this.onTriggerScan})
    : super(
        ApiClient(
          baseUrl: 'http://127.0.0.1:8000',
          authInterceptor: DeviceAuthInterceptor(
            DeviceIdentityService(secureStorage: MockSecureStorage()),
          ),
        ),
      );

  @override
  Future<LibraryResponse> getMovies() async {
    if (onGetMovies != null) return onGetMovies!();
    return const LibraryResponse(movies: [], watching: [], total: 0);
  }

  @override
  Future<bool> triggerScan() async {
    if (onTriggerScan != null) return onTriggerScan!();
    return true;
  }
}

void main() {
  const movieA = MovieItem(
    filename: 'batman.mp4',
    title: 'Batman Knightfall',
    year: 2026,
    genres: 'Action',
    rating: 8.5,
    runtime: 114,
    percent: 50.0,
    position: 3420,
    duration: 6840,
  );

  const movieB = MovieItem(
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

  Widget createSubject(
    FakeHomeLibraryRepository repo, {
    void Function(MovieItem movie)? onMovieSelected,
  }) {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (context, state) => const HomeScreen(),
        ),
        GoRoute(
          path: AppRoutes.movieDetails,
          builder: (context, state) {
            onMovieSelected?.call(state.extra as MovieItem);
            return const Scaffold(body: Text('Details Screen'));
          },
        ),
      ],
    );

    return ProviderScope(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repo),
        serverBaseUrlProvider.overrideWithValue('http://127.0.0.1:8000'),
      ],
      child: MaterialApp.router(
        routerConfig: router,
      ),
    );
  }

  group('HomeScreen Widget Tests', () {
    testWidgets('renders Continue Watching rail and Recently Added section', (
      tester,
    ) async {
      final fakeRepo = FakeHomeLibraryRepository(
        onGetMovies: () async => const LibraryResponse(
          movies: [movieA, movieB],
          watching: [movieA],
          total: 2,
        ),
      );

      await tester.pumpWidget(createSubject(fakeRepo));
      await tester.pumpAndSettle();

      // Brand Header
      expect(find.textContaining("Anis'", findRichText: true), findsOneWidget);
      expect(
        find.textContaining('Home Media Server', findRichText: true),
        findsOneWidget,
      );

      // Continue Watching
      expect(find.text('Continue Watching'), findsOneWidget);

      // Browse Full Library banner
      expect(find.text('Browse Full Library'), findsOneWidget);

      // Recently Added
      expect(find.text('Recently Added'), findsOneWidget);
      expect(find.text('Batman Knightfall'), findsWidgets);
      expect(find.text('Spider-Man Brand New Day'), findsOneWidget);
    });

    testWidgets('taps movie card to navigate to MovieDetailsScreen', (
      tester,
    ) async {
      MovieItem? tappedMovie;
      final fakeRepo = FakeHomeLibraryRepository(
        onGetMovies: () async => const LibraryResponse(
          movies: [movieA],
          watching: [],
          total: 1,
        ),
      );

      await tester.pumpWidget(
        createSubject(
          fakeRepo,
          onMovieSelected: (m) => tappedMovie = m,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Batman Knightfall').first);
      await tester.pumpAndSettle();

      expect(tappedMovie?.title, 'Batman Knightfall');
      expect(find.text('Details Screen'), findsOneWidget);
    });

    testWidgets('renders empty state when library has no media files', (
      tester,
    ) async {
      final fakeRepo = FakeHomeLibraryRepository(
        onGetMovies: () async => const LibraryResponse(
          movies: [],
          watching: [],
          total: 0,
        ),
      );

      await tester.pumpWidget(createSubject(fakeRepo));
      await tester.pumpAndSettle();

      expect(find.text('Your Media Library is Empty'), findsOneWidget);
      expect(find.text('Scan Library Files'), findsOneWidget);
      expect(find.text('Configure Server Origin'), findsOneWidget);
    });

    testWidgets('renders error card with retry button on network error', (
      tester,
    ) async {
      var callCount = 0;
      final fakeRepo = FakeHomeLibraryRepository(
        onGetMovies: () async {
          callCount++;
          if (callCount == 1) {
            throw const NetworkException('Connection timed out');
          }
          return const LibraryResponse(
            movies: [movieA],
            watching: [],
            total: 1,
          );
        },
      );

      await tester.pumpWidget(createSubject(fakeRepo));
      await tester.pumpAndSettle();

      // Error shown
      expect(find.text('Failed to Connect to Server'), findsOneWidget);
      expect(find.text('Connection timed out'), findsOneWidget);

      // Tap Retry
      await tester.tap(find.text('Retry Connection'));
      await tester.pumpAndSettle();

      // Recovered
      expect(find.text('Batman Knightfall'), findsOneWidget);
    });

    testWidgets('triggers library scan from header button', (tester) async {
      var scanTriggered = false;
      final fakeRepo = FakeHomeLibraryRepository(
        onGetMovies: () async => const LibraryResponse(
          movies: [movieA],
          watching: [],
          total: 1,
        ),
        onTriggerScan: () async {
          scanTriggered = true;
          return true;
        },
      );

      await tester.pumpWidget(createSubject(fakeRepo));
      await tester.pumpAndSettle();

      final scanBtn = find.byTooltip('Scan Library Files');
      expect(scanBtn, findsOneWidget);
      await tester.tap(scanBtn);
      await tester.pumpAndSettle();

      expect(scanTriggered, isTrue);
      expect(
        find.text('Library scan completed successfully'),
        findsOneWidget,
      );
    });
  });
}
