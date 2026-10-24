import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/errors/app_exception.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/features/auth/domain/models/auth_state.dart';
import 'package:media_server_client/features/auth/domain/models/user_identity.dart';
import 'package:media_server_client/features/auth/infrastructure/auth_repository.dart';
import 'package:media_server_client/features/auth/infrastructure/auth_secure_storage.dart';
import 'package:media_server_client/features/auth/presentation/providers/auth_providers.dart';
import 'auth_secure_storage_test.dart';

class FakeAuthRepository extends AuthRepository {
  UserIdentity nextIdentity;
  String? nextLoginToken;
  bool shouldThrowOnLogin;
  bool shouldThrowOnGetMe;
  bool verifyPinResult;

  FakeAuthRepository({
    required super.apiClient,
    required super.secureStorage,
    this.nextIdentity = UserIdentity.guest,
    this.nextLoginToken = 'sess_fake_123',
    this.shouldThrowOnLogin = false,
    this.shouldThrowOnGetMe = false,
    this.verifyPinResult = true,
  });

  @override
  Future<UserIdentity> getMe() async {
    if (shouldThrowOnGetMe) {
      throw const ServerException('Server error');
    }
    return nextIdentity;
  }

  @override
  Future<({UserIdentity identity, String sessionToken})> loginWithPin(String pin) async {
    if (shouldThrowOnLogin) {
      throw const UnauthorizedException('Invalid PIN');
    }
    await secureStorage.saveSessionToken(nextLoginToken!);
    return (identity: nextIdentity, sessionToken: nextLoginToken!);
  }

  @override
  Future<bool> verifyAdminPin(String pin) async {
    return verifyPinResult;
  }

