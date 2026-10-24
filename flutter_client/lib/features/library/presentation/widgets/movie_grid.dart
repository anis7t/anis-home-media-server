import 'package:flutter/material.dart';
import '../../data/models/movie_item.dart';
import 'movie_card.dart';

/// Responsive grid displaying library movie cards with dynamic column calculation.
class MovieGrid extends StatelessWidget {
  final List<MovieItem> movies;
  final String baseUrl;
  final ValueChanged<MovieItem> onMovieTap;
  final ScrollPhysics? physics;
  final bool shrinkWrap;
  final EdgeInsetsGeometry padding;

  const MovieGrid({
    super.key,
    required this.movies,
    required this.baseUrl,
    required this.onMovieTap,
    this.physics,
    this.shrinkWrap = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        int crossAxisCount = 2;

        if (width >= 1280) {
          crossAxisCount = 6;
        } else if (width >= 960) {
          crossAxisCount = 5;
        } else if (width >= 680) {
          crossAxisCount = 4;
        } else if (width >= 460) {
          crossAxisCount = 3;
        } else {
          crossAxisCount = 2;
        }

        return GridView.builder(
          padding: padding,
          physics: physics,
          shrinkWrap: shrinkWrap,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: 0.58,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: movies.length,
          itemBuilder: (context, index) {
            final movie = movies[index];
            return MovieCard(
              movie: movie,
              baseUrl: baseUrl,
              showProgress: true,
              onTap: () => onMovieTap(movie),
            );
          },
        );
      },
    );
  }
}
