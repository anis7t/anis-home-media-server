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
    overview: 'Gotham faces Knightfall',
    rating: 8.4,
    runtime: 114,
    position: 3420.0,
    duration: 6840.0,
    percent: 50.0,
    updatedAt: '2026-09-25 10:00:00',
  );

  const movieB = MovieItem(
    filename: 'spiderman.mkv',
    title: 'Spider-Man Brand New Day',
    year: 2025,
    genres: 'Action, Sci-Fi',
    overview: 'Peter Parker returns',
    rating: 7.9,
    runtime: 130,
    position: 0.0,
    duration: 7800.0,
    percent: 0.0,
    updatedAt: '2026-09-24 10:00:00',
  );

  const movieC = MovieItem(
    filename: 'odyssey.mkv',
    title: 'The Odyssey',
    year: 2024,
    genres: 'Adventure, Drama',
    overview: 'Epic journey home',
    rating: 9.1,
    runtime: 160,
    position: 5880.0,
    duration: 6000.0,
    percent: 98.0,
    updatedAt: '2026-09-26 01:00:00',
  );

  const movieD = MovieItem(
    filename: 'coyote.mkv',
    title: 'Coyote vs Acme',
    year: null,
    genres: 'Animation, Comedy',
    overview: 'Wile E. sues Acme Corporation',
    rating: null,
    runtime: 90,
    position: 0.0,
    duration: 5400.0,
    percent: 0.0,
    updatedAt: null,
  );

  group('LibraryController', () {
    test('loads library movies and continue watching on build', () async {
      final fakeRepo = FakeLibraryRepository(
        onGetMovies: () async => const LibraryResponse(
          movies: [movieA, movieB],
          watching: [movieA],
          total: 2,
        ),
      );

      final container = ProviderContainer(
        overrides: [libraryRepositoryProvider.overrideWithValue(fakeRepo)],
      );
      addTearDown(container.dispose);

      expect(
        container.read(libraryControllerProvider).status,
        LibraryStatus.loading,
      );

      await container.read(libraryControllerProvider.notifier).loadLibrary();

      final state = container.read(libraryControllerProvider);
      expect(state.status, LibraryStatus.loaded);
      expect(state.movies.length, 2);
      expect(state.continueWatching.length, 1);
      expect(state.total, 2);
      expect(state.errorMessage, isNull);
    });

    test('handles error gracefully when repository fails', () async {
      final fakeRepo = FakeLibraryRepository(
        onGetMovies: () async => throw NetworkException('Connection timed out'),
      );

      final container = ProviderContainer(
        overrides: [libraryRepositoryProvider.overrideWithValue(fakeRepo)],
      );
      addTearDown(container.dispose);

      await container.read(libraryControllerProvider.notifier).loadLibrary();

      final state = container.read(libraryControllerProvider);
      expect(state.status, LibraryStatus.error);
      expect(state.movies, isEmpty);
      expect(state.errorMessage, contains('Connection timed out'));
    });

    test('pull-to-refresh preserves existing movies during fetch', () async {
      var callCount = 0;
      final fakeRepo = FakeLibraryRepository(
        onGetMovies: () async {
          callCount++;
          return const LibraryResponse(
            movies: [movieA],
            watching: [],
            total: 1,
          );
        },
      );

      final container = ProviderContainer(
        overrides: [libraryRepositoryProvider.overrideWithValue(fakeRepo)],
      );
      addTearDown(container.dispose);

      await container.read(libraryControllerProvider.notifier).loadLibrary();
      expect(container.read(libraryControllerProvider).movies.length, 1);
      callCount = 0;

      final refreshFuture = container
          .read(libraryControllerProvider.notifier)
          .loadLibrary(isRefresh: true);

      expect(container.read(libraryControllerProvider).movies.length, 1);
      await refreshFuture;

      expect(container.read(libraryControllerProvider).isRefreshing, false);
      expect(callCount, 1);
    });

    test('filters movies by title, year, overview, and genre', () async {
      final fakeRepo = FakeLibraryRepository(
        onGetMovies: () async => const LibraryResponse(
          movies: [movieA, movieB],
          watching: [],
          total: 2,
        ),
      );

      final container = ProviderContainer(
        overrides: [libraryRepositoryProvider.overrideWithValue(fakeRepo)],
      );
      addTearDown(container.dispose);

      await container.read(libraryControllerProvider.notifier).loadLibrary();
      final notifier = container.read(libraryControllerProvider.notifier);

      // Filter by title
      notifier.setSearchQuery('Spider');
      expect(
        container.read(libraryControllerProvider).filteredMovies.length,
        1,
      );
      expect(
        container.read(libraryControllerProvider).filteredMovies.first.title,
        'Spider-Man Brand New Day',
      );

      // Filter by year
      notifier.setSearchQuery('2026');
      expect(
        container.read(libraryControllerProvider).filteredMovies.length,
        1,
      );
      expect(
        container.read(libraryControllerProvider).filteredMovies.first.title,
        'Batman Knightfall',
      );

      // Filter by genre
      notifier.setSearchQuery('Mystery');
      expect(
        container.read(libraryControllerProvider).filteredMovies.length,
        1,
      );

      // Clear search
      notifier.clearSearch();
      expect(
        container.read(libraryControllerProvider).filteredMovies.length,
        2,
      );
    });

    test('sorts catalog deterministically across all SortOptions', () async {
      final fakeRepo = FakeLibraryRepository(
        onGetMovies: () async => const LibraryResponse(
          movies: [movieA, movieB, movieC, movieD],
          watching: [],
          total: 4,
        ),
      );

      final container = ProviderContainer(
        overrides: [libraryRepositoryProvider.overrideWithValue(fakeRepo)],
      );
      addTearDown(container.dispose);

      await container.read(libraryControllerProvider.notifier).loadLibrary();
      final notifier = container.read(libraryControllerProvider.notifier);

      // 1. Title A-Z (default)
      notifier.setSortOption(SortOption.titleAsc);
      var titles = container
          .read(libraryControllerProvider)
          .filteredMovies
          .map((m) => m.title)
          .toList();
      expect(titles, [
        'Batman Knightfall',
        'Coyote vs Acme',
        'Spider-Man Brand New Day',
        'The Odyssey',
      ]);

      // 2. Title Z-A
      notifier.setSortOption(SortOption.titleDesc);
      titles = container
          .read(libraryControllerProvider)
          .filteredMovies
          .map((m) => m.title)
          .toList();
      expect(titles, [
        'The Odyssey',
        'Spider-Man Brand New Day',
        'Coyote vs Acme',
        'Batman Knightfall',
      ]);

      // 3. Year Descending (newest first, nulls at end)
      notifier.setSortOption(SortOption.yearDesc);
      titles = container
          .read(libraryControllerProvider)
          .filteredMovies
          .map((m) => m.title)
          .toList();
      expect(titles, [
        'Batman Knightfall', // 2026
        'Spider-Man Brand New Day', // 2025
        'The Odyssey', // 2024
        'Coyote vs Acme', // null
      ]);

      // 4. Year Ascending (oldest first, nulls at end)
      notifier.setSortOption(SortOption.yearAsc);
      titles = container
          .read(libraryControllerProvider)
          .filteredMovies
          .map((m) => m.title)
          .toList();
      expect(titles, [
        'The Odyssey', // 2024
        'Spider-Man Brand New Day', // 2025
        'Batman Knightfall', // 2026
        'Coyote vs Acme', // null
      ]);

      // 5. Rating Descending (highest first, nulls at end)
      notifier.setSortOption(SortOption.ratingDesc);
      titles = container
          .read(libraryControllerProvider)
          .filteredMovies
          .map((m) => m.title)
          .toList();
      expect(titles, [
        'The Odyssey', // 9.1
        'Batman Knightfall', // 8.4
        'Spider-Man Brand New Day', // 7.9
        'Coyote vs Acme', // null
      ]);

      // 6. Watch Progress Descending (highest percentage first)
      notifier.setSortOption(SortOption.progressDesc);
      titles = container
          .read(libraryControllerProvider)
          .filteredMovies
          .map((m) => m.title)
          .toList();
      expect(titles, [
        'The Odyssey', // 98%
        'Batman Knightfall', // 50%
        'Coyote vs Acme', // 0% (tie-break title A-Z)
        'Spider-Man Brand New Day', // 0%
      ]);

      // 7. Recently Added (newest updatedAt first)
      notifier.setSortOption(SortOption.recentlyAdded);
      titles = container
          .read(libraryControllerProvider)
          .filteredMovies
          .map((m) => m.title)
          .toList();
      expect(titles, [
        'The Odyssey', // 2026-09-26
        'Batman Knightfall', // 2026-09-25
        'Spider-Man Brand New Day', // 2026-09-24
        'Coyote vs Acme', // null
      ]);
    });

    test('filters catalog by WatchStatusFilter', () async {
      final fakeRepo = FakeLibraryRepository(
        onGetMovies: () async => const LibraryResponse(
          movies: [movieA, movieB, movieC, movieD],
          watching: [],
          total: 4,
        ),
      );

      final container = ProviderContainer(
        overrides: [libraryRepositoryProvider.overrideWithValue(fakeRepo)],
      );
      addTearDown(container.dispose);

      await container.read(libraryControllerProvider.notifier).loadLibrary();
      final notifier = container.read(libraryControllerProvider.notifier);

      // In Progress (percent > 0 && percent < 95)
      notifier.setWatchStatusFilter(WatchStatusFilter.inProgress);
      var titles = container
          .read(libraryControllerProvider)
          .filteredMovies
          .map((m) => m.title)
          .toList();
      expect(titles, ['Batman Knightfall']);

      // Unwatched (percent == 0)
      notifier.setWatchStatusFilter(WatchStatusFilter.unwatched);
      titles = container
          .read(libraryControllerProvider)
          .filteredMovies
          .map((m) => m.title)
          .toList();
      expect(titles, ['Coyote vs Acme', 'Spider-Man Brand New Day']);

      // Completed (percent >= 95)
      notifier.setWatchStatusFilter(WatchStatusFilter.completed);
      titles = container
          .read(libraryControllerProvider)
          .filteredMovies
          .map((m) => m.title)
          .toList();
      expect(titles, ['The Odyssey']);

      // All
      notifier.setWatchStatusFilter(WatchStatusFilter.all);
      expect(
        container.read(libraryControllerProvider).filteredMovies.length,
        4,
      );
    });

    test(
      'extracts canonical availableGenres and filters by selectedGenre',
      () async {
        final fakeRepo = FakeLibraryRepository(
          onGetMovies: () async => const LibraryResponse(
            movies: [movieA, movieB, movieC, movieD],
            watching: [],
            total: 4,
          ),
        );

        final container = ProviderContainer(
          overrides: [libraryRepositoryProvider.overrideWithValue(fakeRepo)],
        );
        addTearDown(container.dispose);

        await container.read(libraryControllerProvider.notifier).loadLibrary();
        final notifier = container.read(libraryControllerProvider.notifier);

        // Verify available genres extracted and deduplicated
        final genres = container
            .read(libraryControllerProvider)
            .availableGenres;
        expect(genres, [
          'Action',
          'Adventure',
          'Animation',
          'Comedy',
          'Drama',
          'Mystery',
          'Sci-Fi',
        ]);

        // Filter by 'Action'
        notifier.setSelectedGenre('Action');
        var titles = container
            .read(libraryControllerProvider)
            .filteredMovies
            .map((m) => m.title)
            .toList();
        expect(titles, ['Batman Knightfall', 'Spider-Man Brand New Day']);

        // Case-insensitive matching: 'comedy'
        notifier.setSelectedGenre('comedy');
        titles = container
            .read(libraryControllerProvider)
            .filteredMovies
            .map((m) => m.title)
            .toList();
        expect(titles, ['Coyote vs Acme']);

        // Clear genre with 'All'
        notifier.setSelectedGenre('All');
        expect(
          container.read(libraryControllerProvider).filteredMovies.length,
          4,
        );
        expect(container.read(libraryControllerProvider).selectedGenre, isNull);
      },
    );

    test(
      'composes search, watch status, genre filter, and sort order accurately',
      () async {
        final fakeRepo = FakeLibraryRepository(
          onGetMovies: () async => const LibraryResponse(
            movies: [movieA, movieB, movieC, movieD],
            watching: [],
            total: 4,
          ),
        );

        final container = ProviderContainer(
          overrides: [libraryRepositoryProvider.overrideWithValue(fakeRepo)],
        );
        addTearDown(container.dispose);

        await container.read(libraryControllerProvider.notifier).loadLibrary();
        final notifier = container.read(libraryControllerProvider.notifier);

        // Compound filter:
        // 1. Genre: Action (Batman, Spider-Man)
        notifier.setSelectedGenre('Action');
        // 2. Watch Status: inProgress (Batman only)
        notifier.setWatchStatusFilter(WatchStatusFilter.inProgress);
        // 3. Sort: Year Descending
        notifier.setSortOption(SortOption.yearDesc);

        var state = container.read(libraryControllerProvider);
        expect(state.activeFilterCount, 3);
        expect(state.hasActiveFilters, isTrue);
        expect(state.filteredMovies.length, 1);
        expect(state.filteredMovies.first.title, 'Batman Knightfall');

        // Add conflicting search query
        notifier.setSearchQuery('Spider');
        expect(
          container.read(libraryControllerProvider).filteredMovies,
          isEmpty,
        );

        // Reset filters restores canonical default state without affecting search query
        notifier.resetFilters();
        state = container.read(libraryControllerProvider);
        expect(state.sortOption, SortOption.titleAsc);
        expect(state.watchStatusFilter, WatchStatusFilter.all);
        expect(state.selectedGenre, isNull);
        expect(state.activeFilterCount, 0);
        expect(state.hasActiveFilters, isFalse);

        // With filters reset, search for 'Spider' finds Spider-Man
        expect(state.filteredMovies.length, 1);
        expect(state.filteredMovies.first.title, 'Spider-Man Brand New Day');
      },
    );

    test(
      'triggerScan invokes repository and updates isScanning flag',
      () async {
        var scanInvoked = false;
        final fakeRepo = FakeLibraryRepository(
          onTriggerScan: () async {
            scanInvoked = true;
            return true;
          },
        );

        final container = ProviderContainer(
          overrides: [libraryRepositoryProvider.overrideWithValue(fakeRepo)],
        );
        addTearDown(container.dispose);

        final success = await container
            .read(libraryControllerProvider.notifier)
            .triggerScan();

        expect(success, isTrue);
        expect(scanInvoked, isTrue);
        expect(container.read(libraryControllerProvider).isScanning, isFalse);
      },
    );
  });
}
