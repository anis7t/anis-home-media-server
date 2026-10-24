import 'package:flutter/foundation.dart';
import '../../../library/data/models/movie_item.dart';

/// Represents a distinct genre section/rail on the endless home feed.
@immutable
class GenreSection {
  final String genre;
  final List<MovieItem> movies;
  final int totalCount;

  const GenreSection({
    required this.genre,
    required this.movies,
    required this.totalCount,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GenreSection &&
          runtimeType == other.runtimeType &&
          genre == other.genre &&
          totalCount == other.totalCount &&
          listEquals(movies, other.movies);

  @override
  int get hashCode => genre.hashCode ^ totalCount.hashCode ^ movies.length.hashCode;
}

/// Represents a decade/release era grouping for the hierarchical navigation tree.
@immutable
class DecadeSection {
  final String label;
  final int count;
  final int? minYear;
  final int? maxYear;

  const DecadeSection({
    required this.label,
    required this.count,
    this.minYear,
    this.maxYear,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DecadeSection &&
          runtimeType == other.runtimeType &&
          label == other.label &&
          count == other.count &&
          minYear == other.minYear &&
          maxYear == other.maxYear;

  @override
  int get hashCode =>
      label.hashCode ^ count.hashCode ^ minYear.hashCode ^ maxYear.hashCode;
}
