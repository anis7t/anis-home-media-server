import 'package:flutter/foundation.dart';
import 'movie_item.dart';

/// Immutable model representing the response from GET /api/movies.
@immutable
class LibraryResponse {
  final List<MovieItem> movies;
  final List<MovieItem> watching;
  final int total;

  const LibraryResponse({
    this.movies = const [],
    this.watching = const [],
    this.total = 0,
  });

  factory LibraryResponse.fromJson(Map<String, dynamic> json) {
    List<MovieItem> parseList(dynamic val) {
      if (val is List) {
        return val
            .whereType<Map<String, dynamic>>()
            .map((e) => MovieItem.fromJson(e))
            .toList();
      }
      return const [];
    }

    final movies = parseList(json['movies']);
    final watching = parseList(json['watching']);
    final total = json['total'] is int ? json['total'] as int : movies.length;

    return LibraryResponse(
      movies: movies,
      watching: watching,
      total: total,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'movies': movies.map((m) => m.toJson()).toList(),
      'watching': watching.map((w) => w.toJson()).toList(),
      'total': total,
    };
  }
}
