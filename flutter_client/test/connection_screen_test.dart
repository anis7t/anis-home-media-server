import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_server_client/app/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String libmpvPath =
    'C:/MediaServer/flutter_client/build/windows/x64/runner/Release/libmpv-2.dll';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    if (File(libmpvPath).existsSync()) {
      MediaKit.ensureInitialized(libmpv: libmpvPath);
    } else {
      MediaKit.ensureInitialized();
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('ConnectionScreen renders branding, server input, and device identity', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MediaServerApp(),
      ),
    );

    // Let any initial microtasks and provider initialization settle
    await tester.pumpAndSettle();

    // Verify brand headers (using findRichText: true for RichText spans)
    expect(find.textContaining("Anis'", findRichText: true), findsWidgets);
    expect(find.textContaining("Home Media Server", findRichText: true), findsWidgets);
    expect(find.text('PLAY • ORGANIZE • ENJOY'), findsOneWidget);

    // Verify Server Origin card
    expect(find.text('Server Origin'), findsOneWidget);
    expect(find.text('Test Connection'), findsOneWidget);

    // Verify Client Device Identity card
    expect(find.text('Client Device Identity'), findsOneWidget);
    expect(find.text('CSPRNG Verified'), findsOneWidget);

    // Verify Save & Set Active Server button
    expect(find.text('Save & Set Active Server'), findsOneWidget);

    // Verify Launch Production Player (Phase 3A) button
    expect(find.text('Launch Production Video Player (Phase 3A)'), findsOneWidget);

    // Verify Launch Player POC (Phase 2) button
    expect(find.text('Launch Player POC Test Harness (Phase 2)'), findsOneWidget);
  });

  testWidgets('Launch Production Video Player navigates to PlayerScreen', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const ProviderScope(
        child: MediaServerApp(),
      ),
    );
    await tester.pumpAndSettle();

    final btn = find.text('Launch Production Video Player (Phase 3A)');
    expect(btn, findsOneWidget);
    await tester.tap(btn);
    // Use fixed pump to allow transition without timing out on spinner animation
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify PlayerScreen shell is rendered with its title
    expect(find.text('Batman Knightfall Part 1 (2026)'), findsOneWidget);
  });

  testWidgets('Launch Player POC navigates to PlayerPocScreen', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(2560, 1440);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const ProviderScope(
        child: MediaServerApp(),
      ),
    );
    await tester.pumpAndSettle();

    final btn = find.text('Launch Player POC Test Harness (Phase 2)');
    expect(btn, findsOneWidget);
    await tester.tap(btn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify PlayerPocScreen header is rendered
    expect(find.text('Player POC Test Harness (Phase 2)'), findsWidgets);
  });
}
