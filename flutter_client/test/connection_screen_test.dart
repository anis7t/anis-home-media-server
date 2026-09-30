import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_server_client/app/app.dart';
import 'package:media_server_client/app/routes.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String libmpvPath =
    'E:/MediaServer/flutter_client/build/windows/x64/runner/Release/libmpv-2.dll';

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

  testWidgets('Default app launch route is AppRoutes.home', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1440);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const ProviderScope(
        child: MediaServerApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify Home tab destination in bottom navigation bar is rendered
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('ConnectionScreen renders branding, server input, and device identity without dev options', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1440);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const ProviderScope(
        child: MediaServerApp(
          initialRoute: AppRoutes.connection,
        ),
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

    // Verify WAN preset chip is available
    expect(find.text('WAN (Cloudflare)'), findsOneWidget);

    // Verify Client Device Identity card
    expect(find.text('Client Device Identity'), findsOneWidget);
    expect(find.text('CSPRNG Verified'), findsOneWidget);

    // Verify Save & Set Active Server and Enter Media Server buttons
    expect(find.text('Save & Set Active Server'), findsOneWidget);
    expect(find.text('Enter Media Server (Home)'), findsOneWidget);

    // Verify dev options are completely absent
    expect(find.text('Launch Production Video Player (Phase 3A)'), findsNothing);
    expect(find.text('Launch Player POC Test Harness (Phase 2)'), findsNothing);
    expect(find.text('Browse Movie Library (Phase 4)'), findsNothing);
  });

  testWidgets('Enter Media Server navigates to HomeScreen in AppShell', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1440);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const ProviderScope(
        child: MediaServerApp(
          initialRoute: AppRoutes.connection,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final btn = find.text('Enter Media Server (Home)');
    expect(btn, findsOneWidget);
    await tester.tap(btn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify navigation into Home tab in shell
    expect(find.text('Home'), findsOneWidget);
  });
}
