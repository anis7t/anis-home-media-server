import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:media_server_client/core/device/domain/device_capabilities.dart';
import 'package:media_server_client/core/device/infrastructure/device_capability_service.dart';
import 'package:media_server_client/features/intro/presentation/controllers/intro_controller.dart';
import 'package:media_server_client/features/shell/presentation/screens/app_shell.dart';
import 'package:media_server_client/features/shell/presentation/widgets/tv_exit_dialog.dart';
import 'package:media_server_client/features/shell/presentation/widgets/tv_side_navigation_rail.dart';
import 'package:media_server_client/features/updater/presentation/widgets/settings_content.dart';

class _MockIntroNotifier extends IntroController {
  @override
  IntroState build() => const IntroState(hasSeenIntro: true, isPlaying: false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const tvCapabilities = DeviceCapabilities(
    isTv: true,
    isAmazonFireTv: true,
    hasTouchscreen: false,
    hasLeanbackFeature: true,
    model: 'AFTMM',
    manufacturer: 'Amazon',
  );

  group('TV Pass 2: Navigation Rail & Back State Machine Tests', () {
    testWidgets('Expanded rail collapses on Back/Escape rather than exiting app', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceCapabilitiesProvider.overrideWithValue(tvCapabilities),
            introControllerProvider.overrideWith(() => _MockIntroNotifier()),
          ],
          child: MaterialApp.router(
            routerConfig: GoRouter(
              initialLocation: '/home',
              routes: [
                StatefulShellRoute.indexedStack(
                  builder: (context, state, shell) => AppShell(navigationShell: shell),
                  branches: [
                    StatefulShellBranch(routes: [
                      GoRoute(path: '/home', builder: (_, _) => const Scaffold(body: Text('Home Content'))),
                    ]),
                    StatefulShellBranch(routes: [
                      GoRoute(path: '/library', builder: (_, _) => const Scaffold(body: Text('Library Content'))),
                    ]),
                    StatefulShellBranch(routes: [
                      GoRoute(path: '/settings', builder: (_, _) => const Scaffold(body: Text('Settings Content'))),
                    ]),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Find ProviderContainer to check/modify tvRailExpandedProvider
      final element = tester.element(find.byType(TvSideNavigationRail));
      final container = ProviderScope.containerOf(element);

      // Expand the rail
      container.read(tvRailExpandedProvider.notifier).expand();
      await tester.pumpAndSettle();
      expect(container.read(tvRailExpandedProvider), isTrue);

      // Trigger back navigation
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      // Rail should now be collapsed, exit dialog should NOT be shown
      expect(container.read(tvRailExpandedProvider), isFalse);
      expect(find.byType(TvExitDialog), findsNothing);
    });

    testWidgets('Root Back on Home triggers TvExitDialog', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceCapabilitiesProvider.overrideWithValue(tvCapabilities),
            introControllerProvider.overrideWith(() => _MockIntroNotifier()),
          ],
          child: MaterialApp.router(
            routerConfig: GoRouter(
              initialLocation: '/home',
              routes: [
                StatefulShellRoute.indexedStack(
                  builder: (context, state, shell) => AppShell(navigationShell: shell),
                  branches: [
                    StatefulShellBranch(routes: [
                      GoRoute(path: '/home', builder: (_, _) => const Scaffold(body: Text('Home Content'))),
                    ]),
                    StatefulShellBranch(routes: [
                      GoRoute(path: '/library', builder: (_, _) => const Scaffold(body: Text('Library Content'))),
                    ]),
                    StatefulShellBranch(routes: [
                      GoRoute(path: '/settings', builder: (_, _) => const Scaffold(body: Text('Settings Content'))),
                    ]),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final element = tester.element(find.byType(TvSideNavigationRail));
      final container = ProviderScope.containerOf(element);
      expect(container.read(tvRailExpandedProvider), isFalse);

      // Press Back at root Home via Android back dispatch
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      // TvExitDialog should be displayed
      expect(find.byType(TvExitDialog), findsOneWidget);
      expect(find.text('Exit Application?'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Exit'), findsOneWidget);

      // Tapping Cancel dismisses dialog and leaves app open
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(TvExitDialog), findsNothing);
      expect(find.text('Home Content'), findsOneWidget);
    });
  });

  group('TV Pass 2: Settings Screen Focus vs Selection Tests', () {
    testWidgets('Settings renders with TV padding and channel cards distinguish selection', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceCapabilitiesProvider.overrideWithValue(tvCapabilities),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SettingsContent(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify Production and Developer channel options exist
      expect(find.text('Production (Stable)'), findsOneWidget);
      expect(find.text('Developer'), findsOneWidget);

      // Production should have the ACTIVE badge
      expect(find.text('ACTIVE'), findsOneWidget);

      // Check for Updates button exists
      expect(find.text('Check for Updates'), findsOneWidget);

      // Verify full-width server connection card exists with TV helper text
      expect(find.text('Connected • Press to change server address'), findsOneWidget);
    });
  });

  group('TV Pass 2: D-pad Rail Entry & Exit Debounce Tests', () {
    testWidgets('D-pad Left from leftmost content transitions focus into rail and expands it', (tester) async {
      final buttonFocusNode = FocusNode(debugLabel: 'test_home_button');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceCapabilitiesProvider.overrideWithValue(tvCapabilities),
            introControllerProvider.overrideWith(() => _MockIntroNotifier()),
          ],
          child: MaterialApp.router(
            routerConfig: GoRouter(
              initialLocation: '/home',
              routes: [
                StatefulShellRoute.indexedStack(
                  builder: (context, state, shell) => AppShell(navigationShell: shell),
                  branches: [
                    StatefulShellBranch(routes: [
                      GoRoute(
                        path: '/home',
                        builder: (_, _) => Scaffold(
                          body: Focus(
                            focusNode: buttonFocusNode,
                            child: const Text('Home Focus Target'),
                          ),
                        ),
                      ),
                    ]),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final element = tester.element(find.byType(TvSideNavigationRail));
      final container = ProviderScope.containerOf(element);

      // Focus the content button
      buttonFocusNode.requestFocus();
      await tester.pumpAndSettle();
      expect(buttonFocusNode.hasFocus, isTrue);
      expect(container.read(tvRailExpandedProvider), isFalse);

      // Simulate D-pad Left from leftmost content
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();

      // Focus should have cleanly transitioned into the side navigation rail and expanded it
      expect(container.read(tvRailExpandedProvider), isTrue);
      final railNodes = container.read(tvRailFocusNodesProvider);
      expect(railNodes[0].hasFocus, isTrue);
    });

    testWidgets('TvExitDialog debounces back key within 350ms of opening to eliminate double-firing', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => TvExitDialog.show(context),
              child: const Text('Show Dialog'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Show Dialog'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(TvExitDialog), findsOneWidget);

      // Trigger back immediately (under 350ms, at 50ms)
      await tester.binding.handlePopRoute();
      await tester.pump();

      // Dialog MUST remain on screen because 350ms timer has not fired yet!
      expect(find.byType(TvExitDialog), findsOneWidget);

      // Wait beyond the 350ms debounce threshold
      await tester.pump(const Duration(milliseconds: 400));

      // Second Back press dismisses dialog cleanly
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(TvExitDialog), findsNothing);
    });
  });
}
