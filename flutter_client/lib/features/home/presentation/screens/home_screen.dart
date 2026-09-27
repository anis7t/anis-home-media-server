import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/api/api_client.dart';
import '../../../library/data/models/movie_item.dart';
import '../../../library/presentation/controllers/library_controller.dart';
import '../../../library/presentation/widgets/continue_watching_rail.dart';
import '../../../library/presentation/widgets/movie_card.dart';

/// Primary landing and dashboard screen in the persistent bottom navigation shell.
/// Highlights in-progress Continue Watching media, recently added library titles,
/// and direct access to full library catalog and scan capabilities.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  void _onMovieSelected(BuildContext context, MovieItem movie) {
    context.push(AppRoutes.movieDetails, extra: movie);
  }

  void _navigateToLibrary(BuildContext context) {
    // Navigate to the Library tab branch in the shell
    try {
      StatefulNavigationShell.of(context).goBranch(1);
    } catch (_) {
      context.go(AppRoutes.library);
    }
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
                ? 'Library scan completed successfully'
                : 'Failed to trigger library scan',
          ),
          backgroundColor:
              success ? AppColors.statusSuccess : AppColors.statusError,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(libraryControllerProvider);
    final baseUrl = ref.watch(serverBaseUrlProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildFrostedHeader(context, ref, state),
            Expanded(
              child: RefreshIndicator(
                color: AppColors.brandRed,
                backgroundColor: AppColors.surfaceElevated,
                onRefresh: () => ref
                    .read(libraryControllerProvider.notifier)
                    .loadLibrary(isRefresh: true),
                child: _buildBody(context, ref, state, baseUrl),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFrostedHeader(
    BuildContext context,
    WidgetRef ref,
    LibraryState state,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: Row(
        children: [
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
    WidgetRef ref,
    LibraryState state,
    String baseUrl,
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
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        // Continue Watching rail if present
        if (state.continueWatching.isNotEmpty) ...[
          const SizedBox(height: 10),
          ContinueWatchingRail(
            movies: state.continueWatching,
            baseUrl: baseUrl,
            onMovieTap: (m) => _onMovieSelected(context, m),
          ),
        ],

        const SizedBox(height: 16),

        // Quick Library Banner / Shortcut
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: InkWell(
            onTap: () => _navigateToLibrary(context),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.borderMedium),
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
                          '${state.movies.length} movies available with instant search & filters',
                          style: AppTypography.labelSmall.copyWith(
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.arrow_forward_ios_rounded,
                    color: AppColors.textMuted,
                    size: 16,
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 20),

        // Recently Added / Library Section Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  color: AppColors.brandRed,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.brandRedGlow,
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Recently Added',
                style: AppTypography.titleLarge,
              ),
              const Spacer(),
              TextButton(
                onPressed: () => _navigateToLibrary(context),
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'View All (${state.movies.length})',
                      style: const TextStyle(
                        color: AppColors.brandRedLight,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.arrow_forward_rounded,
                      color: AppColors.brandRedLight,
                      size: 14,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // Responsive Recent Movies Grid (displaying up to 8 movies)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final crossAxisCount = constraints.maxWidth < 420
                  ? 2
                  : constraints.maxWidth < 700
                      ? 3
                      : 4;
              final recentMovies = state.movies.take(8).toList();

              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 14,
                  childAspectRatio: 0.62,
                ),
                itemCount: recentMovies.length,
                itemBuilder: (context, index) {
                  final movie = recentMovies[index];
                  return MovieCard(
                    movie: movie,
                    baseUrl: baseUrl,
                    onTap: () => _onMovieSelected(context, movie),
                  );
                },
              );
            },
          ),
        ),

        const SizedBox(height: 18),

        // Bottom explore CTA
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                side: const BorderSide(color: AppColors.borderMedium),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
              onPressed: () => _navigateToLibrary(context),
              icon: const Icon(Icons.explore_outlined, size: 18),
              label: Text(
                'Explore All ${state.movies.length} Movies in Catalog',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
