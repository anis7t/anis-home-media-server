import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'app/app.dart';
import 'app/routes.dart';
import 'core/device/domain/device_capabilities.dart';
import 'core/device/infrastructure/device_capability_service.dart';
import 'features/devices/presentation/widgets/device_presence_scope.dart';
import 'features/intro/infrastructure/audioplayers_score.dart';
import 'features/intro/presentation/providers/intro_score_provider.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final hasTvArg = args.contains('--tv') || args.contains('--tv-mode');
  final capabilities = hasTvArg
      ? DeviceCapabilities.tvDefault
      : await DeviceCapabilityService.detect();

  final hasRouteArg = args.any((a) => a.startsWith('--route='));
  final routeArg = hasRouteArg
      ? args.firstWhere((a) => a.startsWith('--route=')).substring(8)
      : null;

  final startAtPlayer = args.contains('--player') ||
      args.contains('--player-poc') ||
      args.contains('--poc') ||
      routeArg == '/player' ||
      routeArg == 'player' ||
      routeArg == '/player-poc' ||
      routeArg == 'player-poc' ||
      routeArg == 'poc';

  final hasServerArg = args.any((a) => a.startsWith('--server='));
  final serverArg = hasServerArg
      ? args.firstWhere((a) => a.startsWith('--server=')).substring(9)
      : null;

  final hasMediaUrlArg = args.any((a) => a.startsWith('--media-url='));
  final mediaUrlArg = hasMediaUrlArg
      ? args.firstWhere((a) => a.startsWith('--media-url=')).substring(12)
      : null;

  String? initialRoute;
  if (startAtPlayer) {
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

  // The brand opening sequence's score is prepared HERE, before the first
  // frame, so that the platform's own preparation overlaps the application's
  // own start-up. The score is anchored to the sequence when it actually
  // starts, so the sooner it is ready the smaller the anchor - and the
  // animation never waits for it either way.
  final introScore = AudioplayersIntroScore();
  unawaited(introScore.prepare());

  runApp(
    ProviderScope(
      overrides: [
        deviceCapabilitiesOverrideProvider.overrideWith(
          () => DeviceCapabilitiesOverrideNotifier(capabilities),
        ),
        introScoreProvider.overrideWithValue(introScore),
      ],
      child: DevicePresenceScope(
        child: MediaServerApp(
          initialRoute: initialRoute,
        ),
      ),
    ),
  );
}
