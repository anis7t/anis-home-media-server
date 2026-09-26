import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/api/api_client.dart';
import '../../data/models/movie_item.dart';
import '../controllers/library_controller.dart';
import '../widgets/continue_watching_rail.dart';
import '../widgets/movie_grid.dart';
import '../widgets/sort_filter_sheet.dart';
import '../../../updater/presentation/widgets/settings_sheet.dart';

/// Main home and media catalog screen with responsive grid, continue-watching rail,
/// instant search with debouncing, and sort/filter capabilities.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounceTimer;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String val) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) {
        ref.read(libraryControllerProvider.notifier).setSearchQuery(val);
      }
    });
  }

  void _onClearSearch() {
    _debounceTimer?.cancel();
    _searchController.clear();
    ref.read(libraryControllerProvider.notifier).clearSearch();
  }

  void _onMovieSelected(MovieItem movie) {
    context.push(AppRoutes.movieDetails, extra: movie);
  }

  void _onResumeWatching(MovieItem movie) {
    final baseUrl = ref.read(serverBaseUrlProvider);
    final mediaUrl = '$baseUrl/media/${Uri.encodeComponent(movie.filename)}';

    context.push(
      AppRoutes.player,
      extra: {
        'mediaUrl': mediaUrl,
        'title': movie.title,
        'subtitle': '${movie.year ?? ''} • ${movie.formattedRuntime}',
        'startPosition': movie.position > 0
            ? Duration(seconds: movie.position.toInt())
            : null,
      },
    );
  }

  Future<void> _handleScan() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    scaffoldMessenger.showSnackBar(
      const SnackBar(
        content: Text('Triggering server library scan...'),
        duration: Duration(seconds: 2),
      ),
    );

    final success = await ref
        .read(libraryControllerProvider.notifier)
        .triggerScan();

    if (mounted) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Library scan completed successfully'
                : 'Failed to trigger library scan',
          ),
          backgroundColor: success
              ? AppColors.statusSuccess
              : AppColors.statusError,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(libraryControllerProvider);
    final baseUrl = ref.watch(serverBaseUrlProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildFrostedHeader(state),
            _buildSearchAndFilterRow(state),
            Expanded(
              child: RefreshIndicator(
                color: AppColors.brandRed,
                backgroundColor: AppColors.surfaceElevated,
                onRefresh: () => ref
                    .read(libraryControllerProvider.notifier)
                    .loadLibrary(isRefresh: true),
                child: _buildContent(state, baseUrl),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFrostedHeader(LibraryState state) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: Row(
        children: [
          // Brand Icon & Identity
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.borderMedium),
              boxShadow: const [
                BoxShadow(
                  color: AppColors.brandRedGlow,
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: const Center(
              child: Icon(
                Icons.play_arrow_rounded,
                color: AppColors.brandRed,
                size: 24,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Row(
                  children: [
                    Text(
                      "Anis' ",
                      style: TextStyle(
                        color: AppColors.brandRedLight,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      'Home Media Server',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'PLAY • ORGANIZE • ENJOY',
                  style: AppTypography.labelSmall.copyWith(
                    color: AppColors.textMuted,
                    letterSpacing: 1.2,
                    fontSize: 9.5,
                  ),
                ),
              ],
            ),
          ),

          // Scan Action Button
          IconButton(
            tooltip: 'Scan Library Files',
            icon: state.isScanning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.brandRed,
                    ),
                  )
                : const Icon(
                    Icons.sync_rounded,
                    color: AppColors.textSecondary,
                    size: 22,
                  ),
            onPressed: state.isScanning ? null : _handleScan,
          ),

          // Application & Server Settings Button
          IconButton(
            tooltip: 'Settings & Updates',
            icon: const Icon(
              Icons.settings_rounded,
              color: AppColors.textSecondary,
              size: 22,
            ),
            onPressed: () => SettingsSheet.show(context),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndFilterRow(LibraryState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.borderSubtle),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.search_rounded,
                        color: AppColors.textMuted,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          style: AppTypography.bodyLarge.copyWith(fontSize: 14),
                          decoration: const InputDecoration(
                            hintText: 'Search movies, years, genres...',
                            hintStyle: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 13.5,
                            ),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onChanged: _onSearchChanged,
                        ),
                      ),
                      if (_searchController.text.isNotEmpty)
                        GestureDetector(
                          onTap: _onClearSearch,
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.close_rounded,
                              color: AppColors.textMuted,
                              size: 18,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),

              // Sort & Filter Sheet Trigger Button
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => SortFilterSheet.show(context: context),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: state.hasActiveFilters
                          ? AppColors.brandRed.withValues(alpha: 0.15)
                          : AppColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: state.hasActiveFilters
                            ? AppColors.brandRed.withValues(alpha: 0.5)
                            : AppColors.borderSubtle,
                      ),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Icon(
                          Icons.filter_list_rounded,
                          color: state.hasActiveFilters
                              ? AppColors.brandRedLight
                              : AppColors.textSecondary,
                          size: 20,
                        ),
                        if (state.hasActiveFilters)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: Container(
                              width: 7,
                              height: 7,
                              decoration: const BoxDecoration(
                                color: AppColors.brandRed,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),

          // Active Filter Chips Rail
          if (state.hasActiveFilters) ...[
            const SizedBox(height: 8),
            _buildActiveFiltersRail(state),
          ],
        ],
      ),
    );
  }

  Widget _buildActiveFiltersRail(LibraryState state) {
    final notifier = ref.read(libraryControllerProvider.notifier);
    final chips = <Widget>[];

    // Sort option chip (if not default titleAsc)
    if (state.sortOption != SortOption.titleAsc) {
      chips.add(
        _buildActiveChip(
          label: _getSortLabel(state.sortOption),
          onRemove: () => notifier.setSortOption(SortOption.titleAsc),
        ),
      );
    }

    // Watch status chip (if not default all)
    if (state.watchStatusFilter != WatchStatusFilter.all) {
      chips.add(
        _buildActiveChip(
          label: _getWatchStatusLabel(state.watchStatusFilter),
          onRemove: () => notifier.setWatchStatusFilter(WatchStatusFilter.all),
        ),
      );
    }

    // Genre chip
    if (state.selectedGenre != null && state.selectedGenre!.isNotEmpty) {
      chips.add(
        _buildActiveChip(
          label: state.selectedGenre!,
          onRemove: () => notifier.setSelectedGenre(null),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          ...chips,
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () => notifier.resetFilters(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                'Reset All',
                style: AppTypography.labelSmall.copyWith(
                  color: AppColors.brandRedLight,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveChip({
    required String label,
    required VoidCallback onRemove,
  }) {
    return Container(
      key: ValueKey('active_chip_$label'),
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.brandRed.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            key: ValueKey('remove_chip_$label'),
            onTap: onRemove,
            child: const Icon(
              Icons.close_rounded,
              size: 14,
              color: AppColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  String _getSortLabel(SortOption option) {
    switch (option) {
      case SortOption.titleAsc:
        return 'A → Z';
      case SortOption.titleDesc:
        return 'Z → A';
      case SortOption.yearDesc:
        return 'Year (Newest)';
      case SortOption.yearAsc:
        return 'Year (Oldest)';
      case SortOption.ratingDesc:
        return 'Rating';
      case SortOption.progressDesc:
        return 'Progress';
      case SortOption.recentlyAdded:
        return 'Recently Added';
    }
  }

  String _getWatchStatusLabel(WatchStatusFilter filter) {
    switch (filter) {
      case WatchStatusFilter.all:
        return 'All';
      case WatchStatusFilter.inProgress:
        return 'In Progress';
      case WatchStatusFilter.unwatched:
        return 'Unwatched';
      case WatchStatusFilter.completed:
        return 'Completed';
    }
  }

  Widget _buildContent(LibraryState state, String baseUrl) {
    if (state.status == LibraryStatus.loading && state.movies.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              color: AppColors.brandRed,
              strokeWidth: 2.5,
            ),
            SizedBox(height: 16),
            Text(
              'Loading movie catalog...',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (state.status == LibraryStatus.error && state.movies.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.wifi_off_rounded,
                color: AppColors.statusError,
                size: 48,
              ),
              const SizedBox(height: 16),
              const Text(
                'Unable to reach media server',
                style: AppTypography.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                state.errorMessage ??
                    'Please verify your server URL and network.',
                textAlign: TextAlign.center,
                style: AppTypography.bodyMedium,
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: () =>
                    ref.read(libraryControllerProvider.notifier).loadLibrary(),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    final filtered = state.filteredMovies;
    final isSearching = state.searchQuery.trim().isNotEmpty;
    final hasWatching =
        !isSearching &&
        !state.hasActiveFilters &&
        state.continueWatching.isNotEmpty;

    if (state.movies.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.movie_filter_outlined,
                color: AppColors.textMuted,
                size: 54,
              ),
              const SizedBox(height: 16),
              const Text(
                'No movies in library',
                style: AppTypography.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Add video files to your media folder and scan to index them.',
                textAlign: TextAlign.center,
                style: AppTypography.bodyMedium,
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _handleScan,
                icon: const Icon(Icons.sync_rounded),
                label: const Text('Scan Media Directory'),
              ),
            ],
          ),
        ),
      );
    }

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        // Continue Watching Rail (hidden while searching or filtering)
        if (hasWatching)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ContinueWatchingRail(
                movies: state.continueWatching,
                baseUrl: baseUrl,
                onMovieTap: _onResumeWatching,
              ),
            ),
          ),

        // Section Title: "All Movies" or "Search Results" or "Filtered Movies"
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Text(
                  isSearching
                      ? 'Results for "${state.searchQuery}"'
                      : state.hasActiveFilters
                      ? 'Filtered Movies'
                      : 'All Movies',
                  style: AppTypography.titleLarge,
                ),
                const SizedBox(width: 8),
                Text(
                  '(${filtered.length})',
                  style: AppTypography.labelSmall.copyWith(
                    color: AppColors.textMuted,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),

        // Populated Movie Grid or Empty Results State
        if (filtered.isEmpty && (isSearching || state.hasActiveFilters))
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.search_off_rounded,
                      color: AppColors.textMuted,
                      size: 44,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      isSearching
                          ? 'No matching movies for "${state.searchQuery}"'
                          : 'No movies match active filters',
                      style: AppTypography.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      isSearching
                          ? 'Check the spelling or try searching by release year or genre.'
                          : 'Try changing your sort or filter settings.',
                      style: AppTypography.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    if (state.hasActiveFilters) ...[
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: () => ref
                            .read(libraryControllerProvider.notifier)
                            .resetFilters(),
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('Reset Filters'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          )
        else
          SliverToBoxAdapter(
            child: MovieGrid(
              movies: filtered,
              baseUrl: baseUrl,
              onMovieTap: _onMovieSelected,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
            ),
          ),

        // Bottom padding
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}
