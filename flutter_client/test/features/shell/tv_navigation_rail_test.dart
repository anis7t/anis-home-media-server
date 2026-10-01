import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:media_server_client/core/device/domain/device_capabilities.dart';
import 'package:media_server_client/core/device/infrastructure/device_capability_service.dart';
import 'package:media_server_client/features/intro/presentation/controllers/intro_controller.dart';
import 'package:media_server_client/features/shell/presentation/screens/app_shell.dart';
import 'package:media_server_client/features/shell/presentation/widgets/tv_side_navigation_rail.dart';

void main() {
  group('TvSideNavigationRail & Adaptive Shell Tests', () {
    testWidgets('AppShell renders mobile NavigationBar when isTvMode is false', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceCapabilitiesProvider.overrideWithValue(DeviceCapabilities.mobileDefault),
            introControllerProvider.overrideWith(() => _MockIntroNotifier(false)),
          ],
          child: MaterialApp.router(
            routerConfig: GoRouter(
              initialLocation: '/home',
              routes: [
                StatefulShellRoute.indexedStack(
                  builder: (context, state, shell) => AppShell(navigationShell: shell),
                  branches: [
                    StatefulShellBranch(routes: [
                      GoRoute(path: '/home', builder: (_, _) => const Text('Home Content')),
                    ]),
                    StatefulShellBranch(routes: [
                      GoRoute(path: '/library', builder: (_, _) => const Text('Library Content')),
                    ]),
                    StatefulShellBranch(routes: [
                      GoRoute(path: '/settings', builder: (_, _) => const Text('Settings Content')),
                    ]),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(TvSideNavigationRail), findsNothing);
      expect(find.text('Home Content'), findsOneWidget);
    });

    testWidgets('AppShell renders TvSideNavigationRail and NO bottom nav when isTvMode is true', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceCapabilitiesProvider.overrideWithValue(DeviceCapabilities.tvDefault),
            introControllerProvider.overrideWith(() => _MockIntroNotifier(false)),
          ],
          child: MaterialApp.router(
            routerConfig: GoRouter(
              initialLocation: '/home',
              routes: [
                StatefulShellRoute.indexedStack(
                  builder: (context, state, shell) => AppShell(navigationShell: shell),
                  branches: [
                    StatefulShellBranch(routes: [
                      GoRoute(path: '/home', builder: (_, _) => const Text('Home Content')),
                    ]),
                    StatefulShellBranch(routes: [
                      GoRoute(path: '/library', builder: (_, _) => const Text('Library Content')),
                    ]),
                    StatefulShellBranch(routes: [
                      GoRoute(path: '/settings', builder: (_, _) => const Text('Settings Content')),
                    ]),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(TvSideNavigationRail), findsOneWidget);
      expect(find.text('Home Content'), findsOneWidget);

      // Verify TV rail destinations are rendered
      expect(find.byIcon(Icons.home_rounded), findsOneWidget);
      expect(find.byIcon(Icons.video_library_outlined), findsOneWidget);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);

      // Tap Library in TV rail
      await tester.tap(find.byIcon(Icons.video_library_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Library Content'), findsOneWidget);
    });
  });
}

class _MockIntroNotifier extends IntroController {
  final bool initialPlaying;
  _MockIntroNotifier(this.initialPlaying);

  @override
  IntroState build() => IntroState(hasSeenIntro: true, isPlaying: initialPlaying);
}
