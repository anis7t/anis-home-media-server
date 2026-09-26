import 'package:flutter/foundation.dart';
import 'movie_extended_details.dart';
import 'movie_item.dart';
import 'movie_specs.dart';

/// Immutable aggregate model representing the full movie details sheet/screen payload.
@immutable
class MovieDetails {
  final MovieItem movie;
  final MovieSpecs specs;
  final MovieExtendedDetails extended;
  final String formattedRuntime;
  final int? backdropTmdbId;
  final Map<String, dynamic>? transcodeInfo;

  const MovieDetails({
    required this.movie,
    required this.specs,
    required this.extended,
    this.formattedRuntime = '',
    this.backdropTmdbId,
    this.transcodeInfo,
  });

  /// Resolves the absolute HTTP URL for backdrop artwork.
  String? backdropUrl(String baseUrl) {
    final id = backdropTmdbId ?? movie.tmdbId;
    if (id == null) return null;
    final cleanBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return '$cleanBase/tmdb-backdrop/$id';
  }

  factory MovieDetails.fromJson(Map<String, dynamic> json) {
    final movieRaw = json['movie'] is Map<String, dynamic>
        ? json['movie'] as Map<String, dynamic>
        : <String, dynamic>{};
    final specsRaw = json['specs'] is Map<String, dynamic>
        ? json['specs'] as Map<String, dynamic>
        : <String, dynamic>{};
    final extendedRaw = json['extended'] is Map<String, dynamic>
        ? json['extended'] as Map<String, dynamic>
        : <String, dynamic>{};

    int? parseBackdropId(dynamic val) {
      if (val is int) return val;
      if (val is num) return val.toInt();
      if (val is String && val.isNotEmpty) return int.tryParse(val);
      return null;
    }

    return MovieDetails(
      movie: MovieItem.fromJson(movieRaw),
      specs: MovieSpecs.fromJson(specsRaw),
      extended: MovieExtendedDetails.fromJson(extendedRaw),
      formattedRuntime: json['formatted_runtime']?.toString() ?? '',
      backdropTmdbId: parseBackdropId(json['backdrop_tmdb_id']),
      transcodeInfo: json['transcode_info'] is Map<String, dynamic>
          ? json['transcode_info'] as Map<String, dynamic>
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'movie': movie.toJson(),
      'specs': specs.toJson(),
      'extended': extended.toJson(),
      'formatted_runtime': formattedRuntime,
      'backdrop_tmdb_id': backdropTmdbId,
      'transcode_info': transcodeInfo,
    };
  }
}
