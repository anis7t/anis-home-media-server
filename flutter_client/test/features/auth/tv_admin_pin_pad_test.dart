import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/errors/app_exception.dart';
import 'package:media_server_client/features/auth/domain/models/user_identity.dart';
import 'package:media_server_client/features/auth/data/auth_repository.dart';
import 'package:media_server_client/features/auth/data/auth_secure_storage.dart';
import 'package:media_server_client/features/auth/presentation/providers/auth_providers.dart';
import 'package:media_server_client/features/auth/presentation/widgets/tv_admin_pin_pad.dart';
import 'auth_secure_storage_test.dart';

class _FakeAuthRepository extends Fake implements AuthRepository {
  bool shouldSucceed = true;

  @override
  Future<({UserIdentity identity, String sessionToken})> loginWithPin(String pin) async {
    if (shouldSucceed && pin == '1234') {
      return (
        identity: const UserIdentity(
          id: 1,
          role: 'admin',
          isAdmin: true,
        ),
        sessionToken: 'test-session-token-pin',
      );
    }
    throw const UnauthorizedException('Invalid PIN');
  }

  @override
  Future<UserIdentity> getMe() async {
    return const UserIdentity(
      id: 1,
      role: 'admin',
      isAdmin: true,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSecureStorage mockSecureStorage;
  late AuthSecureStorage authSecureStorage;
  late _FakeAuthRepository fakeRepository;

  setUp(() {
    mockSecureStorage = MockSecureStorage();
    authSecureStorage = AuthSecureStorage(secureStorage: mockSecureStorage);
    fakeRepository = _FakeAuthRepository();
  });

  Widget buildTestableWidget({
    VoidCallback? onSuccess,
    VoidCallback? onCancel,
  }) {
    return ProviderScope(
      overrides: [
        authSecureStorageProvider.overrideWithValue(authSecureStorage),
        authRepositoryProvider.overrideWithValue(fakeRepository),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: TvAdminPinPad(
            onSuccess: onSuccess,
            onCancel: onCancel,
          ),
        ),
      ),
    );
  }

  group('TvAdminPinPad Widget', () {
    testWidgets('renders PIN pad title, indicators, and 10 keypad digits', (tester) async {
      await tester.pumpWidget(buildTestableWidget());
      await tester.pumpAndSettle();

      expect(find.text('Admin PIN Sign-In'), findsOneWidget);
      expect(find.text('Use your remote control to enter the server PIN'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
      expect(find.text('⌫'), findsOneWidget);
      expect(find.text('Clear All'), findsOneWidget);
    });

    testWidgets('tapping digits and backspace updates entered digits', (tester) async {
      await tester.pumpWidget(buildTestableWidget());
      await tester.pumpAndSettle();

      await tester.tap(find.text('1'));
      await tester.pump();
      await tester.tap(find.text('2'));
      await tester.pump();

      // Tap backspace
      await tester.tap(find.text('⌫'));
      await tester.pump();

      // Clear all
      await tester.tap(find.text('Clear All'));
      await tester.pump();
    });

    testWidgets('entering 4 valid digits triggers login and invokes onSuccess', (tester) async {
      bool successCalled = false;
      await tester.pumpWidget(buildTestableWidget(
        onSuccess: () {
          successCalled = true;
        },
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('1'));
      await tester.pump();
      await tester.tap(find.text('2'));
      await tester.pump();
      await tester.tap(find.text('3'));
      await tester.pump();
      await tester.tap(find.text('4'));
      await tester.pumpAndSettle();

      expect(successCalled, isTrue);
    });

    testWidgets('entering invalid PIN displays error feedback', (tester) async {
      fakeRepository.shouldSucceed = false;

      await tester.pumpWidget(buildTestableWidget());
      await tester.pumpAndSettle();

      await tester.tap(find.text('9'));
      await tester.pump();
      await tester.tap(find.text('9'));
      await tester.pump();
      await tester.tap(find.text('9'));
      await tester.pump();
      await tester.tap(find.text('9'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Invalid PIN'), findsOneWidget);
    });
  });
}
