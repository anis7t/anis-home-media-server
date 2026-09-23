import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'routes.dart';
import 'theme/app_theme.dart';

class MediaServerApp extends ConsumerWidget {
  const MediaServerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: "Anis' Home Media Server",
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      routerConfig: AppRoutes.router,
    );
  }
}
