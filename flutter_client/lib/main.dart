import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'app/app.dart';
import 'app/routes.dart';
import 'core/device/domain/device_capabilities.dart';
import 'core/device/infrastructure/device_capability_service.dart';
import 'features/devices/presentation/widgets/device_presence_scope.dart';

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
      overrides: [
        deviceCapabilitiesOverrideProvider.overrideWith(
          () => DeviceCapabilitiesOverrideNotifier(capabilities),
        ),
      ],
      child: DevicePresenceScope(
        child: MediaServerApp(
          initialRoute: initialRoute,
        ),
      ),
    ),
  );
}
