import 'package:flutter/material.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../data/models/movie_item.dart';
import 'movie_card.dart';

/// Horizontal rail of in-progress media items with playback progress and one-tap resume.
class ContinueWatchingRail extends StatelessWidget {
  final List<MovieItem> movies;
  final String baseUrl;
  final ValueChanged<MovieItem> onMovieTap;

  const ContinueWatchingRail({
    super.key,
    required this.movies,
    required this.baseUrl,
    required this.onMovieTap,
  });

  @override
  Widget build(BuildContext context) {
    if (movies.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                'Continue Watching',
                style: AppTypography.titleLarge,
              ),
              const Spacer(),
              Text(
                '${movies.length}',
                style: AppTypography.labelSmall.copyWith(
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 232,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: movies.length,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final movie = movies[index];
              return SizedBox(
                width: 136,
                child: Stack(
                  children: [
                    MovieCard(
                      movie: movie,
                      baseUrl: baseUrl,
                      showProgress: true,
                      onTap: () => onMovieTap(movie),
                    ),
                    // Centered Play Action Overlay for one-tap resume
                    Positioned.fill(
                      bottom: 48, // keep off metadata footer
                      child: IgnorePointer(
                        child: Center(
                          child: Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.3),
                                width: 1.2,
                              ),
                            ),
                            child: const Icon(
                              Icons.play_arrow_rounded,
                              size: 24,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
