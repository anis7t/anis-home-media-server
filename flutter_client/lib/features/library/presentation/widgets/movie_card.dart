import 'package:flutter/material.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../data/models/movie_item.dart';

/// Reusable obsidian movie card displaying poster artwork, playback progress, and metadata.
class MovieCard extends StatelessWidget {
  final MovieItem movie;
  final String baseUrl;
  final VoidCallback? onTap;
  final bool showProgress;
  final double? width;
  final double? height;

  const MovieCard({
    super.key,
    required this.movie,
    required this.baseUrl,
    this.onTap,
    this.showProgress = true,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final posterUrl = movie.posterUrl(baseUrl);
    final hasProgress = showProgress && movie.percent > 0 && movie.percent <= 100;

    return Semantics(
      label: '${movie.title}${movie.year != null ? ', ${movie.year}' : ''}',
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          splashColor: AppColors.brandRedGlow,
          highlightColor: AppColors.borderSubtle,
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Poster Artwork Area with fixed 2:3 ratio
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (posterUrl != null && posterUrl.isNotEmpty)
                        Image.network(
                          posterUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              _buildArtworkFallback(),
                          loadingBuilder: (context, child, loadingProgress) {
                            if (loadingProgress == null) return child;
                            return _buildLoadingPlaceholder();
                          },
                        )
                      else
                        _buildArtworkFallback(),

                      // Subtle gradient overlay at bottom of poster for contrast
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 36,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.65),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // Rating Badge (Top Right)
                      if (movie.rating != null && movie.rating! > 0)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.75),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.15),
                                width: 0.75,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.star_rounded,
                                  size: 13,
                                  color: Color(0xFFFFB800),
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  movie.rating!.toStringAsFixed(1),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      // Playback Progress Bar (Bottom of poster)
                      if (hasProgress)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            height: 3.5,
                            color: Colors.black.withValues(alpha: 0.5),
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: (movie.percent / 100.0).clamp(0.0, 1.0),
                              child: Container(
                                color: AppColors.brandRed,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                // Metadata Footer (Title, Year, Runtime)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        movie.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                          letterSpacing: -0.2,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          if (movie.year != null) ...[
                            Text(
                              '${movie.year}',
                              style: AppTypography.labelSmall.copyWith(
                                color: AppColors.textSecondary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                          if (movie.year != null && movie.formattedRuntime.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: Text(
                                '•',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: AppColors.textMuted.withValues(alpha: 0.7),
                                ),
                              ),
                            ),
                          ],
                          if (movie.formattedRuntime.isNotEmpty) ...[
                            Flexible(
                              child: Text(
                                movie.formattedRuntime,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.labelSmall.copyWith(
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildArtworkFallback() {
    final initials = movie.title.isNotEmpty
        ? movie.title.trim().characters.first.toUpperCase()
        : '🎬';

    return Container(
      color: AppColors.surfaceElevated,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.surfaceHighlight,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Center(
                child: Text(
                  initials,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.brandRedLight,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Icon(
              Icons.movie_outlined,
              size: 16,
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingPlaceholder() {
    return Container(
      color: AppColors.surfaceElevated,
      child: const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.textMuted),
          ),
        ),
      ),
    );
  }
}
