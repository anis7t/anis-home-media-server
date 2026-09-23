import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../features/connection/presentation/connection_screen.dart';

class AppRoutes {
  AppRoutes._();

  static const String connection = '/';

  static final GoRouter router = GoRouter(
    initialLocation: connection,
    routes: [
      GoRoute(
        path: connection,
        builder: (BuildContext context, GoRouterState state) {
          return const ConnectionScreen();
        },
      ),
    ],
  );
}