  @override
  Future<void> logout() async {
    await secureStorage.clearAll();
  }
}

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
    );
  });

  ProviderContainer createContainer() {
    final container = ProviderContainer(
      overrides: [
        authSecureStorageProvider.overrideWithValue(authSecureStorage),
        authRepositoryProvider.overrideWithValue(fakeRepository),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('AuthNotifier', () {
    test('initial state is AuthState.initial', () {
      final container = createContainer();
      final state = container.read(authNotifierProvider);

      expect(state.status, equals(AuthStatus.initial));
      expect(state.isAuthenticated, isFalse);
    });

    test('hydrate transitions to unauthenticated when storage is empty', () async {
      final container = createContainer();
      final notifier = container.read(authNotifierProvider.notifier);

      await notifier.hydrate();

      final state = container.read(authNotifierProvider);
      expect(state.status, equals(AuthStatus.unauthenticated));
      expect(state.isAuthenticated, isFalse);
      expect(state.sessionToken, isNull);
    });

    test('hydrate restores authenticated state when valid token and identity exist', () async {
      await authSecureStorage.saveSessionToken('sess_stored_valid');
      fakeRepository.nextIdentity = const UserIdentity(
        id: 1,
        email: 'admin@media.server',
        name: 'Administrator',
        role: 'admin',
        isAdmin: true,
        oauthConfigured: true,
      );

      final container = createContainer();
      final notifier = container.read(authNotifierProvider.notifier);

      await notifier.hydrate();

      final state = container.read(authNotifierProvider);
      expect(state.status, equals(AuthStatus.authenticated));
      expect(state.isAuthenticated, isTrue);
      expect(state.isAdmin, isTrue);
      expect(state.identity?.email, equals('admin@media.server'));
      expect(state.sessionToken, equals('sess_stored_valid'));
    });

    test('hydrate clears stale token when getMe returns guest', () async {
      await authSecureStorage.saveSessionToken('sess_stale_expired');
      fakeRepository.nextIdentity = UserIdentity.guest;

      final container = createContainer();
      final notifier = container.read(authNotifierProvider.notifier);

      await notifier.hydrate();

      final state = container.read(authNotifierProvider);
      expect(state.status, equals(AuthStatus.unauthenticated));
      expect(state.isAuthenticated, isFalse);
      expect(await authSecureStorage.getSessionToken(), isNull);
    });

    test('loginWithPin updates state to authenticated on success', () async {
      fakeRepository.nextIdentity = const UserIdentity(
        id: 1,
        email: 'admin@localhost',
        role: 'admin',
        isAdmin: true,
        oauthConfigured: true,
      );
      fakeRepository.nextLoginToken = 'sess_pin_success';

      final container = createContainer();
      final notifier = container.read(authNotifierProvider.notifier);

      final success = await notifier.loginWithPin('1234');

      expect(success, isTrue);
      final state = container.read(authNotifierProvider);
      expect(state.status, equals(AuthStatus.authenticated));
      expect(state.isAuthenticated, isTrue);
      expect(state.sessionToken, equals('sess_pin_success'));
      expect(state.activeAdminPin, equals('1234'));
    });

    test('loginWithPin handles failure cleanly', () async {
      fakeRepository.shouldThrowOnLogin = true;

      final container = createContainer();
      final notifier = container.read(authNotifierProvider.notifier);

      final success = await notifier.loginWithPin('wrong-pin');

      expect(success, isFalse);
      final state = container.read(authNotifierProvider);
      expect(state.status, equals(AuthStatus.unauthenticated));
      expect(state.isAuthenticated, isFalse);
      expect(state.errorMessage, contains('Invalid PIN'));
    });

    test('setSessionToken stores token and hydrates profile', () async {
      fakeRepository.nextIdentity = const UserIdentity(
        id: 2,
        email: 'google_user@gmail.com',
        role: 'viewer',
        isAdmin: false,
        oauthConfigured: true,
      );

      final container = createContainer();
      final notifier = container.read(authNotifierProvider.notifier);

      final success = await notifier.setSessionToken('sess_oauth_token_777');

      expect(success, isTrue);
      final state = container.read(authNotifierProvider);
      expect(state.status, equals(AuthStatus.authenticated));
      expect(state.identity?.email, equals('google_user@gmail.com'));
      expect(state.sessionToken, equals('sess_oauth_token_777'));
      expect(await authSecureStorage.getSessionToken(), equals('sess_oauth_token_777'));
    });

    test('verifyAndUnlockAdminPin sets activeAdminPin on success', () async {
      fakeRepository.verifyPinResult = true;

      final container = createContainer();
      final notifier = container.read(authNotifierProvider.notifier);

      final ok = await notifier.verifyAndUnlockAdminPin('9999', remember: true);

      expect(ok, isTrue);
      final state = container.read(authNotifierProvider);
      expect(state.isAdmin, isTrue);
      expect(state.activeAdminPin, equals('9999'));
      expect(await authSecureStorage.getAdminPin(), equals('9999'));
    });

    test('logout resets state to unauthenticated and clears storage', () async {
      await authSecureStorage.saveSessionToken('sess_active');
      final container = createContainer();
      final notifier = container.read(authNotifierProvider.notifier);

      await notifier.logout();

      final state = container.read(authNotifierProvider);
      expect(state.status, equals(AuthStatus.unauthenticated));
      expect(state.isAuthenticated, isFalse);
      expect(await authSecureStorage.getSessionToken(), isNull);
    });

    test('handleUnauthorized wipes session and resets to guest', () async {
      await authSecureStorage.saveSessionToken('sess_to_wipe');
      fakeRepository.nextIdentity = const UserIdentity(
        id: 1,
        email: 'user@media.server',
        role: 'viewer',
        isAdmin: false,
      );

      final container = createContainer();
      final notifier = container.read(authNotifierProvider.notifier);

      await notifier.hydrate();
      expect(container.read(authNotifierProvider).isAuthenticated, isTrue);

      notifier.handleUnauthorized();

      expect(container.read(authNotifierProvider).isAuthenticated, isFalse);
      expect(await authSecureStorage.getSessionToken(), isNull);
    });
  });
}
