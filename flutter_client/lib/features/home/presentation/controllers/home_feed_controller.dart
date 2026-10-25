import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../library/domain/models/movie_item.dart';
import '../../../library/presentation/controllers/library_controller.dart';
import '../../domain/models/genre_section.dart';

/// Immutable state for the endless home discovery feed.
@immutable
class HomeFeedState {
  final List<MovieItem> continueWatching;
  final List<MovieItem> recentlyAdded;
  final List<GenreSection> allGenreSections;
  final List<DecadeSection> decadeSections;
  final int visibleRailCount;
  final bool isLoadingMore;

  const HomeFeedState({
    this.continueWatching = const [],
    this.recentlyAdded = const [],
    this.allGenreSections = const [],
    this.decadeSections = const [],
    this.visibleRailCount = 3,
    this.isLoadingMore = false,
  });

  /// The currently visible genre sections based on scroll progress.
  List<GenreSection> get visibleGenreSections =>
      allGenreSections.take(visibleRailCount).toList();

  /// Whether there are additional genre rails waiting to be lazily loaded.
  bool get hasMoreRails => visibleRailCount < allGenreSections.length;

  /// Total number of movies in the catalog.
  int get totalMovieCount =>
      recentlyAdded.isNotEmpty ? recentlyAdded.length : 0;

  HomeFeedState copyWith({
    List<MovieItem>? continueWatching,
    List<MovieItem>? recentlyAdded,
    List<GenreSection>? allGenreSections,
    List<DecadeSection>? decadeSections,
    int? visibleRailCount,
    bool? isLoadingMore,
  }) {
    return HomeFeedState(
      continueWatching: continueWatching ?? this.continueWatching,
      recentlyAdded: recentlyAdded ?? this.recentlyAdded,
      allGenreSections: allGenreSections ?? this.allGenreSections,
      decadeSections: decadeSections ?? this.decadeSections,
      visibleRailCount: visibleRailCount ?? this.visibleRailCount,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    );
  }
}

/// Controller managing endless home feed partitioning, sorting, and lazy rail loading.
class HomeFeedController extends Notifier<HomeFeedState> {
  static const int initialRails = 3;
  static const int railsPerBatch = 2;

  @override
  HomeFeedState build() {
    final libraryState = ref.watch(libraryControllerProvider);
    final previousRailCount = stateOrNull?.visibleRailCount ?? initialRails;
    return _computeState(libraryState, previousRailCount);
  }

  HomeFeedState _computeState(LibraryState libraryState, int railCount) {
    final movies = libraryState.movies;
    if (movies.isEmpty) {
      return const HomeFeedState();
    }

    // 1. Recently Added: sorted by updatedAt desc, then releaseDate desc
    final recent = List<MovieItem>.from(movies);
    recent.sort((a, b) {
      final uA = a.updatedAt ?? '';
      final uB = b.updatedAt ?? '';
      final cmp = uB.compareTo(uA);
      if (cmp != 0) return cmp;
      final yA = a.year ?? 0;
      final yB = b.year ?? 0;
      return yB.compareTo(yA);
    });

    // 2. Extract canonical genres and partition movies
    final Map<String, List<MovieItem>> genreMap = {};
    for (final m in movies) {
      if (m.genres.trim().isEmpty) continue;
      for (final raw in m.genres.split(',')) {
        final trimmed = raw.trim();
        if (trimmed.isEmpty) continue;
        final canonicalName = trimmed.length > 1
            ? '${trimmed[0].toUpperCase()}${trimmed.substring(1)}'
            : trimmed.toUpperCase();
        genreMap.putIfAbsent(canonicalName, () => []).add(m);
      }
    }

    // Sort movies inside each genre by rating desc, then year desc
    final List<GenreSection> genreSections = [];
    genreMap.forEach((genre, genreMovies) {
      final sortedMovies = List<MovieItem>.from(genreMovies);
      sortedMovies.sort((a, b) {
        final rA = a.rating ?? -1.0;
        final rB = b.rating ?? -1.0;
        final rCmp = rB.compareTo(rA);
        if (rCmp != 0) return rCmp;
        return (b.year ?? 0).compareTo(a.year ?? 0);
      });
      genreSections.add(GenreSection(
        genre: genre,
        movies: sortedMovies,
        totalCount: sortedMovies.length,
      ));
    });

    // Sort genre rails by movie count descending, then alphabetically
    genreSections.sort((a, b) {
      final countCmp = b.totalCount.compareTo(a.totalCount);
      if (countCmp != 0) return countCmp;
      return a.genre.toLowerCase().compareTo(b.genre.toLowerCase());
    });

    // 3. Compute Decades
    final List<DecadeSection> decades = [];
    final eraBuckets = <String, (int?, int?)>{
      '2020s': (2020, 2029),
      '2010s': (2010, 2019),
      '2000s': (2000, 2009),
      '1990s': (1990, 1999),
      'Classic Cinema (<1990)': (null, 1989),
    };

    eraBuckets.forEach((label, bounds) {
      final (minY, maxY) = bounds;
      final count = movies.where((m) {
        final y = m.year;
        if (y == null) return false;
        if (minY != null && y < minY) return false;
        if (maxY != null && y > maxY) return false;
        return true;
      }).length;

      if (count > 0) {
        decades.add(DecadeSection(
          label: label,
          count: count,
          minYear: minY,
          maxYear: maxY,
        ));
      }
    });

    final effectiveRails = railCount > initialRails ? railCount : initialRails;

    return HomeFeedState(
      continueWatching: libraryState.continueWatching,
      recentlyAdded: recent,
      allGenreSections: genreSections,
      decadeSections: decades,
      visibleRailCount: effectiveRails,
    );
  }

  /// Lazily loads additional genre rails as the user scrolls down the home feed.
  void loadMoreRails() {
    if (!state.hasMoreRails || state.isLoadingMore) return;

    final nextCount = (state.visibleRailCount + railsPerBatch)
        .clamp(0, state.allGenreSections.length);

    state = state.copyWith(visibleRailCount: nextCount);
  }
}

/// Riverpod provider for HomeFeedController.
final homeFeedControllerProvider =
    NotifierProvider<HomeFeedController, HomeFeedState>(
  HomeFeedController.new,
);
