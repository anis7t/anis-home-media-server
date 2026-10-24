import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/device/infrastructure/device_capability_service.dart';
import 'package:media_server_client/features/admin/presentation/widgets/admin_hub_tile.dart';
import 'package:media_server_client/features/auth/presentation/providers/auth_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildTestableWidget({
    required bool isAdmin,
    bool isTv = false,
  }) {
    return ProviderScope(
      overrides: [
        isAdminProvider.overrideWithValue(isAdmin),
        isTvModeProvider.overrideWithValue(isTv),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: AdminHubTile(),
        ),
      ),
    );
  }

  testWidgets('AdminHubTile renders LOCKED badge and lock icon when unauthenticated', (tester) async {
    await tester.pumpWidget(buildTestableWidget(isAdmin: false));
    await tester.pumpAndSettle();

    expect(find.text('Admin Management Hub'), findsOneWidget);
    expect(find.text('LOCKED'), findsOneWidget);
    expect(find.text('Enter Admin PIN to unlock server management tools'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
  });

  testWidgets('AdminHubTile renders UNLOCKED badge and admin shield icon when admin', (tester) async {
    await tester.pumpWidget(buildTestableWidget(isAdmin: true));
    await tester.pumpAndSettle();

    expect(find.text('Admin Management Hub'), findsOneWidget);
    expect(find.text('UNLOCKED'), findsOneWidget);
    expect(find.text('Storage, Transcodes, Devices & Library Maintenance'), findsOneWidget);
    expect(find.byIcon(Icons.admin_panel_settings_rounded), findsOneWidget);
  });
}
