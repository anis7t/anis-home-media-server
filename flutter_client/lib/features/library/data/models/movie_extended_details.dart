import 'package:flutter/foundation.dart';

/// Immutable model representing a single cast member from TMDb credits.
@immutable
class CastMember {
  final String name;
  final String? character;
  final String? profilePath;

  const CastMember({
    required this.name,
    this.character,
    this.profilePath,
  });

  /// Full TMDb profile image URL (w185 thumbnail size).
  String? get profileUrl => (profilePath != null && profilePath!.isNotEmpty)
      ? 'https://image.tmdb.org/t/p/w185$profilePath'
      : null;

  factory CastMember.fromJson(Map<String, dynamic> json) {
    return CastMember(
      name: json['name']?.toString() ?? '',
      character: json['character']?.toString(),
      profilePath: json['profile_path']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'character': character,
      'profile_path': profilePath,
    };
  }
}

/// Immutable model representing extended TMDb metadata.
@immutable
class MovieExtendedDetails {
  final String tagline;
  final String? imdbId;
  final String? certification;
  final List<CastMember> cast;
  final List<String> directors;
  final List<String> writers;
  final List<String> production;
  final String? trailerKey;

  const MovieExtendedDetails({
    this.tagline = '',
    this.imdbId,
    this.certification,
    this.cast = const [],
    this.directors = const [],
    this.writers = const [],
    this.production = const [],
    this.trailerKey,
  });

  factory MovieExtendedDetails.fromJson(Map<String, dynamic> json) {
    List<CastMember> parseCast(dynamic val) {
      if (val is List) {
        return val
            .whereType<Map<String, dynamic>>()
            .map((e) => CastMember.fromJson(e))
            .where((c) => c.name.isNotEmpty)
            .toList();
      }
      return const [];
    }

    List<String> parseStrings(dynamic val) {
      if (val is List) {
        return val
            .map((e) => e?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
      }
      return const [];
    }

    return MovieExtendedDetails(
      tagline: json['tagline']?.toString() ?? '',
      imdbId: json['imdb_id']?.toString(),
      certification: json['certification']?.toString(),
      cast: parseCast(json['cast']),
      directors: parseStrings(json['directors']),
      writers: parseStrings(json['writers']),
      production: parseStrings(json['production']),
      trailerKey: json['trailer_key']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'tagline': tagline,
      'imdb_id': imdbId,
      'certification': certification,
      'cast': cast.map((c) => c.toJson()).toList(),
      'directors': directors,
      'writers': writers,
      'production': production,
      'trailer_key': trailerKey,
    };
  }
}
