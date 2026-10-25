import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/constants/storage_keys.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/features/auth/data/auth_secure_storage.dart';
import 'auth_secure_storage_test.dart';

class TestErrorHandler extends ErrorInterceptorHandler {
  DioException? capturedError;

  @override
  void next(DioException err) {
    capturedError = err;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceAuthInterceptor Auth Injection', () {
    test('Injects Cookie and X-Admin-Pin headers when present in secure storage', () async {
      const fixedDevId = 'dev_1122334455667788';
      const fixedToken = 'sess_xyz123456';
      const fixedPin = '4321';

      final mockStorage = MockSecureStorage({
        StorageKeys.deviceId: fixedDevId,
        StorageKeys.sessionToken: fixedToken,
        StorageKeys.adminPin: fixedPin,
      });

      final deviceService = DeviceIdentityService(secureStorage: mockStorage);
      final authStorage = AuthSecureStorage(secureStorage: mockStorage);

      final interceptor = DeviceAuthInterceptor(
        deviceService,
        secureStorage: authStorage,
      );

      final options = RequestOptions(path: '/api/auth/me');
      final handler = RequestInterceptorHandler();

      await interceptor.onRequest(options, handler);

      expect(options.headers['X-Device-Id'], equals(fixedDevId));
      expect(options.headers['Cookie'], equals('session_token=$fixedToken'));
      expect(options.headers['X-Admin-Pin'], equals(fixedPin));
    });

    test('Preserves existing cookies when appending session_token cookie', () async {
      final mockStorage = MockSecureStorage({
        StorageKeys.sessionToken: 'sess_token_abc',
      });

      final deviceService = DeviceIdentityService(secureStorage: mockStorage);
      final authStorage = AuthSecureStorage(secureStorage: mockStorage);

      final interceptor = DeviceAuthInterceptor(
        deviceService,
        secureStorage: authStorage,
      );

      final options = RequestOptions(
        path: '/api/auth/me',
        headers: {'Cookie': 'custom_pref=dark'},
      );
      final handler = RequestInterceptorHandler();

      await interceptor.onRequest(options, handler);

      expect(
        options.headers['Cookie'],
        equals('custom_pref=dark; session_token=sess_token_abc'),
      );
    });

    test('Invokes onUnauthorized callback when response status is 401', () {
      final mockStorage = MockSecureStorage();
      final deviceService = DeviceIdentityService(secureStorage: mockStorage);

      bool unauthorizedTriggered = false;
      final interceptor = DeviceAuthInterceptor(
        deviceService,
        onUnauthorized: () {
          unauthorizedTriggered = true;
        },
      );

      final reqOptions = RequestOptions(path: '/api/protected');
      final dioErr = DioException(
        requestOptions: reqOptions,
        response: Response(
          requestOptions: reqOptions,
          statusCode: 401,
          statusMessage: 'Unauthorized',
        ),
        type: DioExceptionType.badResponse,
      );

      final handler = TestErrorHandler();
      interceptor.onError(dioErr, handler);

      expect(unauthorizedTriggered, isTrue);
    });
  });
}
