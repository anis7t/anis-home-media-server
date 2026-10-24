import 'package:flutter/foundation.dart';

/// Immutable model representing a single movie item in the library or continue-watching rail.
@immutable
class MovieItem {
  final String filename;
  final String title;
  final int? year;
  final int? tmdbId;
  final String overview;
  final double? rating;
  final int? runtime;
  final String genres;
  final String? releaseDate;
  final String? poster;
  final String? backdropPath;
  final double position;
  final double duration;
  final double percent;
  final String? updatedAt;

  const MovieItem({
    required this.filename,
    required this.title,
    this.year,
    this.tmdbId,
    this.overview = '',
    this.rating,
    this.runtime,
    this.genres = '',
    this.releaseDate,
    this.poster,
    this.backdropPath,
    this.position = 0.0,
    this.duration = 0.0,
    this.percent = 0.0,
    this.updatedAt,
  });

  /// Resolves the absolute HTTP URL for poster artwork.
  String? posterUrl(String baseUrl) {
    if (poster == null || poster!.isEmpty) return null;
    final cleanBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    if (poster!.startsWith('tmdb:')) {
      final id = poster!.substring(5);
      return '$cleanBase/tmdb-poster/$id';
    } else if (poster!.startsWith('local:')) {
      final path = poster!.substring(6);
      return '$cleanBase/poster/${Uri.encodeComponent(path)}';
    }
    return '$cleanBase/poster/${Uri.encodeComponent(poster!)}';
  }

  /// Resolves the absolute HTTP URL for backdrop artwork.
  String? backdropUrl(String baseUrl) {
    if (tmdbId == null) return null;
    final cleanBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return '$cleanBase/tmdb-backdrop/$tmdbId';
  }

  /// Formatted runtime display (e.g. "1h 54m" or "45m").
  String get formattedRuntime {
    if (runtime == null || runtime! <= 0) return '';
    final hours = runtime! ~/ 60;
    final minutes = runtime! % 60;
    if (hours > 0 && minutes > 0) {
      return '${hours}h ${minutes}m';
    } else if (hours > 0) {
      return '${hours}h';
    } else {
      return '${minutes}m';
    }
  }

  /// True if the user has started watching this movie (> 10 seconds).
  bool get hasProgress => position > 10;

  /// Progress fraction clamped between 0.0 and 1.0.
  double get progressFraction {
    if (percent > 0) return (percent / 100.0).clamp(0.0, 1.0);
    if (duration > 0) return (position / duration).clamp(0.0, 1.0);
    return 0.0;
  }

  factory MovieItem.fromJson(Map<String, dynamic> json) {
    int? parseYear(dynamic val) {
      if (val is int) return val;
      if (val is String && val.isNotEmpty) {
        return int.tryParse(val);
      }
      return null;
    }

    double? parseDouble(dynamic val) {
      if (val is num) return val.toDouble();
      if (val is String && val.isNotEmpty) {
        return double.tryParse(val);
      }
      return null;
    }

    int? parseInt(dynamic val) {
      if (val is int) return val;
      if (val is num) return val.toInt();
      if (val is String && val.isNotEmpty) {
        return int.tryParse(val);
      }
      return null;
    }

    return MovieItem(
      filename: json['filename']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      year: parseYear(json['year']),
      tmdbId: parseInt(json['tmdb_id']),
      overview: json['overview']?.toString() ?? '',
      rating: parseDouble(json['rating']),
      runtime: parseInt(json['runtime']),
      genres: json['genres']?.toString() ?? '',
      releaseDate: json['release_date']?.toString(),
      poster: json['poster']?.toString(),
      backdropPath: json['backdrop_path']?.toString(),
      position: parseDouble(json['position']) ?? 0.0,
      duration: parseDouble(json['duration']) ?? 0.0,
      percent: parseDouble(json['percent']) ?? 0.0,
      updatedAt: json['updated_at']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'filename': filename,
      'title': title,
      'year': year,
      'tmdb_id': tmdbId,
      'overview': overview,
      'rating': rating,
      'runtime': runtime,
      'genres': genres,
      'release_date': releaseDate,
      'poster': poster,
      'backdrop_path': backdropPath,
      'position': position,
      'duration': duration,
      'percent': percent,
      'updated_at': updatedAt,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MovieItem &&
          runtimeType == other.runtimeType &&
          filename == other.filename &&
          title == other.title &&
          year == other.year &&
          position == other.position &&
          duration == other.duration;

  @override
  int get hashCode =>
      filename.hashCode ^
      title.hashCode ^
      year.hashCode ^
      position.hashCode ^
      duration.hashCode;
}
