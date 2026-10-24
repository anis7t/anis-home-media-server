import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_endpoints.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/errors/app_exception.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/features/auth/domain/models/qr_pair_session.dart';
import 'package:media_server_client/features/auth/infrastructure/auth_secure_storage.dart';
import 'package:media_server_client/features/auth/infrastructure/qr_auth_repository.dart';
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

  group('QrAuthRepository', () {
    test('createPairSession creates session and captures ms_qr_secret cookie', () async {
      final apiClient = createMockApiClient((options) async {
        expect(options.path, equals(ApiEndpoints.qrSession));
        expect(options.method, equals('POST'));
        return Response(
          requestOptions: options,
          statusCode: 200,
          headers: Headers.fromMap({
            'set-cookie': [
              'ms_qr_secret=secret-proof-123; Path=/api/auth/qr/qr-session-1; HttpOnly; SameSite=Lax',
            ],
          }),
          data: {
            'qr_id': 'qr-session-1',
            'code': 'K9X2P',
            'sig': 'hmac-signature-abc',
            'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120,
            'qr_url': 'http://127.0.0.1:8000/remotelogin?qr_id=qr-session-1&code=K9X2P&sig=hmac-signature-abc',
            'login_url': 'http://127.0.0.1:8000/remotelogin',
          },
        );
      });

      final repository = QrAuthRepository(
        apiClient: apiClient,
        secureStorage: authSecureStorage,
      );

      final session = await repository.createPairSession();
      expect(session.qrId, equals('qr-session-1'));
      expect(session.code, equals('K9X2P'));
      expect(session.secret, equals('secret-proof-123'));
      expect(session.isExpired, isFalse);
      expect(session.remainingSeconds, greaterThan(0));
    });

    test('getPairStatus returns correct QrPairStatus enum', () async {
      final apiClient = createMockApiClient((options) async {
        expect(options.path, equals(ApiEndpoints.qrStatus('session-99')));
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {'status': 'confirmed'},
        );
      });

      final repository = QrAuthRepository(
        apiClient: apiClient,
        secureStorage: authSecureStorage,
      );

      final status = await repository.getPairStatus('session-99');
      expect(status, equals(QrPairStatus.confirmed));
    });

    test('getPairStatus returns QrPairStatus.expired on 404 response', () async {
      final apiClient = createMockApiClient((options) async {
        throw DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 404),
        );
      });

      final repository = QrAuthRepository(
        apiClient: apiClient,
        secureStorage: authSecureStorage,
      );

      final status = await repository.getPairStatus('expired-session');
      expect(status, equals(QrPairStatus.expired));
    });

    test('finalizePairSession passes ms_qr_secret and extracts session token', () async {
      final apiClient = createMockApiClient((options) async {
        expect(options.path, equals(ApiEndpoints.qrFinalize('session-final')));
        expect(options.headers['Cookie'], equals('ms_qr_secret=secret-proof-123'));
        return Response(
          requestOptions: options,
          statusCode: 307,
          headers: Headers.fromMap({
            'set-cookie': [
              'session_token=tv-session-token-xyz; Path=/; HttpOnly; SameSite=Lax',
            ],
          }),
        );
      });

      final repository = QrAuthRepository(
        apiClient: apiClient,
        secureStorage: authSecureStorage,
      );

      final token = await repository.finalizePairSession('session-final', 'secret-proof-123');
      expect(token, equals('tv-session-token-xyz'));
      final savedToken = await authSecureStorage.getSessionToken();
      expect(savedToken, equals('tv-session-token-xyz'));
    });

    test('lookupPairCode validates 5-character length and returns QrLookupResult', () async {
      final apiClient = createMockApiClient((options) async {
        expect(options.path, equals(ApiEndpoints.qrLookup));
        expect(options.data, equals({'code': 'ABC12'}));
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'qr_id': 'resolved-qr-id',
            'code': 'ABC12',
          },
        );
      });

      final repository = QrAuthRepository(
        apiClient: apiClient,
        secureStorage: authSecureStorage,
      );

      final result = await repository.lookupPairCode('abc12');
      expect(result.qrId, equals('resolved-qr-id'));
      expect(result.code, equals('ABC12'));

      // Rejects invalid length
      expect(() => repository.lookupPairCode('123'), throwsA(isA<ValidationException>()));
    });

    test('confirmPairSession validates device name and posts confirmation', () async {
      final apiClient = createMockApiClient((options) async {
        expect(options.path, equals(ApiEndpoints.qrConfirm('target-qr-id')));
        expect(options.data['device_name'], equals('Living Room Fire TV'));
        expect(options.data['code'], equals('ABC12'));
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {'success': true},
        );
      });

      final repository = QrAuthRepository(
        apiClient: apiClient,
        secureStorage: authSecureStorage,
      );

      final ok = await repository.confirmPairSession(
        qrId: 'target-qr-id',
        deviceName: 'Living Room Fire TV',
        code: 'abc12',
      );
      expect(ok, isTrue);

      // Rejects empty device name
      expect(
        () => repository.confirmPairSession(qrId: 'target-qr-id', deviceName: '  '),
        throwsA(isA<ValidationException>()),
      );
    });
  });
}
