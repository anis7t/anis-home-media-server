import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/errors/app_exception.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/features/library/data/models/library_response.dart';
import 'package:media_server_client/features/library/data/models/movie_item.dart';
import 'package:media_server_client/features/library/data/repositories/library_repository.dart';
import 'package:media_server_client/features/library/presentation/controllers/library_controller.dart';
import 'package:media_server_client/features/library/presentation/screens/library_screen.dart';

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

class FakeLibraryRepository extends LibraryRepository {
  final Future<LibraryResponse> Function()? onGetMovies;
  final Future<bool> Function()? onTriggerScan;

  FakeLibraryRepository({this.onGetMovies, this.onTriggerScan})
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
    genres: 'Action, Mystery',
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
    genres: 'Action, Sci-Fi',
    rating: 7.9,
    runtime: 130,
    percent: 0.0,
    position: 0,
    duration: 7800,
  );

  Widget createSubject(
    FakeLibraryRepository repo, {
    ProviderContainer? container,
  }) {
    if (container != null) {
      return UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LibraryScreen()),
      );
    }
    return ProviderScope(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repo),
        serverBaseUrlProvider.overrideWithValue('http://127.0.0.1:8000'),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    );
  }

  group('LibraryScreen Widget Tests', () {
    testWidgets('renders populated library with movies and continue watching', (
      tester,
    ) async {
      final fakeRepo = FakeLibraryRepository(
        onGetMovies: () async => const LibraryResponse(
          movies: [movieA, movieB],
          watching: [movieA],
          total: 2,
        ),
      );

      await tester.pumpWidget(createSubject(fakeRepo));
      await tester.pumpAndSettle();

      // Brand Header
      expect(find.text("Anis' "), findsOneWidget);
      expect(find.text('Home Media Server'), findsOneWidget);

      // Continue watching rail present
      expect(find.text('Continue Watching'), findsOneWidget);

      // All Movies section title
      expect(find.text('All Movies'), findsOneWidget);
      expect(find.text('(2)'), findsOneWidget);

      // Movie titles present
      expect(find.text('Batman Knightfall'), findsWidgets);
      expect(find.text('Spider-Man Brand New Day'), findsOneWidget);
    });

    testWidgets(
      'filters movie grid on debounced search query and hides continue watching',
      (tester) async {
        final fakeRepo = FakeLibraryRepository(
          onGetMovies: () async => const LibraryResponse(
            movies: [movieA, movieB],
            watching: [movieA],
            total: 2,
          ),
        );

        await tester.pumpWidget(createSubject(fakeRepo));
        await tester.pumpAndSettle();

        // Type "Spider" in the search input
        await tester.enterText(find.byType(TextField), 'Spider');
        // Advance timer for 150ms debounce
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();

        // Continue watching is hidden during active search
        expect(find.text('Continue Watching'), findsNothing);

        // Results header
        expect(find.text('Results for "Spider"'), findsOneWidget);
        expect(find.text('(1)'), findsOneWidget);
        expect(find.text('Spider-Man Brand New Day'), findsOneWidget);
      },
    );

    testWidgets(
      'renders sort and filter trigger button and opens SortFilterSheet on tap',
      (tester) async {
        final fakeRepo = FakeLibraryRepository(
          onGetMovies: () async => const LibraryResponse(
            movies: [movieA, movieB],
            watching: [movieA],
            total: 2,
          ),
        );

        await tester.pumpWidget(createSubject(fakeRepo));
        await tester.pumpAndSettle();

        // Find the filter icon button for sort & filter and settings icon in header
        final filterBtn = find.byIcon(Icons.filter_list_rounded);
        expect(filterBtn, findsOneWidget);
        expect(find.byIcon(Icons.settings_rounded), findsOneWidget);

        // Tap the sort & filter button (the one inside the search row)
        await tester.tap(filterBtn);
        await tester.pumpAndSettle();

        // Bottom sheet should be visible
        expect(find.text('Sort & Filter'), findsOneWidget);
        expect(find.text('WATCH STATUS'), findsOneWidget);
        expect(find.text('SORT BY'), findsOneWidget);
      },
    );

    testWidgets(
      'displays active filter chips rail and allows clearing individual filters',
      (tester) async {
        final fakeRepo = FakeLibraryRepository(
          onGetMovies: () async => const LibraryResponse(
            movies: [movieA, movieB],
            watching: [movieA],
            total: 2,
          ),
        );

        final container = ProviderContainer(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(fakeRepo),
            serverBaseUrlProvider.overrideWithValue('http://127.0.0.1:8000'),
          ],
        );
        addTearDown(container.dispose);

        await container.read(libraryControllerProvider.notifier).loadLibrary();

        await tester.pumpWidget(createSubject(fakeRepo, container: container));
        await tester.pumpAndSettle();

        // Initially no active filter chips
        expect(find.text('Reset All'), findsNothing);

        // Set a genre filter and sort order programmatically via notifier
        container
            .read(libraryControllerProvider.notifier)
            .setSelectedGenre('Mystery');
        container
            .read(libraryControllerProvider.notifier)
            .setSortOption(SortOption.titleDesc);
        await tester.pumpAndSettle();

        // Active chips rail should now display
        expect(find.text('Mystery'), findsOneWidget);
        expect(find.text('Z → A'), findsOneWidget);
        expect(find.text('Reset All'), findsOneWidget);
        expect(find.text('Filtered Movies'), findsOneWidget);

        // Remove the genre chip via its dedicated key
        final mysteryRemoveBtn = find.byKey(
          const ValueKey('remove_chip_Mystery'),
        );
        expect(mysteryRemoveBtn, findsOneWidget);
        await tester.tap(mysteryRemoveBtn);
        await tester.pumpAndSettle();

        // Genre should be removed
        expect(container.read(libraryControllerProvider).selectedGenre, isNull);

        // Tap Reset All to clear remaining sort filter
        await tester.tap(find.text('Reset All'));
        await tester.pumpAndSettle();

        expect(
          container.read(libraryControllerProvider).hasActiveFilters,
          isFalse,
        );
        expect(find.text('Reset All'), findsNothing);
        expect(find.text('All Movies'), findsOneWidget);
      },
    );

    testWidgets('renders empty state when library has 0 movies', (
      tester,
    ) async {
      final fakeRepo = FakeLibraryRepository(
        onGetMovies: () async =>
            const LibraryResponse(movies: [], watching: [], total: 0),
      );

      await tester.pumpWidget(createSubject(fakeRepo));
      await tester.pumpAndSettle();

      expect(find.text('No movies in library'), findsOneWidget);
      expect(find.text('Scan Media Directory'), findsOneWidget);
    });

    testWidgets('renders error state with retry button when repository fails', (
      tester,
    ) async {
      final fakeRepo = FakeLibraryRepository(
        onGetMovies: () async =>
            throw NetworkException('Media server unreachable'),
      );

      await tester.pumpWidget(createSubject(fakeRepo));
      await tester.pumpAndSettle();

      expect(find.text('Unable to reach media server'), findsOneWidget);
      expect(find.text('Try Again'), findsOneWidget);
    });
  });
}
