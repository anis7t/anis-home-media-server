import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:media_server_client/features/intro/presentation/controllers/intro_controller.dart';
import 'package:media_server_client/features/intro/presentation/widgets/brand_intro_overlay.dart';
import 'package:media_server_client/features/shell/presentation/screens/app_shell.dart';

class FakePlayingIntroController extends IntroController {
  @override
  IntroState build() {
    return const IntroState(hasSeenIntro: false, isPlaying: true);
  }
}

void main() {
  group('BrandIntroOverlay Widget Tests', () {
    testWidgets('renders Skip button and overlay structure', (tester) async {
      bool finishedCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BrandIntroOverlay(
              autoFinishOnError: false,
              onFinished: () {
                finishedCalled = true;
              },
            ),
          ),
        ),
      );

      // Verify the Skip button is present
      expect(find.text('Skip'), findsOneWidget);
      expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);

      // Tap the Skip button
      await tester.tap(find.text('Skip'));
      await tester.pump(const Duration(milliseconds: 350));

      expect(finishedCalled, isTrue);
    });

    testWidgets('tap anywhere on screen triggers finish callback', (tester) async {
      bool finishedCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BrandIntroOverlay(
              autoFinishOnError: false,
              onFinished: () {
                finishedCalled = true;
              },
            ),
          ),
        ),
      );

      // Tap on the center of the overlay
      await tester.tap(find.byType(BrandIntroOverlay));
      await tester.pump(const Duration(milliseconds: 350));

      expect(finishedCalled, isTrue);
    });

    testWidgets('AppShell overlays BrandIntroOverlay when isPlaying is true', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          introControllerProvider.overrideWith(
            () => FakePlayingIntroController(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final router = GoRouter(
        initialLocation: '/test-home',
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (context, state, navigationShell) {
              return AppShell(
                navigationShell: navigationShell,
                autoFinishIntroOnError: false,
              );
            },
            branches: [
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/test-home',
                    builder: (context, state) => const Scaffold(
                      body: Center(child: Text('Underlying Shell Content')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
          ),
        ),
      );

      // Verify overlay is mounted on top of the shell
      expect(find.byType(BrandIntroOverlay), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);

      // Tap Skip to dismiss
      await tester.tap(find.text('Skip'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      // Verify dismissal
      expect(container.read(introControllerProvider).isPlaying, isFalse);
      expect(container.read(introControllerProvider).hasSeenIntro, isTrue);
      expect(find.byType(BrandIntroOverlay), findsNothing);
      expect(find.text('Underlying Shell Content'), findsOneWidget);
    });
  });
}
