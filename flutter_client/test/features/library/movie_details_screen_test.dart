import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:media_server_client/app/routes.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/errors/app_exception.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/features/library/data/models/movie_details.dart';
import 'package:media_server_client/features/library/data/models/movie_extended_details.dart';
import 'package:media_server_client/features/library/data/models/movie_item.dart';
import 'package:media_server_client/features/library/data/models/movie_specs.dart';
import 'package:media_server_client/features/library/data/repositories/library_repository.dart';
import 'package:media_server_client/features/library/presentation/screens/movie_details_screen.dart';

class MockSecureStorage extends FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
  }) async => data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
  }) async {
    if (value != null) data[key] = value;
  }
}

class FakeDetailsLibraryRepository extends LibraryRepository {
  final Future<MovieDetails> Function(String filename)? onGetMovieDetails;

  FakeDetailsLibraryRepository({this.onGetMovieDetails})
    : super(
        ApiClient(
          baseUrl: 'http://127.0.0.1:8000',
          authInterceptor: DeviceAuthInterceptor(
            DeviceIdentityService(secureStorage: MockSecureStorage()),
          ),
        ),
      );

  @override
  Future<MovieDetails> getMovieDetails(String filename) async {
    if (onGetMovieDetails != null) {
      return onGetMovieDetails!(filename);
    }
    throw const NetworkException('Not implemented in mock');
  }
}

