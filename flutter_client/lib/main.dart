import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'app/app.dart';
import 'app/routes.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final startAtPoc = args.contains('--player-poc') || args.contains('--poc');
  final startAtPlayer = args.contains('--player');

  String? initialRoute;
  if (startAtPoc) {
    initialRoute = AppRoutes.playerPoc;
  } else if (startAtPlayer) {
    initialRoute = AppRoutes.player;
  }

  runApp(
    ProviderScope(
      child: MediaServerApp(
        initialRoute: initialRoute,
      ),
    ),
  );
}
