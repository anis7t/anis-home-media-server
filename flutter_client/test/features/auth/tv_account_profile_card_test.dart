import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/auth/domain/models/auth_state.dart';
import 'package:media_server_client/features/auth/domain/models/user_identity.dart';
import 'package:media_server_client/features/auth/infrastructure/auth_repository.dart';
import 'package:media_server_client/features/auth/infrastructure/auth_secure_storage.dart';
import 'package:media_server_client/features/auth/presentation/controllers/auth_notifier.dart';
import 'package:media_server_client/features/auth/presentation/providers/auth_providers.dart';
import 'package:media_server_client/features/auth/presentation/widgets/tv_account_profile_card.dart';
import 'auth_secure_storage_test.dart';

class _FakeAuthRepository extends Fake implements AuthRepository {
  bool logoutCalled = false;

  @override
  Future<void> logout() async {
    logoutCalled = true;
  }
}

class _PreloadedAuthNotifier extends AuthNotifier {
  final AuthState _preloadedState;

  _PreloadedAuthNotifier(this._preloadedState);

  @override
  AuthState build() => _preloadedState;
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

  Widget buildTestableWidget({AuthState? initialAuthState}) {
    return ProviderScope(
      overrides: [
        authSecureStorageProvider.overrideWithValue(authSecureStorage),
        authRepositoryProvider.overrideWithValue(fakeRepository),
        if (initialAuthState != null)
          authNotifierProvider.overrideWith(
            () => _PreloadedAuthNotifier(initialAuthState),
          ),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: TvAccountProfileCard(),
        ),
      ),
    );
  }

  group('TvAccountProfileCard Widget', () {
    testWidgets('renders TV Guest mode with QR Pair and Admin PIN Pad buttons when unauthenticated',
        (tester) async {
      await tester.pumpWidget(buildTestableWidget());
      await tester.pumpAndSettle();

      expect(find.text('Guest Mode'), findsOneWidget);
      expect(find.text('TV VIEWER'), findsOneWidget);
      expect(find.text('Pair with Phone (QR Code)'), findsOneWidget);
      expect(find.text('Admin PIN Pad'), findsOneWidget);
    });

    testWidgets('renders TV Authenticated profile with ADMIN badge and Sign Out button',
        (tester) async {
      const adminIdentity = UserIdentity(
        id: 1,
        email: 'admin@mediaserver.local',
        name: 'Admin Parvez',
        role: 'admin',
        isAdmin: true,
      );

      const authState = AuthState(
        status: AuthStatus.authenticated,
        identity: adminIdentity,
      );

      await tester.pumpWidget(buildTestableWidget(initialAuthState: authState));
      await tester.pumpAndSettle();

      expect(find.text('Admin Parvez'), findsOneWidget);
      expect(find.text('admin@mediaserver.local'), findsOneWidget);
      expect(find.text('ADMIN'), findsOneWidget);
      expect(find.text('Sign Out'), findsOneWidget);

      await tester.tap(find.text('Sign Out'));
      await tester.pump();
      expect(fakeRepository.logoutCalled, isTrue);
    });
  });
}
