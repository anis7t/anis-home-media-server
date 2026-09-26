import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/errors/app_exception.dart';
import '../../data/models/movie_item.dart';
import '../../data/repositories/library_repository.dart';

enum LibraryStatus { initial, loading, loaded, error }

/// Sorting options supported across the library catalog.
enum SortOption {
  titleAsc,
  titleDesc,
  yearDesc,
  yearAsc,
  ratingDesc,
  progressDesc,
  recentlyAdded,
}

/// Watch progress filter options.
enum WatchStatusFilter { all, inProgress, unwatched, completed }

/// Immutable state for the media library screen.
@immutable
class LibraryState {
  final LibraryStatus status;
  final List<MovieItem> movies;
  final List<MovieItem> continueWatching;
  final int total;
  final String? errorMessage;
  final String searchQuery;
  final bool isRefreshing;
  final bool isScanning;
  final SortOption sortOption;
  final WatchStatusFilter watchStatusFilter;
  final String? selectedGenre;

  const LibraryState({
    this.status = LibraryStatus.initial,
    this.movies = const [],
    this.continueWatching = const [],
    this.total = 0,
    this.errorMessage,
    this.searchQuery = '',
    this.isRefreshing = false,
    this.isScanning = false,
    this.sortOption = SortOption.titleAsc,
    this.watchStatusFilter = WatchStatusFilter.all,
    this.selectedGenre,
  });

  /// In-memory filtered and sorted list based on search, filters, and sort options.
  List<MovieItem> get filteredMovies {
    Iterable<MovieItem> result = movies;

    // 1. Search Query filter (title, year, overview, genres)
    if (searchQuery.trim().isNotEmpty) {
      final q = searchQuery.trim().toLowerCase();
      result = result.where((m) {
        final title = m.title.toLowerCase();
        final year = m.year?.toString() ?? '';
        final overview = m.overview.toLowerCase();
        final genres = m.genres.toLowerCase();
        return title.contains(q) ||
            year.contains(q) ||
            overview.contains(q) ||
            genres.contains(q);
      });
    }

    // 2. Watch Status filter
    if (watchStatusFilter != WatchStatusFilter.all) {
      result = result.where((m) => _matchesWatchStatus(m, watchStatusFilter));
    }

    // 3. Genre filter
    if (selectedGenre != null &&
        selectedGenre!.trim().isNotEmpty &&
        selectedGenre!.trim().toLowerCase() != 'all') {
      result = result.where((m) => _matchesGenre(m, selectedGenre!));
    }

    // 4. Deterministic sorting
    final list = result.toList();
    list.sort((a, b) => _compareMovies(a, b, sortOption));
    return list;
  }

  /// Extracts unique canonical genres discovered across all catalog movies.
  List<String> get availableGenres {
    final Map<String, String> canonical = {};
    for (final m in movies) {
      if (m.genres.trim().isEmpty) continue;
      for (final raw in m.genres.split(',')) {
        final trimmed = raw.trim();
        if (trimmed.isEmpty) continue;
        final lower = trimmed.toLowerCase();
        if (!canonical.containsKey(lower)) {
          canonical[lower] = trimmed.length > 1
              ? '${trimmed[0].toUpperCase()}${trimmed.substring(1)}'
              : trimmed.toUpperCase();
        }
      }
    }
    final sorted = canonical.values.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted;
  }

  /// Total count of active non-default sort and filter selections.
  int get activeFilterCount {
    var count = 0;
    if (sortOption != SortOption.titleAsc) count++;
    if (watchStatusFilter != WatchStatusFilter.all) count++;
    if (selectedGenre != null &&
        selectedGenre!.trim().isNotEmpty &&
        selectedGenre!.trim().toLowerCase() != 'all') {
      count++;
    }
    return count;
  }

  bool get hasActiveFilters => activeFilterCount > 0;

  static bool _matchesWatchStatus(MovieItem m, WatchStatusFilter filter) {
    switch (filter) {
      case WatchStatusFilter.all:
        return true;
      case WatchStatusFilter.inProgress:
        return (m.percent > 0 || m.position > 10) && m.percent < 95;
      case WatchStatusFilter.unwatched:
        return m.percent == 0 && m.position <= 10;
      case WatchStatusFilter.completed:
        return m.percent >= 95;
    }
  }

  static bool _matchesGenre(MovieItem m, String selectedGenre) {
    final target = selectedGenre.trim().toLowerCase();
    final itemGenres = m.genres
        .split(',')
        .map((g) => g.trim().toLowerCase())
        .where((g) => g.isNotEmpty);
    return itemGenres.contains(target);
  }

