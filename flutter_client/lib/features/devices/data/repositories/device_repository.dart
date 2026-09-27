import 'package:dio/dio.dart';

import '../../../../core/api/api_client.dart';
import '../../../../core/api/api_endpoints.dart';
import '../../../../core/storage/settings_service.dart';

/// Client for the server's device-tracking endpoints.
///
/// The shared [Dio] already carries `X-Device-Id` (attached by
/// `DeviceAuthInterceptor`), which is what makes registration idempotent: the
/// server upserts on that id, so repeated heartbeats refresh one row instead of
/// creating duplicates.
class DeviceRepository {
  final ApiClient _apiClient;
  final SettingsService? _settingsService;

  DeviceRepository(this._apiClient, [this._settingsService]);

  Dio get _dio => _apiClient.dio;

  /// Points the client at the server the user actually saved.
  ///
  /// The same guard `LibraryRepository` uses: on a cold start the shared client
  /// still carries the default origin, so a heartbeat would be sent to
  /// `127.0.0.1` - i.e. to the phone itself - and the device would never appear
  /// in the dashboard.
  Future<void> _ensureBaseUrl() async {
    if (_settingsService == null) return;
    final savedUrl = await _settingsService.getServerBaseUrl();
    if (savedUrl.isNotEmpty && _dio.options.baseUrl != savedUrl) {
      _apiClient.updateBaseUrl(savedUrl);
    }
  }

  /// Sends one keepalive ping.
  ///
  /// Returns true when the server acknowledged it. Failures are swallowed on
  /// purpose: presence tracking is telemetry and must never disturb playback or
  /// surface errors to the viewer.
  Future<bool> sendHeartbeat() async {
    try {
      await _ensureBaseUrl();
      final res = await _dio.post<dynamic>(
        ApiEndpoints.deviceHeartbeat,
        options: Options(
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
