import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../storage/settings_service.dart';
import 'api_endpoints.dart';
import 'api_interceptors.dart';

class ConnectionTestResult {
  final bool success;
  final int latencyMs;
  final String? serverVersion;
  final String? hostname;
  final String? status;
  final String? errorMessage;
  final Map<String, dynamic>? data;

  const ConnectionTestResult({
    required this.success,
    required this.latencyMs,
    this.serverVersion,
    this.hostname,
    this.status,
    this.errorMessage,
    this.data,
  });
}

class ApiClient {
  final Dio dio;

  ApiClient({
    required String baseUrl,
    required DeviceAuthInterceptor authInterceptor,
    Dio? customDio,
  }) : dio = customDio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: const Duration(seconds: 5),
                receiveTimeout: const Duration(seconds: 5),
                sendTimeout: const Duration(seconds: 5),
              ),
            ) {
    dio.interceptors.add(authInterceptor);
  }

  void updateBaseUrl(String newBaseUrl) {
    dio.options.baseUrl = newBaseUrl;
  }

  /// Tests connectivity to the media server by querying `/api/system-status`.
  Future<ConnectionTestResult> testConnection({String? overrideUrl}) async {
    final sw = Stopwatch()..start();
    final targetUrl = SettingsService.sanitizeUrl(overrideUrl ?? dio.options.baseUrl);

    try {
      final response = await dio.get(
        '$targetUrl${ApiEndpoints.systemStatus}',
        options: Options(
          sendTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 4),
        ),
      );

      sw.stop();

      if (response.statusCode == 200 && response.data is Map) {
        final data = response.data as Map<String, dynamic>;
        return ConnectionTestResult(
          success: true,
          latencyMs: sw.elapsedMilliseconds,
          serverVersion: data['version']?.toString() ?? '1.0',
          hostname: data['hostname']?.toString() ?? 'MediaServer Host',
          status: data['status']?.toString() ?? 'online',
          data: data,
        );
      } else {
        return ConnectionTestResult(
          success: false,
          latencyMs: sw.elapsedMilliseconds,
          errorMessage: 'Unexpected response (${response.statusCode})',
        );
      }
    } on DioException catch (e) {
      sw.stop();
      final message = e.error?.toString() ?? e.message ?? 'Connection failed';
      return ConnectionTestResult(
        success: false,
        latencyMs: sw.elapsedMilliseconds,
        errorMessage: message,
      );
    } catch (e) {
      sw.stop();
      return ConnectionTestResult(
        success: false,
        latencyMs: sw.elapsedMilliseconds,
        errorMessage: e.toString(),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Riverpod Provider
// ---------------------------------------------------------------------------

final apiClientProvider = Provider<ApiClient>((ref) {
  final deviceService = ref.watch(deviceIdentityServiceProvider);
  final authInterceptor = DeviceAuthInterceptor(deviceService);

  return ApiClient(
    baseUrl: SettingsService.defaultServerUrl,
    authInterceptor: authInterceptor,
  );
});

/// Exposes the active server base URL for image/media URL resolution.
final serverBaseUrlProvider = Provider<String>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return apiClient.dio.options.baseUrl;
});
