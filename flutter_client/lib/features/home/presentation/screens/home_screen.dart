import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/api/api_client.dart';
import '../../../../core/device/data/device_capability_service.dart';
import '../../../../core/widgets/tv_focusable.dart';
import '../../../library/domain/models/movie_item.dart';
import '../../../library/presentation/controllers/library_controller.dart';
import '../../../library/presentation/widgets/continue_watching_rail.dart';
import '../../../library/presentation/widgets/movie_grid.dart';
import '../controllers/home_feed_controller.dart';
import '../widgets/frosted_tree_drawer.dart';
import '../widgets/genre_rail_widget.dart';

/// Primary landing and dashboard screen featuring an endless discovery feed.
/// Combines Continue Watching, Recently Added, and dynamic lazy-loaded genre rails,
/// with instant access to the hierarchical Frosted Obsidian Tree Drawer.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final ScrollController _scrollController = ScrollController();
  late final TextEditingController _searchController;
  late final FocusNode _searchFocusNode;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text: ref.read(libraryControllerProvider).searchQuery,
    );
    _searchFocusNode = FocusNode(debugLabel: 'home_catalog_search');
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 450) {
      ref.read(homeFeedControllerProvider.notifier).loadMoreRails();
    }
  }

  void _onMovieSelected(BuildContext context, MovieItem movie) {
    context.push(AppRoutes.movieDetails, extra: movie);
  }

  void _navigateToHome(BuildContext context) {
    try {
      StatefulNavigationShell.of(context).goBranch(0);
    } catch (_) {
      context.go(AppRoutes.home);
    }
  }

  void _navigateToTvLibrary(BuildContext context) {
    try {
      StatefulNavigationShell.of(context).goBranch(1);
    } catch (_) {
      context.go(AppRoutes.library);
    }
  }

  void _onGenreSelectedFromTree(String genre) {
    final controller = ref.read(libraryControllerProvider.notifier);
    controller.resetFilters();
    controller.clearSearch();
    controller.setSelectedGenre(genre);
    _navigateToHome(context);
  }

  void _onDecadeSelectedFromTree(String decade) {
    final query = decade.replaceAll(RegExp(r'[^0-9]'), '');
    final prefix = query.length >= 3 ? query.substring(0, 3) : query;
    final controller = ref.read(libraryControllerProvider.notifier);
    controller.resetFilters();
    controller.setSearchQuery(prefix);
    _navigateToHome(context);
  }

  void _onSearchChanged(String query) {
    ref.read(libraryControllerProvider.notifier).setSearchQuery(query);
  }

  void _focusSearch() {
    _searchFocusNode.requestFocus();
  }

  void _clearHomeBrowse() {
    _searchController.clear();
    final controller = ref.read(libraryControllerProvider.notifier);
    controller.clearSearch();
    controller.resetFilters();
  }

  Future<void> _handleScan(BuildContext context, WidgetRef ref) async {
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

    if (context.mounted) {
      scaffoldMessenger.hideCurrentSnackBar();
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Library scan started successfully'
                : 'Could not start scan (check connection or admin access)',
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
    final libraryState = ref.watch(libraryControllerProvider);
    final feedState = ref.watch(homeFeedControllerProvider);
    final baseUrl = ref.watch(serverBaseUrlProvider);
    final isTv = ref.watch(isTvModeProvider);

    ref.listen<String>(
      libraryControllerProvider.select((state) => state.searchQuery),
      (previous, query) {
        if (_searchController.text == query) return;
        _searchController.value = TextEditingValue(
          text: query,
          selection: TextSelection.collapsed(offset: query.length),
        );
      },
    );

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppColors.background,
      drawerEnableOpenDragGesture: true,
      drawer: FrostedTreeDrawer(
        onGenreSelected: _onGenreSelectedFromTree,
        onDecadeSelected: _onDecadeSelectedFromTree,
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildFrostedHeader(context, libraryState, isTv),
            if (!isTv) _buildHomeSearch(libraryState),
            Expanded(
              child: RefreshIndicator(
                color: AppColors.brandRed,
                backgroundColor: AppColors.surfaceElevated,
                onRefresh: () => ref
                    .read(libraryControllerProvider.notifier)
                    .loadLibrary(isRefresh: true),
                child: _buildBody(
                  context,
                  libraryState,
                  feedState,
                  baseUrl,
                  isTv,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFrostedHeader(
    BuildContext context,
    LibraryState state,
    bool isTv,
  ) {
    if (isTv) {
      return Container(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
        ),
        child: Row(
          children: [
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.account_tree_rounded,
                      color: AppColors.brandRedLight,
                      size: 16,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Catalog Tree',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            Text(
              'Home',
              style: AppTypography.titleLarge.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onPressed: state.isScanning
                  ? null
                  : () => _handleScan(context, ref),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    state.isScanning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.brandRed,
                            ),
                          )
                        : const Icon(
                            Icons.sync_rounded,
                            color: AppColors.textSecondary,
                            size: 18,
                          ),
                    const SizedBox(width: 8),
                    const Text(
                      'Scan Library',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final isCompactPhone = MediaQuery.sizeOf(context).width < 390;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Open navigation menu',
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            style: IconButton.styleFrom(
              backgroundColor: AppColors.surfaceElevated,
              foregroundColor: AppColors.brandRedLight,
              minimumSize: const Size(44, 44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.menu_rounded, size: 24),
          ),
          const SizedBox(width: 10),
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
                    Flexible(
                      child: Text(
                        'Home Media Server',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                ),
                if (!isCompactPhone) ...[
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
              ],
            ),
          ),
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
            onPressed: state.isScanning
                ? null
                : () => _handleScan(context, ref),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeSearch(LibraryState state) {
    final canClear =
        _searchController.text.isNotEmpty || state.hasActiveFilters;

    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        height: 64,
        child: TextField(
          key: const ValueKey('home_catalog_search'),
          controller: _searchController,
          focusNode: _searchFocusNode,
          textInputAction: TextInputAction.search,
          style: AppTypography.bodyLarge.copyWith(fontSize: 16),
          onChanged: _onSearchChanged,
          onSubmitted: (_) => _searchFocusNode.unfocus(),
          decoration: InputDecoration(
            prefixIcon: const Icon(
              Icons.search_rounded,
              color: AppColors.brandRedLight,
              size: 24,
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 52),
            hintText: 'Search your collection',
            hintStyle: AppTypography.bodyMedium.copyWith(
              color: AppColors.textMuted,
              fontSize: 15,
            ),
            suffixIcon: canClear
                ? IconButton(
                    tooltip: 'Clear search and filters',
                    onPressed: _clearHomeBrowse,
                    icon: const Icon(Icons.close_rounded),
                    color: AppColors.textSecondary,
                  )
                : null,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
            filled: false,
            isDense: false,
            contentPadding: const EdgeInsets.symmetric(vertical: 20),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    LibraryState state,
    HomeFeedState feedState,
    String baseUrl,
    bool isTv,
  ) {
    if (state.status == LibraryStatus.loading && state.movies.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.brandRed),
      );
    }

    if (state.status == LibraryStatus.error && state.movies.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.cloud_off_rounded,
                  size: 48,
                  color: AppColors.statusError,
                ),
                const SizedBox(height: 16),
                Text(
                  'Failed to Connect to Server',
                  style: AppTypography.titleLarge.copyWith(
                    color: AppColors.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  state.errorMessage ??
                      'Could not fetch media catalog from the server.',
                  style: AppTypography.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.brandRed,
                    foregroundColor: AppColors.textOnBrand,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () => ref
                      .read(libraryControllerProvider.notifier)
                      .loadLibrary(),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Retry Connection'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (state.movies.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.borderMedium),
                  ),
                  child: const Icon(
                    Icons.movie_filter_outlined,
                    size: 32,
                    color: AppColors.brandRedLight,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Your Media Library is Empty',
                  style: AppTypography.titleLarge.copyWith(
                    color: AppColors.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'No video files found in the configured server directory. Add media files to your server or trigger a scan to discover them.',
                  style: AppTypography.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.45,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.brandRed,
                    foregroundColor: AppColors.textOnBrand,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () => _handleScan(context, ref),
                  icon: const Icon(Icons.sync_rounded, size: 18),
                  label: const Text('Scan Library Files'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppColors.borderMedium),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () => context.push(AppRoutes.connection),
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: const Text('Configure Server Origin'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!isTv &&
        (state.searchQuery.trim().isNotEmpty || state.hasActiveFilters)) {
      return _buildHomeCatalogResults(state, baseUrl);
    }

    return ListView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        // Section 0: Continue Watching rail if present
        if (feedState.continueWatching.isNotEmpty) ...[
          const SizedBox(height: 10),
          ContinueWatchingRail(
            movies: feedState.continueWatching,
            baseUrl: baseUrl,
            phoneLayout: !isTv,
            onMovieTap: (m) => _onMovieSelected(context, m),
          ),
        ],

        const SizedBox(height: 14),

        // The TV keeps its established catalog shortcut; phone discovery stays on Home.
        if (isTv) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TvFocusable(
              borderRadius: BorderRadius.circular(14),
              onPressed: () => _navigateToTvLibrary(context),
              builder: (context, isFocused, _) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: isFocused
                        ? AppColors.surfaceHighlight
                        : AppColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isFocused
                          ? AppColors.brandRed
                          : AppColors.borderSubtle,
                      width: isFocused ? 2.5 : 1.0,
                    ),
                    boxShadow: isFocused
                        ? [
                            BoxShadow(
                              color: AppColors.brandRedGlow.withValues(
                                alpha: 0.65,
                              ),
                              blurRadius: 18,
                              spreadRadius: 2,
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: isFocused
                              ? AppColors.brandRed.withValues(alpha: 0.22)
                              : AppColors.surface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isFocused
                                ? AppColors.brandRed
                                : AppColors.borderMedium,
                          ),
                        ),
                        child: const Icon(
                          Icons.video_library_rounded,
                          color: AppColors.brandRedLight,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Browse Full Library',
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 14.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${state.movies.length} movies available • Tap left menu for tree view',
                              style: AppTypography.labelSmall.copyWith(
                                color: isFocused
                                    ? AppColors.textSecondary
                                    : AppColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_ios_rounded,
                        color: isFocused
                            ? AppColors.brandRedLight
                            : AppColors.textMuted,
                        size: 16,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 18),
        ],

        // Section 1: Recently Added Discovery Rail
        if (feedState.recentlyAdded.isNotEmpty) ...[
          GenreRailWidget(
            title: 'Recently Added',
            dotColor: AppColors.brandRed,
            movies: feedState.recentlyAdded,
            baseUrl: baseUrl,
            phoneLayout: !isTv,
            exploreLabel: isTv
                ? 'View All (${state.movies.length})'
                : 'See all',
            onExploreTap: () {
              if (isTv) {
                _navigateToTvLibrary(context);
                return;
              }
              final controller = ref.read(libraryControllerProvider.notifier);
              controller.resetFilters();
              controller.clearSearch();
              controller.setSortOption(SortOption.recentlyAdded);
              _navigateToHome(context);
            },
            onMovieTap: (m) => _onMovieSelected(context, m),
          ),
          const SizedBox(height: 22),
        ],

        // Sections 2..N: Endless Visible Genre Rails
        for (final section in feedState.visibleGenreSections) ...[
          GenreRailWidget(
            title: section.genre,
            dotColor: AppColors.statusInfo,
            movies: section.movies,
            baseUrl: baseUrl,
            phoneLayout: !isTv,
            exploreLabel: 'Explore',
            onExploreTap: () {
              if (isTv) {
                ref
                    .read(libraryControllerProvider.notifier)
                    .setSelectedGenre(section.genre);
                _navigateToTvLibrary(context);
              } else {
                _onGenreSelectedFromTree(section.genre);
              }
            },
            onMovieTap: (m) => _onMovieSelected(context, m),
          ),
          const SizedBox(height: 22),
        ],

        // Lazy-Loading Progress Indicator
        if (feedState.hasMoreRails) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.brandRed,
                ),
              ),
            ),
          ),
        ] else if (feedState.allGenreSections.isNotEmpty) ...[
          // End-of-Feed Discovery Footer
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Column(
                children: [
                  const Icon(
                    Icons.auto_awesome_rounded,
                    color: AppColors.brandRedLight,
                    size: 24,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    "You've Explored All Categories",
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 14.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isTv
                        ? 'Explore the complete catalog with custom filters and search.'
                        : 'Search the full collection by title, year, or genre.',
                    style: AppTypography.labelSmall.copyWith(
                      color: AppColors.textMuted,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.surfaceHighlight,
                      foregroundColor: AppColors.textPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: isTv
                        ? () => _navigateToTvLibrary(context)
                        : _focusSearch,
                    icon: Icon(
                      isTv ? Icons.explore_outlined : Icons.search_rounded,
                      size: 16,
                    ),
                    label: Text(
                      isTv
                          ? 'Open Library Catalog'
                          : 'Search the full collection',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],

        if (isTv) const SizedBox(height: 64),
      ],
    );
  }

  Widget _buildHomeCatalogResults(LibraryState state, String baseUrl) {
    final query = state.searchQuery.trim();
    final movies = state.filteredMovies;
    final title = query.isNotEmpty
        ? 'Search results'
        : state.selectedGenre ??
              (state.sortOption == SortOption.recentlyAdded
                  ? 'Recently Added'
                  : 'Your collection');
    final summary = query.isNotEmpty
        ? 'Results for "$query"'
        : 'Filtered titles';

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTypography.titleMedium.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$summary • ${movies.length} ${movies.length == 1 ? 'title' : 'titles'}',
                      style: AppTypography.labelSmall.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (state.searchQuery.isNotEmpty || state.hasActiveFilters)
                TextButton.icon(
                  onPressed: _clearHomeBrowse,
                  icon: const Icon(Icons.close_rounded, size: 17),
                  label: const Text('Clear'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: movies.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(24, 64, 24, 32),
                  children: [
                    const Icon(
                      Icons.search_off_rounded,
                      size: 46,
                      color: AppColors.textMuted,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      query.isEmpty
                          ? 'No titles match these filters'
                          : 'No titles match "$query"',
                      textAlign: TextAlign.center,
                      style: AppTypography.titleMedium.copyWith(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Try another title, year, or genre.',
                      textAlign: TextAlign.center,
                      style: AppTypography.bodyMedium.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Center(
                      child: TextButton.icon(
                        onPressed: _clearHomeBrowse,
                        icon: const Icon(Icons.home_rounded),
                        label: const Text('Return to Home Feed'),
                      ),
                    ),
                  ],
                )
              : MovieGrid(
                  movies: movies,
                  baseUrl: baseUrl,
                  onMovieTap: (movie) => _onMovieSelected(context, movie),
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                  phoneColumnCount: 3,
                  containArtwork: true,
                ),
        ),
      ],
    );
  }
}
