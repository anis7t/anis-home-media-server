import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../features/connection/presentation/connection_screen.dart';
import '../features/library/data/models/movie_item.dart';
import '../features/library/presentation/screens/library_screen.dart';
import '../features/library/presentation/screens/movie_details_screen.dart';
import '../features/player/presentation/player_screen.dart';
import '../features/player_poc/presentation/player_poc_screen.dart';

class AppRoutes {
  AppRoutes._();

  static const String connection = '/';
  static const String library = '/library';
  static const String movieDetails = '/movie-details';
  static const String playerPoc = '/player-poc';
  static const String player = '/player';

  static GoRouter createRouter({String initialLocation = connection}) {
    return GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: connection,
          builder: (BuildContext context, GoRouterState state) {
            return const ConnectionScreen();
          },
        ),
        GoRoute(
          path: library,
          builder: (BuildContext context, GoRouterState state) {
            return const LibraryScreen();
          },
        ),
        GoRoute(
          path: movieDetails,
          builder: (BuildContext context, GoRouterState state) {
            final movie = state.extra is MovieItem ? state.extra as MovieItem : null;
            final filename = state.uri.queryParameters['filename'];
            return MovieDetailsScreen(
              initialMovie: movie,
              filename: filename,
            );
          },
        ),
        GoRoute(
          path: playerPoc,
          builder: (BuildContext context, GoRouterState state) {
            return const PlayerPocScreen();
          },
        ),
        GoRoute(
          path: player,
          builder: (BuildContext context, GoRouterState state) {
            final extra = state.extra as Map<String, dynamic>?;
            final query = state.uri.queryParameters;
            final providedUrl =
                (extra?['mediaUrl'] as String?) ?? query['mediaUrl'];
            final serverParam =
                (extra?['server'] as String?) ?? query['server'];

            const filename =
                'Batman%20Knightfall%20Part%201%202026%201080p%20WEBRip%20x264%20AAC5%201-%5BYTS%20GG%20-%20YTS%20BZ%5D.mp4';
            final defaultUrl = (serverParam != null && serverParam.isNotEmpty)
                ? '${serverParam.endsWith('/') ? serverParam.substring(0, serverParam.length - 1) : serverParam}/media/$filename'
                : 'http://127.0.0.1:8000/media/$filename';

            return PlayerScreen(
              mediaUrl: (providedUrl != null && providedUrl.isNotEmpty)
                  ? providedUrl
                  : defaultUrl,
              title: extra?['title'] as String? ??
                  query['title'] ??
                  'Batman Knightfall Part 1 (2026)',
              subtitle: extra?['subtitle'] as String? ??
                  query['subtitle'] ??
                  'Direct MP4 • 1080p • AAC 5.1',
              startPosition: extra?['startPosition'] as Duration?,
              externalSubtitleUrl: extra?['externalSubtitleUrl'] as String? ??
                  query['externalSubtitleUrl'],
            );
          },
        ),
      ],
    );
  }

  static final GoRouter router = createRouter();
}