void main() {
  const sampleMovie = MovieItem(
    filename: 'Sample.Movie.2026.mp4',
    title: 'Sample Movie',
    year: 2026,
    runtime: 110,
    rating: 8.4,
    genres: 'Action, Sci-Fi',
    overview: 'A thrilling sci-fi adventure across the cosmos.',
    position: 0.0,
    duration: 6600.0,
  );

  const sampleSpecs = MovieSpecs(
    resolution: '1920x1080',
    resolutionBadge: '1080p',
    videoCodec: 'H.264',
    videoProfile: 'High',
    audioCodec: 'AAC',
    audioChannels: '6',
    container: 'mp4',
    fileSize: '2.4 GB',
    bitrate: '3,200 kbps',
    subtitles: ['English', 'Spanish'],
  );

  const sampleExtended = MovieExtendedDetails(
    tagline: 'The ultimate space odyssey begins.',
    certification: 'PG-13',
    cast: [
      CastMember(name: 'Jane Doe', character: 'Commander Nova'),
      CastMember(name: 'John Smith', character: 'Chief Pilot Ray'),
    ],
    directors: ['Christopher Director'],
    writers: ['Jane Writer'],
  );

  const sampleDetails = MovieDetails(
    movie: sampleMovie,
    specs: sampleSpecs,
    extended: sampleExtended,
    formattedRuntime: '1h 50m',
  );

  Widget createSubject({
    required LibraryRepository repo,
    MovieItem? initialMovie,
    String? filename,
    void Function(Map<String, dynamic>? extra)? onNavigatedToPlayer,
  }) {
    final router = GoRouter(
      initialLocation: '/details',
      routes: [
        GoRoute(
          path: '/details',
          builder: (context, state) => MovieDetailsScreen(
            initialMovie: initialMovie,
            filename: filename,
          ),
        ),
        GoRoute(
          path: AppRoutes.player,
          builder: (context, state) {
            onNavigatedToPlayer?.call(state.extra as Map<String, dynamic>?);
            return const Scaffold(body: Text('Player Screen'));
          },
        ),
      ],
    );

    return ProviderScope(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repo),
        serverBaseUrlProvider.overrideWithValue('http://127.0.0.1:8000'),
      ],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  testWidgets(
    'renders movie details with initialMovie immediately and loads specs/cast',
    (tester) async {
      final repo = FakeDetailsLibraryRepository(
        onGetMovieDetails: (fn) async => sampleDetails,
      );

      await tester.pumpWidget(
        createSubject(repo: repo, initialMovie: sampleMovie),
      );

      // Verify immediate render from initialMovie
      expect(find.text('Sample Movie'), findsOneWidget);
      expect(find.text('2026'), findsOneWidget);
      expect(find.text('1h 50m'), findsOneWidget);

      await tester.pumpAndSettle();

      // Verify extended details and technical specs
      expect(find.text('“The ultimate space odyssey begins.”'), findsOneWidget);
      expect(find.text('PG-13'), findsOneWidget);
      expect(find.text('1080p'), findsOneWidget);
      expect(find.text('8.4'), findsOneWidget);
      expect(find.text('Overview'), findsOneWidget);
      expect(
        find.text('A thrilling sci-fi adventure across the cosmos.'),
        findsOneWidget,
      );
      expect(find.text('Top Cast'), findsOneWidget);
      expect(find.text('Jane Doe'), findsOneWidget);
      expect(find.text('Commander Nova'), findsOneWidget);
      expect(find.text('Technical Specs'), findsOneWidget);
      expect(find.text('Resolution: '), findsOneWidget);
      expect(find.text('Video Codec: '), findsOneWidget);
      expect(find.text('Audio: '), findsOneWidget);

      // Floating header buttons
      expect(
        find.byKey(const ValueKey('movie_details_back_btn')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('movie_details_refresh_btn')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'renders Play Movie button for unwatched movie and handles tap with handshake',
    (tester) async {
      Map<String, dynamic>? playerArgs;
      final repo = FakeDetailsLibraryRepository(
        onGetMovieDetails: (fn) async => sampleDetails,
      );

      await tester.pumpWidget(
        createSubject(
          repo: repo,
          initialMovie: sampleMovie,
          onNavigatedToPlayer: (extra) => playerArgs = extra,
        ),
      );
      await tester.pumpAndSettle();

      final playBtnFinder = find.byKey(const ValueKey('primary_play_button'));
      expect(playBtnFinder, findsOneWidget);
      expect(find.text('Play Movie'), findsOneWidget);
      expect(find.byKey(const ValueKey('resume_play_button')), findsNothing);
      expect(
        find.byKey(const ValueKey('start_beginning_button')),
        findsNothing,
      );

      // Tap Play Movie button
      await tester.tap(playBtnFinder);
      await tester.pumpAndSettle();

      expect(find.text('Player Screen'), findsOneWidget);
      expect(playerArgs, isNotNull);
      expect(
        playerArgs!['mediaUrl'],
        'http://127.0.0.1:8000/media/Sample.Movie.2026.mp4',
      );
      expect(playerArgs!['title'], 'Sample Movie');
      expect(playerArgs!['startPosition'], Duration.zero);
    },
  );

  testWidgets(
    'renders Resume and From Start buttons for in-progress movie with progress bar and handshake',
    (tester) async {
      Map<String, dynamic>? playerArgs;
      const inProgressMovie = MovieItem(
        filename: 'Sample.Movie.2026.mp4',
        title: 'Sample Movie',
        year: 2026,
        runtime: 110,
        position: 1200.0, // 20 mins
        duration: 3600.0, // 60 mins
        percent: 33.3,
      );

      const inProgressDetails = MovieDetails(
        movie: inProgressMovie,
        specs: sampleSpecs,
        extended: sampleExtended,
        formattedRuntime: '1h 50m',
      );

      final repo = FakeDetailsLibraryRepository(
        onGetMovieDetails: (fn) async => inProgressDetails,
      );

      await tester.pumpWidget(
        createSubject(
          repo: repo,
          initialMovie: inProgressMovie,
          onNavigatedToPlayer: (extra) => playerArgs = extra,
        ),
      );
      await tester.pumpAndSettle();

      // Check progress metrics
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.textContaining('Watched 20:00 of 1:00:00'), findsOneWidget);
      expect(find.text('33%'), findsOneWidget);

      // Check Dual Play Action buttons
      final resumeBtnFinder = find.byKey(const ValueKey('resume_play_button'));
      final startBtnFinder = find.byKey(
        const ValueKey('start_beginning_button'),
      );

      expect(resumeBtnFinder, findsOneWidget);
      expect(find.text('Resume (20:00)'), findsOneWidget);
      expect(startBtnFinder, findsOneWidget);
      expect(find.text('From Start'), findsOneWidget);
      expect(find.byKey(const ValueKey('primary_play_button')), findsNothing);

      // Tap Resume
      await tester.tap(resumeBtnFinder);
      await tester.pumpAndSettle();

      expect(find.text('Player Screen'), findsOneWidget);
      expect(playerArgs, isNotNull);
      expect(playerArgs!['startPosition'], const Duration(seconds: 1200));
    },
  );

  testWidgets(
    'tapping From Start launches player with Duration.zero startPosition',
    (tester) async {
      Map<String, dynamic>? playerArgs;
      const inProgressMovie = MovieItem(
        filename: 'Sample.Movie.2026.mp4',
        title: 'Sample Movie',
        year: 2026,
        runtime: 110,
        position: 1200.0,
        duration: 3600.0,
        percent: 33.3,
      );

      const inProgressDetails = MovieDetails(
        movie: inProgressMovie,
        specs: sampleSpecs,
        extended: sampleExtended,
        formattedRuntime: '1h 50m',
      );

      final repo = FakeDetailsLibraryRepository(
        onGetMovieDetails: (fn) async => inProgressDetails,
      );

      await tester.pumpWidget(
        createSubject(
          repo: repo,
          initialMovie: inProgressMovie,
          onNavigatedToPlayer: (extra) => playerArgs = extra,
        ),
      );
      await tester.pumpAndSettle();

      final startBtnFinder = find.byKey(
        const ValueKey('start_beginning_button'),
      );
      await tester.tap(startBtnFinder);
      await tester.pumpAndSettle();

      expect(find.text('Player Screen'), findsOneWidget);
      expect(playerArgs, isNotNull);
      expect(playerArgs!['startPosition'], Duration.zero);
    },
  );

  testWidgets(
    'renders active multi-GPU transcoding banner when transcodeInfo is present',
    (tester) async {
      const transcodeDetails = MovieDetails(
        movie: sampleMovie,
        specs: sampleSpecs,
        extended: sampleExtended,
        formattedRuntime: '1h 50m',
        transcodeInfo: {'speed': '3.2x', 'fps': '75', 'status': 'active'},
      );

      final repo = FakeDetailsLibraryRepository(
        onGetMovieDetails: (fn) async => transcodeDetails,
      );

      await tester.pumpWidget(
        createSubject(repo: repo, initialMovie: sampleMovie),
      );
      await tester.pumpAndSettle();

      expect(find.text('Active Multi-GPU Transcoding'), findsOneWidget);
      expect(find.text('Encoding stream at 3.2x (75 fps)'), findsOneWidget);
    },
  );

  testWidgets(
    'handles error state gracefully with retry button when initialMovie is absent',
    (tester) async {
      var fetchCount = 0;
      final repo = FakeDetailsLibraryRepository(
        onGetMovieDetails: (fn) async {
          fetchCount++;
          if (fetchCount == 1) {
            throw const NetworkException('Failed to load movie details');
          }
          return sampleDetails;
        },
      );

      await tester.pumpWidget(
        createSubject(repo: repo, filename: 'Sample.Movie.2026.mp4'),
      );
      await tester.pumpAndSettle();

      // Error card shown
      expect(find.text('Failed to load movie details'), findsOneWidget);
      final retryBtnFinder = find.byKey(const ValueKey('retry_details_button'));
      expect(retryBtnFinder, findsOneWidget);

      // Tap Retry
      await tester.tap(retryBtnFinder);
      await tester.pumpAndSettle();

      // Movie details now loaded
      expect(find.text('Sample Movie'), findsOneWidget);
      expect(find.text('Overview'), findsOneWidget);
    },
  );
}
