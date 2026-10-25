import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/widgets/tv_focusable.dart';
import '../../../library/domain/models/movie_item.dart';
import '../../../library/presentation/widgets/movie_card.dart';

/// Reusable horizontal discovery rail for genre categories and recently added collections.
class GenreRailWidget extends StatelessWidget {
  final String title;
  final List<MovieItem> movies;
  final String baseUrl;
  final ValueChanged<MovieItem> onMovieTap;
  final VoidCallback? onExploreTap;
  final String exploreLabel;
  final Color dotColor;

  const GenreRailWidget({
    super.key,
    required this.title,
    required this.movies,
    required this.baseUrl,
    required this.onMovieTap,
    this.onExploreTap,
    this.exploreLabel = 'Explore',
    this.dotColor = AppColors.brandRed,
  });

  @override
  Widget build(BuildContext context) {
    if (movies.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: dotColor.withValues(alpha: 0.45),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: AppTypography.titleLarge.copyWith(fontSize: 18),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: Text(
                  '${movies.length}',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              if (onExploreTap != null)
                TvFocusable(
                  borderRadius: BorderRadius.circular(8),
                  onPressed: onExploreTap,
                  builder: (context, isFocused, _) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isFocused
                            ? AppColors.brandRed.withValues(alpha: 0.22)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isFocused ? AppColors.brandRed : Colors.transparent,
                          width: isFocused ? 1.8 : 1.0,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            exploreLabel,
                            style: TextStyle(
                              color: isFocused
                                  ? AppColors.brandRedLight
                                  : AppColors.brandRedLight,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.arrow_forward_rounded,
                            color: AppColors.brandRedLight,
                            size: 13,
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        ),

        const SizedBox(height: 4),

        // Horizontal Rail
        SizedBox(
          height: 228,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: movies.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final movie = movies[index];
              return MovieCard(
                movie: movie,
                baseUrl: baseUrl,
                width: 128,
                height: 220,
                onTap: () => onMovieTap(movie),
              );
            },
          ),
        ),
      ],
    );
  }
}
