import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/home/presentation/controllers/home_feed_controller.dart';
import 'package:media_server_client/features/library/domain/models/movie_item.dart';
import 'package:media_server_client/features/library/presentation/controllers/library_controller.dart';

void main() {
  group('HomeFeedController Tests', () {
    late ProviderContainer container;

    final testMovies = [
      const MovieItem(
        filename: 'movie_action_1.mp4',
        title: 'Action Movie 1',
        year: 2024,
        rating: 8.5,
        genres: 'Action, Thriller',
        updatedAt: '2026-10-20T10:00:00Z',
      ),
      const MovieItem(
        filename: 'movie_action_2.mp4',
        title: 'Action Movie 2',
        year: 2022,
        rating: 7.2,
        genres: 'Action',
        updatedAt: '2026-10-18T10:00:00Z',
      ),
      const MovieItem(
        filename: 'movie_sci_fi.mp4',
        title: 'Sci-Fi Gem',
        year: 2015,
        rating: 9.0,
        genres: 'Sci-Fi',
        updatedAt: '2026-10-22T10:00:00Z',
      ),
      const MovieItem(
        filename: 'movie_drama.mp4',
        title: 'Emotional Drama',
        year: 1985,
        rating: 8.1,
        genres: 'Drama',
        updatedAt: '2026-10-01T10:00:00Z',
      ),
      const MovieItem(
        filename: 'movie_comedy.mp4',
        title: 'Hilarious Comedy',
        year: 2005,
        rating: 6.8,
        genres: 'Comedy',
        updatedAt: '2026-10-12T10:00:00Z',
      ),
    ];

    tearDown(() {
      container.dispose();
    });

    test('initializes with empty state when library is empty', () {
      container = ProviderContainer(
        overrides: [
          libraryControllerProvider.overrideWith(
            () => _FakeEmptyLibraryController(),
          ),
        ],
      );

      final state = container.read(homeFeedControllerProvider);
      expect(state.recentlyAdded, isEmpty);
      expect(state.allGenreSections, isEmpty);
      expect(state.decadeSections, isEmpty);
      expect(state.hasMoreRails, isFalse);
    });

    test('correctly partitions recentlyAdded, genre rails, and decade buckets', () {
      container = ProviderContainer(
        overrides: [
          libraryControllerProvider.overrideWith(
            () => _FakePopulatedLibraryController(testMovies),
          ),
        ],
      );

      final state = container.read(homeFeedControllerProvider);

      // 1. Recently Added should be sorted by updatedAt desc
      expect(state.recentlyAdded.first.title, 'Sci-Fi Gem'); // 2026-10-22
      expect(state.recentlyAdded[1].title, 'Action Movie 1'); // 2026-10-20
      expect(state.recentlyAdded.last.title, 'Emotional Drama'); // 2026-10-01

      // 2. Genre rails: Action has 2 movies, Thriller (1), Sci-Fi (1), Drama (1), Comedy (1)
      expect(state.allGenreSections.first.genre, 'Action');
      expect(state.allGenreSections.first.totalCount, 2);

      // Verify movies within Action rail are sorted by rating desc
      expect(state.allGenreSections.first.movies.first.rating, 8.5);
      expect(state.allGenreSections.first.movies.last.rating, 7.2);

      // 3. Decade buckets:
      // 2020s: 2 (2024, 2022)
      // 2010s: 1 (2015)
      // 2000s: 1 (2005)
      // Classic Cinema (<1990): 1 (1985)
      final decadeLabels = state.decadeSections.map((d) => d.label).toList();
      expect(decadeLabels, contains('2020s'));
      expect(decadeLabels, contains('2010s'));
      expect(decadeLabels, contains('2000s'));
      expect(decadeLabels, contains('Classic Cinema (<1990)'));
      expect(decadeLabels, isNot(contains('1990s'))); // 0 movies in 1990s
    });

    test('lazy rail pagination increments visible rails', () {
      container = ProviderContainer(
        overrides: [
          libraryControllerProvider.overrideWith(
            () => _FakePopulatedLibraryController(testMovies),
          ),
        ],
      );

      final notifier = container.read(homeFeedControllerProvider.notifier);
      final initialState = container.read(homeFeedControllerProvider);

      // There are 5 genres: Action, Comedy, Drama, Sci-Fi, Thriller
      expect(initialState.allGenreSections.length, 5);
      expect(initialState.visibleRailCount, 3);
      expect(initialState.visibleGenreSections.length, 3);
      expect(initialState.hasMoreRails, isTrue);

      // Load more rails: +2
      notifier.loadMoreRails();
      final updatedState = container.read(homeFeedControllerProvider);
      expect(updatedState.visibleRailCount, 5);
      expect(updatedState.visibleGenreSections.length, 5);
      expect(updatedState.hasMoreRails, isFalse);
    });
  });
}

class _FakeEmptyLibraryController extends LibraryController {
  @override
  LibraryState build() {
    return const LibraryState(status: LibraryStatus.loaded, movies: []);
  }
}

class _FakePopulatedLibraryController extends LibraryController {
  final List<MovieItem> _movies;
  _FakePopulatedLibraryController(this._movies);

  @override
  LibraryState build() {
    return LibraryState(
      status: LibraryStatus.loaded,
      movies: _movies,
      total: _movies.length,
    );
  }
}
