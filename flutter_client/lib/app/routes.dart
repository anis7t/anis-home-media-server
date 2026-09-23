import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../features/connection/presentation/connection_screen.dart';
import '../features/player_poc/presentation/player_poc_screen.dart';

class AppRoutes {
  AppRoutes._();

  static const String connection = '/';
  static const String playerPoc = '/player-poc';

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
      ],
    );
  }

  static final GoRouter router = createRouter();
}
