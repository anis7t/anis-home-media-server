import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'app/app.dart';
import 'app/routes.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final startAtPoc = args.contains('--player-poc') || args.contains('--poc');
  runApp(
    ProviderScope(
      child: MediaServerApp(
        initialRoute: startAtPoc ? AppRoutes.playerPoc : null,
      ),
    ),
  );
}
