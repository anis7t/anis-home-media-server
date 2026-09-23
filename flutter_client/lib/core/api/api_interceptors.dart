import 'dart:io' show Platform;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../errors/app_exception.dart';
import '../storage/device_identity_service.dart';

/// Interceptor that attaches the persistent device ID and client metadata to all requests.
class DeviceAuthInterceptor extends Interceptor {
  final DeviceIdentityService _deviceIdentityService;

  DeviceAuthInterceptor(this._deviceIdentityService);

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      final deviceId = await _deviceIdentityService.getOrCreateDeviceId();
      options.headers['X-Device-Id'] = deviceId;

      final platformStr = kIsWeb
          ? 'Web'
          : Platform.isWindows
              ? 'Windows'
              : Platform.isAndroid
                  ? 'Android'
                  : Platform.isIOS
                      ? 'iOS'
                      : Platform.isMacOS
                          ? 'macOS'
                          : Platform.isLinux
                              ? 'Linux'
                              : 'Unknown';

      options.headers['User-Agent'] =
          'MediaServer-Flutter/1.0 ($platformStr; Dart)';
      options.headers['Accept'] = 'application/json';
    } catch (e) {
      debugPrint('[DeviceAuthInterceptor] Failed to attach device identity: $e');
    }

    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    AppException exception;
    switch (err.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        exception = const NetworkException(
          'Connection timed out. Please check your network and server address.',
        );
        break;
      case DioExceptionType.connectionError:
        exception = NetworkException(
          'Unable to reach media server at ${err.requestOptions.baseUrl}. Is the server online?',
        );
        break;
      case DioExceptionType.badResponse:
        final status = err.response?.statusCode;
        final msg = err.response?.statusMessage ?? 'Server returned error';
        exception = ServerException(
          'Server error ($status): $msg',
          statusCode: status,
          details: err.response?.data,
        );
        break;
      default:
        exception = AppException(err.message ?? 'An unexpected error occurred');
    }

    handler.next(err.copyWith(error: exception));
  }
}
