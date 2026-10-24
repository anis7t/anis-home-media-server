import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/api/api_client.dart';
import '../../../../core/device/infrastructure/device_capability_service.dart';
import '../../../../core/widgets/tv_focusable.dart';
import '../../../library/data/models/movie_item.dart';
import '../../../library/presentation/controllers/library_controller.dart';
import '../../../library/presentation/widgets/continue_watching_rail.dart';
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

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
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

  void _navigateToLibrary(BuildContext context) {
    try {
      StatefulNavigationShell.of(context).goBranch(1);
    } catch (_) {
      context.go(AppRoutes.library);
    }
  }

  void _onGenreSelectedFromTree(String genre) {
    ref.read(libraryControllerProvider.notifier).setSelectedGenre(genre);
    _navigateToLibrary(context);
  }

  void _onDecadeSelectedFromTree(String decade) {
    final query = decade.replaceAll(RegExp(r'[^0-9]'), '');
    final prefix = query.length >= 3 ? query.substring(0, 3) : query;
    ref.read(libraryControllerProvider.notifier).setSearchQuery(prefix);
    _navigateToLibrary(context);
  }

  Future<void> _handleScan(BuildContext context, WidgetRef ref) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    scaffoldMessenger.showSnackBar(
      const SnackBar(
        content: Text('Triggering server library scan...'),
        duration: Duration(seconds: 2),
      ),
    );

    final success =
        await ref.read(libraryControllerProvider.notifier).triggerScan();

    if (context.mounted) {
      scaffoldMessenger.hideCurrentSnackBar();
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Library scan started successfully'
                : 'Could not start scan (check connection or admin access)',
          ),
          backgroundColor:
              success ? AppColors.statusSuccess : AppColors.statusError,
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
            Expanded(
              child: RefreshIndicator(
                color: AppColors.brandRed,
                backgroundColor: AppColors.surfaceElevated,
                onRefresh: () => ref
                    .read(libraryControllerProvider.notifier)
                    .loadLibrary(isRefresh: true),
                child: _buildBody(context, libraryState, feedState, baseUrl, isTv),
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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
              onPressed: state.isScanning ? null : () => _handleScan(context, ref),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: Row(
        children: [
          // Frosted Tree Drawer Button
          TvFocusable(
            borderRadius: BorderRadius.circular(10),
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            builder: (context, isFocused, _) {
              return Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: isFocused
                      ? AppColors.surfaceHighlight
                      : AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isFocused ? AppColors.brandRed : AppColors.borderMedium,
                    width: isFocused ? 1.8 : 1.0,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: AppColors.brandRedGlow,
                      blurRadius: 16,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Center(
                  child: Icon(
                    Icons.account_tree_rounded,
                    color: isFocused
                        ? AppColors.brandRedLight
                        : AppColors.brandRedLight,
                    size: 20,
                  ),
                ),
              );
            },
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
            onPressed:
                state.isScanning ? null : () => _handleScan(context, ref),
          ),
        ],
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
        child: CircularProgressIndicator(
          color: AppColors.brandRed,
        ),
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
            onMovieTap: (m) => _onMovieSelected(context, m),
          ),
        ],

        const SizedBox(height: 14),

        // Quick Browse Banner / Tree Action Shortcut
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TvFocusable(
            borderRadius: BorderRadius.circular(14),
            onPressed: () => _navigateToLibrary(context),
            builder: (context, isFocused, _) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: isFocused
                      ? AppColors.surfaceHighlight
                      : AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isFocused ? AppColors.brandRed : AppColors.borderSubtle,
                    width: isFocused ? 2.5 : 1.0,
                  ),
                  boxShadow: isFocused
                      ? [
                          BoxShadow(
                            color: AppColors.brandRedGlow.withValues(alpha: 0.65),
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

        // Section 1: Recently Added Discovery Rail
        if (feedState.recentlyAdded.isNotEmpty) ...[
          GenreRailWidget(
            title: 'Recently Added',
            dotColor: AppColors.brandRed,
            movies: feedState.recentlyAdded,
            baseUrl: baseUrl,
            exploreLabel: 'View All (${state.movies.length})',
            onExploreTap: () => _navigateToLibrary(context),
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
            exploreLabel: 'Explore',
            onExploreTap: () {
              ref
                  .read(libraryControllerProvider.notifier)
                  .setSelectedGenre(section.genre);
              _navigateToLibrary(context);
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
                    'Explore the complete catalog with custom filters and search.',
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
                    onPressed: () => _navigateToLibrary(context),
                    icon: const Icon(Icons.explore_outlined, size: 16),
                    label: const Text('Open Library Catalog'),
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
}
