import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'routes.dart';
import 'theme/app_theme.dart';

class MediaServerApp extends ConsumerWidget {
  final String? initialRoute;
  final RouterConfig<Object>? routerConfig;

  const MediaServerApp({
    super.key,
    this.initialRoute,
    this.routerConfig,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: "Anis' Home Media Server",
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      routerConfig: routerConfig ??
          (initialRoute != null && initialRoute != AppRoutes.connection
              ? AppRoutes.createRouter(initialLocation: initialRoute!)
              : AppRoutes.createRouter()),
    );
  }
}