  static int _compareMovies(MovieItem a, MovieItem b, SortOption sortOption) {
    int result = 0;
    switch (sortOption) {
      case SortOption.titleAsc:
        result = a.title.toLowerCase().compareTo(b.title.toLowerCase());
        break;
      case SortOption.titleDesc:
        result = b.title.toLowerCase().compareTo(a.title.toLowerCase());
        break;
      case SortOption.yearDesc:
        final yA = a.year ?? -1;
        final yB = b.year ?? -1;
        result = yB.compareTo(yA);
        break;
      case SortOption.yearAsc:
        final yA = a.year ?? 99999;
        final yB = b.year ?? 99999;
        result = yA.compareTo(yB);
        break;
      case SortOption.ratingDesc:
        final rA = a.rating ?? -1.0;
        final rB = b.rating ?? -1.0;
        result = rB.compareTo(rA);
        break;
      case SortOption.progressDesc:
        final pA = a.percent;
        final pB = b.percent;
        result = pB.compareTo(pA);
        break;
      case SortOption.recentlyAdded:
        final uA = a.updatedAt ?? '';
        final uB = b.updatedAt ?? '';
        result = uB.compareTo(uA);
        break;
    }

    // Deterministic tie-breaking by lowercase title, then filename
    if (result == 0) {
      result = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    }
    if (result == 0) {
      result = a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
    }
    return result;
  }

  LibraryState copyWith({
    LibraryStatus? status,
    List<MovieItem>? movies,
    List<MovieItem>? continueWatching,
    int? total,
    String? errorMessage,
    bool clearError = false,
    String? searchQuery,
    bool? isRefreshing,
    bool? isScanning,
    SortOption? sortOption,
    WatchStatusFilter? watchStatusFilter,
    String? selectedGenre,
    bool clearSelectedGenre = false,
  }) {
    return LibraryState(
      status: status ?? this.status,
      movies: movies ?? this.movies,
      continueWatching: continueWatching ?? this.continueWatching,
      total: total ?? this.total,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      searchQuery: searchQuery ?? this.searchQuery,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      isScanning: isScanning ?? this.isScanning,
      sortOption: sortOption ?? this.sortOption,
      watchStatusFilter: watchStatusFilter ?? this.watchStatusFilter,
      selectedGenre: clearSelectedGenre
          ? null
          : (selectedGenre ?? this.selectedGenre),
    );
  }
}

/// Controller managing library catalog fetching, searching, sorting, filtering, and scans.
class LibraryController extends Notifier<LibraryState> {
  late final LibraryRepository _repository;

  @override
  LibraryState build() {
    _repository = ref.watch(libraryRepositoryProvider);
    Future.microtask(() => loadLibrary());
    return const LibraryState(status: LibraryStatus.loading);
  }

  /// Fetches the latest movie catalog and continue-watching list from the server.
  /// When [isRefresh] is true, preserves current list to avoid UI flicker.
  Future<void> loadLibrary({bool isRefresh = false}) async {
    if (isRefresh) {
      state = state.copyWith(isRefreshing: true, clearError: true);
    } else if (state.movies.isEmpty) {
      state = state.copyWith(status: LibraryStatus.loading, clearError: true);
    }

    try {
      final response = await _repository.getMovies();
      state = state.copyWith(
        status: LibraryStatus.loaded,
        movies: response.movies,
        continueWatching: response.watching,
        total: response.total,
        isRefreshing: false,
        clearError: true,
      );
    } on AppException catch (e) {
      state = state.copyWith(
        status: state.movies.isEmpty
            ? LibraryStatus.error
            : LibraryStatus.loaded,
        errorMessage: e.message,
        isRefreshing: false,
      );
    } catch (e) {
      state = state.copyWith(
        status: state.movies.isEmpty
            ? LibraryStatus.error
            : LibraryStatus.loaded,
        errorMessage: 'An unexpected error occurred: $e',
        isRefreshing: false,
      );
    }
  }

  /// Updates the in-memory search query.
  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  /// Clears the active search query.
  void clearSearch() {
    state = state.copyWith(searchQuery: '');
  }

  /// Updates the active sort option.
  void setSortOption(SortOption option) {
    state = state.copyWith(sortOption: option);
  }

  /// Updates the active watch progress filter.
  void setWatchStatusFilter(WatchStatusFilter filter) {
    state = state.copyWith(watchStatusFilter: filter);
  }

  /// Updates the active genre filter. Passing null or 'All' clears the filter.
  void setSelectedGenre(String? genre) {
    if (genre == null || genre.trim().toLowerCase() == 'all') {
      state = state.copyWith(clearSelectedGenre: true);
    } else {
      state = state.copyWith(selectedGenre: genre.trim());
    }
  }

  /// Resets all sort and filter selections to their canonical defaults.
  void resetFilters() {
    state = state.copyWith(
      sortOption: SortOption.titleAsc,
      watchStatusFilter: WatchStatusFilter.all,
      clearSelectedGenre: true,
    );
  }

  /// Triggers an explicit background library scan on the media server.
  Future<bool> triggerScan() async {
    state = state.copyWith(isScanning: true);
    try {
      final success = await _repository.triggerScan();
      state = state.copyWith(isScanning: false);
      if (success) {
        await loadLibrary(isRefresh: true);
      }
      return success;
    } catch (e) {
      state = state.copyWith(isScanning: false);
      return false;
    }
  }
}

/// Riverpod provider for LibraryController.
final libraryControllerProvider =
    NotifierProvider<LibraryController, LibraryState>(LibraryController.new);
