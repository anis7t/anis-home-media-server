import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/app/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
  });
}
