import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/features/auth/domain/models/auth_state.dart';
import 'package:media_server_client/features/auth/domain/models/user_identity.dart';
import 'package:media_server_client/features/auth/data/auth_secure_storage.dart';
import 'package:media_server_client/features/auth/presentation/controllers/auth_notifier.dart';
import 'package:media_server_client/features/auth/presentation/providers/auth_providers.dart';
import 'package:media_server_client/features/auth/presentation/widgets/account_profile_card.dart';
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
    );
  });

  Widget buildTestableWidget({
    AuthState? initialAuthState,
    required Widget child,
  }) {
    return ProviderScope(
      overrides: [
        authSecureStorageProvider.overrideWithValue(authSecureStorage),
        authRepositoryProvider.overrideWithValue(fakeRepository),
        if (initialAuthState != null)
          authNotifierProvider.overrideWith(
            () => _PreloadedAuthNotifier(initialAuthState),
          ),
      ],
      child: MaterialApp(
        home: Scaffold(body: child),
      ),
    );
  }

  group('AccountProfileCard Widget', () {
    testWidgets('renders Guest mode details and sign-in action buttons when unauthenticated',
        (tester) async {
      await tester.pumpWidget(
        buildTestableWidget(
          initialAuthState: AuthState.unauthenticated,
          child: const AccountProfileCard(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Guest Mode'), findsOneWidget);
      expect(find.text('GUEST'), findsOneWidget);
      expect(find.text('Browsing as local guest'), findsOneWidget);
      expect(find.text('Sign In with Google'), findsOneWidget);
      expect(find.text('Admin PIN'), findsOneWidget);
    });

    testWidgets('renders Authenticated Viewer mode with blue badge and email',
        (tester) async {
      const viewerState = AuthState(
        status: AuthStatus.authenticated,
        identity: UserIdentity(
          id: 5,
          email: 'viewer@gmail.com',
          name: 'Jane Viewer',
          role: 'viewer',
          isAdmin: false,
        ),
        sessionToken: 'sess_viewer_123',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          initialAuthState: viewerState,
          child: const AccountProfileCard(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Jane Viewer'), findsOneWidget);
      expect(find.text('viewer@gmail.com'), findsOneWidget);
      expect(find.text('VIEWER'), findsOneWidget);
      expect(find.byIcon(Icons.logout_rounded), findsOneWidget);
      expect(find.text('Sign In with Google'), findsNothing);
    });

    testWidgets('renders Authenticated Admin mode with red ADMIN badge',
        (tester) async {
      const adminState = AuthState(
        status: AuthStatus.authenticated,
        identity: UserIdentity(
          id: 1,
          email: 'admin@media.server',
          name: 'SysAdmin',
          role: 'admin',
          isAdmin: true,
        ),
        sessionToken: 'sess_admin_123',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          initialAuthState: adminState,
          child: const AccountProfileCard(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('SysAdmin'), findsOneWidget);
      expect(find.text('admin@media.server'), findsOneWidget);
      expect(find.text('ADMIN'), findsOneWidget);
      expect(find.byIcon(Icons.logout_rounded), findsOneWidget);
    });

    testWidgets('tapping logout button triggers sign-out and wipes session',
        (tester) async {
      const adminState = AuthState(
        status: AuthStatus.authenticated,
        identity: UserIdentity(
          id: 1,
          email: 'admin@media.server',
          name: 'SysAdmin',
          role: 'admin',
          isAdmin: true,
        ),
        sessionToken: 'sess_admin_123',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          initialAuthState: adminState,
          child: const AccountProfileCard(),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Sign out icon
      await tester.tap(find.byIcon(Icons.logout_rounded));
      await tester.pumpAndSettle();

      // Should transition back to Guest mode
      expect(find.text('Guest Mode'), findsOneWidget);
      expect(find.text('GUEST'), findsOneWidget);
    });
  });
}

class _PreloadedAuthNotifier extends AuthNotifier {
  final AuthState _initial;

  _PreloadedAuthNotifier(this._initial);

  @override
  AuthState build() => _initial;
}
