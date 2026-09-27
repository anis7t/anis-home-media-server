import 'dart:io' show Platform;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../errors/app_exception.dart';
import '../storage/device_identity_service.dart';

/// Builds the client's User-Agent string.
///
/// The server classifies devices from this string (`parse_user_agent`): it reads
/// the version out of `Android <ver>` and only reports a phone when it also sees
/// a `Mobile` token - without it the Android client shows up in the Connected
/// Devices dashboard as "Android Tablet". Keep both tokens when adding
/// platforms.
@visibleForTesting
String buildClientUserAgent({
  required bool isWeb,
  required String platformName,
  required String operatingSystemVersion,
}) {
  if (!isWeb && platformName == 'Android') {
    // `Platform.operatingSystemVersion` on Android is not guaranteed to carry an
    // "Android <ver>" prefix (API 36 reports "16, API level 36"), so take the
    // first version-looking number anywhere in the string.
    final match =
        RegExp(r'([0-9]+(?:\.[0-9]+)*)').firstMatch(operatingSystemVersion);
    final version = match?.group(1);
    return version == null
        ? 'MediaServer-Flutter/1.0 (Android; Mobile; Dart)'
        : 'MediaServer-Flutter/1.0 (Android $version; Mobile; Dart)';
  }
  return 'MediaServer-Flutter/1.0 ($platformName; Dart)';
}

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

      options.headers['User-Agent'] = buildClientUserAgent(
        isWeb: kIsWeb,
        platformName: platformStr,
        operatingSystemVersion: kIsWeb ? '' : Platform.operatingSystemVersion,
      );
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
