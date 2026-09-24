import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../features/connection/presentation/connection_screen.dart';
import '../features/player/presentation/player_screen.dart';
import '../features/player_poc/presentation/player_poc_screen.dart';

class AppRoutes {
  AppRoutes._();

  static const String connection = '/';
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
          path: playerPoc,
          builder: (BuildContext context, GoRouterState state) {
            return const PlayerPocScreen();
          },
        ),
        GoRoute(
          path: player,
          builder: (BuildContext context, GoRouterState state) {
            final extra = state.extra as Map<String, dynamic>?;
            final providedUrl = extra?['mediaUrl'] as String?;
            const defaultUrl =
                'http://127.0.0.1:8000/media/Batman%20Knightfall%20Part%201%202026%201080p%20WEBRip%20x264%20AAC5%201-%5BYTS%20GG%20-%20YTS%20BZ%5D.mp4';
            return PlayerScreen(
              mediaUrl: (providedUrl != null && providedUrl.isNotEmpty)
                  ? providedUrl
                  : defaultUrl,
              title: extra?['title'] as String? ?? 'Batman Knightfall Part 1 (2026)',
              subtitle: extra?['subtitle'] as String? ?? 'Direct MP4 • 1080p • AAC 5.1',
              startPosition: extra?['startPosition'] as Duration?,
              externalSubtitleUrl: extra?['externalSubtitleUrl'] as String?,
            );
          },
        ),
      ],
    );
  }

  static final GoRouter router = createRouter();
}
