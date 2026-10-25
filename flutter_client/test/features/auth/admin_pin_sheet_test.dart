import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/features/auth/domain/models/user_identity.dart';
import 'package:media_server_client/features/auth/data/auth_secure_storage.dart';
import 'package:media_server_client/features/auth/presentation/providers/auth_providers.dart';
import 'package:media_server_client/features/auth/presentation/widgets/admin_pin_sheet.dart';
import 'auth_notifier_test.dart';
import 'auth_secure_storage_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSecureStorage mockSecureStorage;
  late AuthSecureStorage authSecureStorage;
  late FakeAuthRepository fakeRepository;

  setUp(() {
    mockSecureStorage = MockSecureStorage();
    authSecureStorage = AuthSecureStorage(secureStorage: mockSecureStorage);

    final deviceService = DeviceIdentityService(secureStorage: mockSecureStorage);
    final interceptor = DeviceAuthInterceptor(deviceService);
    final apiClient = ApiClient(
      baseUrl: 'http://127.0.0.1:8000',
      authInterceptor: interceptor,
    );

    fakeRepository = FakeAuthRepository(
      apiClient: apiClient,
      secureStorage: authSecureStorage,
      nextIdentity: const UserIdentity(
        id: 1,
        email: 'admin@media.server',
        role: 'admin',
        isAdmin: true,
      ),
    );
  });

  Widget buildTestableWidget({required Widget child}) {
    return ProviderScope(
      overrides: [
        authSecureStorageProvider.overrideWithValue(authSecureStorage),
        authRepositoryProvider.overrideWithValue(fakeRepository),
      ],
      child: MaterialApp(
        home: Scaffold(body: child),
      ),
    );
  }

  group('AdminPinSheet Widget', () {
    testWidgets('renders PIN sheet title, input, and action buttons', (tester) async {
      await tester.pumpWidget(
        buildTestableWidget(
          child: const AdminPinSheet(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Admin PIN Sign-In'), findsOneWidget);
      expect(find.text('Verify & Sign In'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Remember PIN on this device'), findsOneWidget);
    });

    testWidgets('shows validation message on empty submission', (tester) async {
      await tester.pumpWidget(
        buildTestableWidget(
          child: const AdminPinSheet(),
        ),
      );
      await tester.pumpAndSettle();

      // Tap submit with empty field
      await tester.tap(find.text('Verify & Sign In'));
      await tester.pumpAndSettle();

      expect(find.text('Please enter your Admin PIN'), findsOneWidget);
    });

    testWidgets('successfully signs in with valid PIN and closes sheet', (tester) async {
      bool? dialogResult;

      await tester.pumpWidget(
        buildTestableWidget(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                dialogResult = await AdminPinSheet.show(context);
              },
              child: const Text('Open Sheet'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open sheet
      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();

      // Enter PIN
      await tester.enterText(find.byType(TextField), '1234');
      await tester.pumpAndSettle();

      // Tap submit
      await tester.tap(find.text('Verify & Sign In'));
      await tester.pumpAndSettle();

      expect(dialogResult, isTrue);
    });

    testWidgets('displays error feedback on invalid PIN submission', (tester) async {
      fakeRepository.shouldThrowOnLogin = true;

      await tester.pumpWidget(
        buildTestableWidget(
          child: const AdminPinSheet(),
        ),
      );
      await tester.pumpAndSettle();

      // Enter wrong PIN
      await tester.enterText(find.byType(TextField), '0000');
      await tester.pumpAndSettle();

      // Tap submit
      await tester.tap(find.text('Verify & Sign In'));
      await tester.pumpAndSettle();

      expect(find.text('Invalid Admin PIN. Please try again.'), findsOneWidget);
    });
  });
}
