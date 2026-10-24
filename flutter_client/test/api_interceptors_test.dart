import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/constants/storage_keys.dart';
import 'package:media_server_client/core/errors/app_exception.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';

class MockSecureStorage extends FlutterSecureStorage {
  final Map<String, String> memory = {};

  MockSecureStorage([Map<String, String>? initial]) {
    if (initial != null) memory.addAll(initial);
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
  }) async =>
      memory[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
  }) async {
    if (value != null) {
      memory[key] = value;
    } else {
      memory.remove(key);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceAuthInterceptor', () {
    test('Injects X-Device-Id, User-Agent, and Accept headers into RequestOptions', () async {
      const fixedDevId = 'dev_1122334455667788';
      final mockStorage = MockSecureStorage({
        StorageKeys.deviceId: fixedDevId,
      });

      final deviceService = DeviceIdentityService(
        secureStorage: mockStorage,
      );

      final interceptor = DeviceAuthInterceptor(deviceService);

      final options = RequestOptions(path: '/api/system-status');
      final handler = RequestInterceptorHandler();

      // Trigger onRequest interceptor
      await interceptor.onRequest(options, handler);

      // Verify injected headers
      expect(options.headers['X-Device-Id'], equals(fixedDevId));
      expect(options.headers['User-Agent'], contains('MediaServer-Flutter/1.0'));
      expect(options.headers['Accept'], equals('application/json'));
    });

    test('Maps DioException to AppException on error', () {
      final mockStorage = MockSecureStorage();
      final deviceService = DeviceIdentityService(
        secureStorage: mockStorage,
      );
      final interceptor = DeviceAuthInterceptor(deviceService);

      final reqOptions = RequestOptions(
        path: '/api/system-status',
        baseUrl: 'http://127.0.0.1:8000',
      );

      final connectionErr = DioException(
        requestOptions: reqOptions,
        type: DioExceptionType.connectionError,
        message: 'Connection refused',
      );

      final handler = TestErrorHandler();
      interceptor.onError(connectionErr, handler);

      expect(handler.capturedError?.error, isA<NetworkException>());
      expect(
        (handler.capturedError?.error as NetworkException).message,
        contains('Unable to reach media server'),
      );
    });
  });
}

class TestErrorHandler extends ErrorInterceptorHandler {
  DioException? capturedError;

  @override
  void next(DioException err) {
    capturedError = err;
  }
}
