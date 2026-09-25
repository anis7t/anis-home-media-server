import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'app/app.dart';
import 'app/routes.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final hasRouteArg = args.any((a) => a.startsWith('--route='));
  final routeArg = hasRouteArg
      ? args.firstWhere((a) => a.startsWith('--route=')).substring(8)
      : null;

  final startAtPoc = args.contains('--player-poc') ||
      args.contains('--poc') ||
      routeArg == '/player-poc' ||
      routeArg == 'player-poc' ||
      routeArg == 'poc';
  final startAtPlayer = args.contains('--player') ||
      routeArg == '/player' ||
      routeArg == 'player';

  final hasServerArg = args.any((a) => a.startsWith('--server='));
  final serverArg = hasServerArg
      ? args.firstWhere((a) => a.startsWith('--server=')).substring(9)
      : null;

  final hasMediaUrlArg = args.any((a) => a.startsWith('--media-url='));
  final mediaUrlArg = hasMediaUrlArg
      ? args.firstWhere((a) => a.startsWith('--media-url=')).substring(12)
      : null;

  String? initialRoute;
  if (startAtPoc) {
    initialRoute = AppRoutes.playerPoc;
  } else if (startAtPlayer) {
    initialRoute = AppRoutes.player;
  } else if (routeArg != null && routeArg.isNotEmpty) {
    initialRoute = routeArg.startsWith('/') ? routeArg : '/$routeArg';
  }

  if (initialRoute != null && (serverArg != null || mediaUrlArg != null)) {
    final uri = Uri.parse(initialRoute);
    final params = Map<String, String>.from(uri.queryParameters);
    if (serverArg != null && serverArg.isNotEmpty) {
      params['server'] = serverArg;
    }
    if (mediaUrlArg != null && mediaUrlArg.isNotEmpty) {
      params['mediaUrl'] = mediaUrlArg;
    }
    initialRoute = uri.replace(queryParameters: params).toString();
  }

  runApp(
    ProviderScope(
      child: MediaServerApp(
        initialRoute: initialRoute,
      ),
    ),
  );
}
