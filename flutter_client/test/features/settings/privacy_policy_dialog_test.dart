import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/settings/presentation/widgets/privacy_policy_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildSubject() {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: PrivacyPolicyDialog(),
        ),
      ),
    );
  }

  testWidgets('PrivacyPolicyDialog renders all transparency sections', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    expect(find.text('Privacy & Architecture'), findsOneWidget);
    expect(find.text('Zero Third-Party Tracking'), findsOneWidget);
    expect(find.text('First-Party Operational Diagnostics'), findsOneWidget);
    expect(find.text('Local Database Persistence'), findsOneWidget);
    expect(find.text('External Media Metadata'), findsOneWidget);
    expect(find.text('Encrypted Remote Transport'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('PrivacyPolicyDialog closes when Close button is pressed', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (_) => const PrivacyPolicyDialog(),
                  );
                },
                child: const Text('Open Dialog'),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open Dialog'));
    await tester.pumpAndSettle();

    expect(find.text('Privacy & Architecture'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(find.text('Privacy & Architecture'), findsNothing);
  });

  testWidgets('PrivacyPolicyDialog closes when X icon is pressed', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (_) => const PrivacyPolicyDialog(),
                  );
                },
                child: const Text('Open Dialog'),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open Dialog'));
    await tester.pumpAndSettle();

    expect(find.text('Privacy & Architecture'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Privacy & Architecture'), findsNothing);
  });
}
