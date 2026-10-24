import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/library/data/models/library_response.dart';
import 'package:media_server_client/features/library/data/models/movie_details.dart';
import 'package:media_server_client/features/library/data/models/movie_extended_details.dart';
import 'package:media_server_client/features/library/data/models/movie_item.dart';
import 'package:media_server_client/features/library/data/models/movie_specs.dart';

void main() {
  group('MovieItem Model', () {
    test('parses complete JSON correctly', () {
      final json = {
        'filename': 'Spider-Man.mkv',
        'title': 'Spider-Man: Brand New Day',
        'year': 2026,
        'tmdb_id': 999,
        'overview': 'Peter Parker returns.',
        'rating': 8.5,
        'runtime': 140,
        'genres': 'Action, Adventure',
        'release_date': '2026-07-10',
        'poster': 'tmdb:999',
        'backdrop_path': '/spider_backdrop.jpg',
        'position': 300.0,
        'duration': 8400.0,
        'percent': 3.57,
        'updated_at': '2026-09-24 12:00:00',
      };

      final movie = MovieItem.fromJson(json);

      expect(movie.filename, 'Spider-Man.mkv');
      expect(movie.title, 'Spider-Man: Brand New Day');
      expect(movie.year, 2026);
      expect(movie.tmdbId, 999);
      expect(movie.overview, 'Peter Parker returns.');
      expect(movie.rating, 8.5);
      expect(movie.runtime, 140);
      expect(movie.genres, 'Action, Adventure');
      expect(movie.releaseDate, '2026-07-10');
      expect(movie.poster, 'tmdb:999');
      expect(movie.backdropPath, '/spider_backdrop.jpg');
      expect(movie.position, 300.0);
      expect(movie.duration, 8400.0);
      expect(movie.percent, 3.57);
      expect(movie.updatedAt, '2026-09-24 12:00:00');
    });

    test('handles null and string-number fields gracefully', () {
      final json = {
        'filename': 'Test.mp4',
        'title': 'Test Movie',
        'year': '2025',
        'tmdb_id': '123',
        'rating': '7.2',
        'runtime': '95',
        'position': '10.5',
        'duration': '100.0',
        'percent': '10.5',
      };

      final movie = MovieItem.fromJson(json);

      expect(movie.year, 2025);
      expect(movie.tmdbId, 123);
      expect(movie.rating, 7.2);
      expect(movie.runtime, 95);
      expect(movie.position, 10.5);
      expect(movie.duration, 100.0);
      expect(movie.percent, 10.5);
    });

    test('posterUrl and backdropUrl resolve correctly', () {
      const baseUrl = 'http://192.168.1.16:8000';

      const tmdbMovie = MovieItem(
        filename: 'm1.mkv',
        title: 'M1',
        tmdbId: 456,
        poster: 'tmdb:456',
      );
      expect(tmdbMovie.posterUrl(baseUrl), 'http://192.168.1.16:8000/tmdb-poster/456');
      expect(tmdbMovie.backdropUrl(baseUrl), 'http://192.168.1.16:8000/tmdb-backdrop/456');

      const localMovie = MovieItem(
        filename: 'm2.mp4',
        title: 'M2',
        poster: 'local:Subfolder/Poster.jpg',
      );
      expect(localMovie.posterUrl(baseUrl), 'http://192.168.1.16:8000/poster/Subfolder%2FPoster.jpg');

      const noPosterMovie = MovieItem(
        filename: 'm3.mp4',
        title: 'M3',
      );
      expect(noPosterMovie.posterUrl(baseUrl), isNull);
      expect(noPosterMovie.backdropUrl(baseUrl), isNull);
    });
  });

  group('MovieSpecs Model', () {
    test('parses specs and subtitles list', () {
      final json = {
        'resolution': '1080p',
        'resolution_badge': '1080p',
        'video_codec': 'H.264 (AVC)',
        'video_profile': 'High',
        'audio_codec': 'AAC',
        'audio_channels': '5.1 Surround',
        'container': 'MKV',
        'file_size': '2.1 GB',
        'bitrate': '3.2 Mbps',
        'subtitles': ['English [SDH]', 'Spanish'],
        'aspect_ratio': '16:9',
      };

      final specs = MovieSpecs.fromJson(json);

      expect(specs.resolution, '1080p');
      expect(specs.resolutionBadge, '1080p');
      expect(specs.videoCodec, 'H.264 (AVC)');
      expect(specs.audioCodec, 'AAC');
      expect(specs.audioChannels, '5.1 Surround');
      expect(specs.container, 'MKV');
      expect(specs.fileSize, '2.1 GB');
      expect(specs.bitrate, '3.2 Mbps');
      expect(specs.subtitles, ['English [SDH]', 'Spanish']);
      expect(specs.aspectRatio, '16:9');
    });

    test('defaults safely when fields are null', () {
      final specs = MovieSpecs.fromJson({});
      expect(specs.resolution, '');
      expect(specs.subtitles, isEmpty);
      expect(specs.container, '');
    });
  });

  group('MovieExtendedDetails & CastMember', () {
    test('parses cast and crew correctly', () {
      final json = {
        'tagline': 'Never let go.',
        'imdb_id': 'tt0120338',
        'certification': 'PG-13',
        'cast': [
          {'name': 'Leonardo DiCaprio', 'character': 'Jack Dawson', 'profile_path': '/leo.jpg'},
          {'name': 'Kate Winslet', 'character': 'Rose DeWitt', 'profile_path': null},
        ],
        'directors': ['James Cameron'],
        'writers': ['James Cameron'],
        'production': ['Paramount', '20th Century Fox'],
        'trailer_key': 'kFz9Z7q3',
      };

      final ext = MovieExtendedDetails.fromJson(json);

      expect(ext.tagline, 'Never let go.');
      expect(ext.imdbId, 'tt0120338');
      expect(ext.certification, 'PG-13');
      expect(ext.cast.length, 2);
      expect(ext.cast.first.name, 'Leonardo DiCaprio');
      expect(ext.cast.first.profileUrl, 'https://image.tmdb.org/t/p/w185/leo.jpg');
      expect(ext.cast[1].profileUrl, isNull);
      expect(ext.directors, ['James Cameron']);
      expect(ext.trailerKey, 'kFz9Z7q3');
    });
  });

  group('MovieDetails Aggregate Model', () {
    test('parses full details and provides backdropUrl', () {
      final json = {
        'movie': {
          'filename': 'Movie.mp4',
          'title': 'Movie',
          'year': 2026,
          'tmdb_id': 555,
        },
        'specs': {
          'resolution': '4K 2160p',
          'resolution_badge': '4K',
        },
        'extended': {
          'tagline': 'An epic journey.',
          'cast': [],
        },
        'formatted_runtime': '2h 15m',
        'backdrop_tmdb_id': 555,
        'transcode_info': null,
      };

      final details = MovieDetails.fromJson(json);

      expect(details.movie.title, 'Movie');
      expect(details.specs.resolution, '4K 2160p');
      expect(details.specs.resolutionBadge, '4K');
      expect(details.extended.tagline, 'An epic journey.');
      expect(details.formattedRuntime, '2h 15m');
      expect(details.backdropTmdbId, 555);
      expect(details.backdropUrl('http://127.0.0.1:8000'), 'http://127.0.0.1:8000/tmdb-backdrop/555');
    });
  });

  group('LibraryResponse Model', () {
    test('parses movies and watching lists correctly', () {
      final json = {
        'movies': [
          {'filename': 'm1.mp4', 'title': 'Movie 1', 'position': 0.0},
          {'filename': 'm2.mp4', 'title': 'Movie 2', 'position': 50.0},
        ],
        'watching': [
          {'filename': 'm2.mp4', 'title': 'Movie 2', 'position': 50.0},
        ],
        'total': 2,
      };

      final response = LibraryResponse.fromJson(json);

      expect(response.total, 2);
      expect(response.movies.length, 2);
      expect(response.watching.length, 1);
      expect(response.watching.first.filename, 'm2.mp4');
    });
  });
}
