import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/app/routes.dart';

void main() {
  testWidgets('AppRoutes.createRouter intercepts ahms://auth/callback and captures token during runtime', (tester) async {
    String? capturedToken;

    final router = AppRoutes.createRouter(
      initialLocation: AppRoutes.home,
      onTokenReceived: (token) {
        capturedToken = token;
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Trigger deep link navigation
    router.go('ahms://auth/callback?session_token=sess_warm_test_999');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(capturedToken, equals('sess_warm_test_999'));
    expect(router.state.matchedLocation, equals(AppRoutes.settings));
  });

  testWidgets('AppRoutes.createRouter intercepts ahms://auth/callback on cold boot initialization', (tester) async {
    String? capturedToken;

    final router = AppRoutes.createRouter(
      initialLocation: 'ahms://auth/callback?session_token=sess_cold_test_888',
      onTokenReceived: (token) {
        capturedToken = token;
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(capturedToken, equals('sess_cold_test_888'));
    expect(router.state.matchedLocation, equals(AppRoutes.settings));
  });

  testWidgets('AppRoutes.createRouter handles internal /auth/callback route fallback', (tester) async {
    String? capturedToken;

    final router = AppRoutes.createRouter(
      initialLocation: AppRoutes.home,
      onTokenReceived: (token) {
        capturedToken = token;
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    router.go('/auth/callback?session_token=sess_internal_test_777');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(capturedToken, equals('sess_internal_test_777'));
    expect(router.state.matchedLocation, equals(AppRoutes.settings));
  });
}
