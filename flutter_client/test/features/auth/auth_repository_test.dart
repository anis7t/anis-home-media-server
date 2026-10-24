import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_endpoints.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/errors/app_exception.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/features/auth/infrastructure/auth_repository.dart';
import 'package:media_server_client/features/auth/infrastructure/auth_secure_storage.dart';
import 'auth_secure_storage_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSecureStorage mockSecureStorage;
  late AuthSecureStorage authSecureStorage;
  late DeviceIdentityService deviceService;
  late DeviceAuthInterceptor authInterceptor;

  setUp(() {
    mockSecureStorage = MockSecureStorage();
    authSecureStorage = AuthSecureStorage(secureStorage: mockSecureStorage);
    deviceService = DeviceIdentityService(secureStorage: mockSecureStorage);
    authInterceptor = DeviceAuthInterceptor(
      deviceService,
      secureStorage: authSecureStorage,
    );
  });

  ApiClient createMockApiClient(
    Future<Response<dynamic>> Function(RequestOptions options) handler,
  ) {
    final customDio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8000'));
    customDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, reqHandler) async {
          try {
            final res = await handler(options);
            reqHandler.resolve(res);
          } on DioException catch (e) {
            reqHandler.reject(e);
          } catch (e) {
            reqHandler.reject(DioException(requestOptions: options, error: e));
          }
        },
      ),
    );

    return ApiClient(
      baseUrl: 'http://127.0.0.1:8000',
      authInterceptor: authInterceptor,
      customDio: customDio,
    );
  }

  group('AuthRepository', () {
    test('getMe returns UserIdentity when authenticated', () async {
      final apiClient = createMockApiClient((options) async {
        expect(options.path, equals(ApiEndpoints.authMe));
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'authenticated': true,
            'email': 'admin@example.com',
            'name': 'Admin User',
            'picture': 'https://example.com/avatar.png',
            'role': 'admin',
            'is_admin': true,
            'oauth_configured': true,
          },
        );
      });

      final repository = AuthRepository(
        apiClient: apiClient,
        secureStorage: authSecureStorage,
      );

      final identity = await repository.getMe();

      expect(identity.email, equals('admin@example.com'));
      expect(identity.name, equals('Admin User'));
      expect(identity.pictureUrl, equals('https://example.com/avatar.png'));
      expect(identity.role, equals('admin'));
      expect(identity.isAdmin, isTrue);
      expect(identity.oauthConfigured, isTrue);
    });

    test('getMe returns UserIdentity.guest on 401 or unauthenticated response', () async {
      final apiClient = createMockApiClient((options) async {
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'authenticated': false,
            'email': null,
            'role': null,
            'is_admin': false,
          },
        );
      });

      final repository = AuthRepository(
        apiClient: apiClient,
        secureStorage: authSecureStorage,
      );

      final identity = await repository.getMe();
      expect(identity.role, equals('guest'));
      expect(identity.isAdmin, isFalse);
      expect(identity.email, isNull);
    });

    test('loginWithPin extracts session token and saves to secure storage', () async {
      const pin = '4321';
      const expectedToken = 'sess_pin_987654321';

      final apiClient = createMockApiClient((options) async {
        expect(options.path, equals(ApiEndpoints.loginPin));
        expect(options.data, equals({'pin': pin}));

        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'success': true,
            'session_token': expectedToken,
            'user': {
              'id': 1,
              'email': 'admin@localhost',
              'role': 'admin',
              'is_admin': true,
            },
          },
          headers: Headers.fromMap({
            'set-cookie': ['session_token=$expectedToken; Path=/; HttpOnly'],
          }),
        );
      });

      final repository = AuthRepository(
        apiClient: apiClient,
        secureStorage: authSecureStorage,
      );

      final result = await repository.loginWithPin(pin);

      expect(result.sessionToken, equals(expectedToken));
      expect(result.identity.isAdmin, isTrue);
      expect(result.identity.role, equals('admin'));

      // Check secure storage was updated
      final storedToken = await authSecureStorage.getSessionToken();
      expect(storedToken, equals(expectedToken));
    });

    test('loginWithPin throws ValidationException on empty input', () async {
      final apiClient = createMockApiClient((options) async {
        throw StateError('Should not be reached');
      });

      final repository = AuthRepository(
        apiClient: apiClient,
        secureStorage: authSecureStorage,
      );

      expect(
        () => repository.loginWithPin('   '),
        throwsA(isA<ValidationException>()),
      );
    });

    test('loginWithPin throws UnauthorizedException on 401 response', () async {
      final apiClient = createMockApiClient((options) async {
        throw DioException(
          requestOptions: options,
          response: Response(
            requestOptions: options,
            statusCode: 401,
            data: {'error': 'Invalid PIN'},
          ),
          type: DioExceptionType.badResponse,
        );
      });

      final repository = AuthRepository(
        apiClient: apiClient,
        secureStorage: authSecureStorage,
      );

      expect(
        () => repository.loginWithPin('wrong-pin'),
        throwsA(isA<UnauthorizedException>()),
      );
    });

    test('verifyAdminPin returns true when backend confirms', () async {
      final apiClient = createMockApiClient((options) async {
        expect(options.path, equals('/api/admin/verify-pin'));
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {'success': true, 'admin': true},
        );
      });

      final repository = AuthRepository(
        apiClient: apiClient,
        secureStorage: authSecureStorage,
      );

      final isAuthorized = await repository.verifyAdminPin('1234');
      expect(isAuthorized, isTrue);
    });

    test('logout calls remote endpoint and purges local secure storage', () async {
      await authSecureStorage.saveSessionToken('sess_to_delete');
      await authSecureStorage.saveAdminPin('pin_to_delete');

      bool logoutEndpointCalled = false;
      final apiClient = createMockApiClient((options) async {
        expect(options.path, equals(ApiEndpoints.logout));
        logoutEndpointCalled = true;
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {'success': true},
        );
      });

      final repository = AuthRepository(
        apiClient: apiClient,
        secureStorage: authSecureStorage,
      );

      await repository.logout();

      expect(logoutEndpointCalled, isTrue);
      expect(await authSecureStorage.getSessionToken(), isNull);
      expect(await authSecureStorage.getAdminPin(), isNull);
    });
  });
}
