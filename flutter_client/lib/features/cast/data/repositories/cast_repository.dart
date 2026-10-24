import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_client.dart';
import '../../../../core/errors/app_exception.dart';
import '../../../../core/storage/settings_service.dart';
import '../models/cast_device.dart';

/// Network access to the server's casting API.
///
/// The server does the protocol work (SSDP for DLNA, mDNS/CastV2 for Chromecast),
/// so this only moves small JSON payloads. A device is addressed by the id the
/// server handed out - never by an address the app invents.
class CastRepository {
  final ApiClient _apiClient;
  final SettingsService? _settingsService;

  CastRepository(this._apiClient, [this._settingsService]);

  Dio get _dio => _apiClient.dio;

  Future<void> _ensureBaseUrl() async {
    if (_settingsService != null) {
      final savedUrl = await _settingsService.getServerBaseUrl();
      if (savedUrl.isNotEmpty && _dio.options.baseUrl != savedUrl) {
        _apiClient.updateBaseUrl(savedUrl);
      }
    }
  }

  /// Devices on the network. [refresh] asks the server for a new scan.
  Future<CastDiscovery> discover({bool refresh = false}) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.get(
        '/api/cast/devices',
        queryParameters: refresh ? {'refresh': '1'} : null,
      );
      if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
        return CastDiscovery.fromJson(response.data as Map<String, dynamic>);
      }
      throw ServerException('Unexpected response from /api/cast/devices', statusCode: response.statusCode);
    } on DioException catch (e) {
      throw NetworkException(_messageFor(e, 'Could not list cast devices'));
    }
  }

  /// Asks a device to play [filename]. The server builds the URL it hands over.
  Future<void> play({required String deviceId, required String filename, Duration? position}) async {
    await _ensureBaseUrl();
    try {
      final payload = <String, dynamic>{'device_id': deviceId, 'filename': filename};
      if (position != null) payload['position'] = position.inMilliseconds / 1000.0;
      final response = await _dio.post('/api/cast/play', data: payload);
      _requireOk(response);
    } on DioException catch (e) {
      throw ServerException(_messageFor(e, 'Could not start casting'), statusCode: e.response?.statusCode);
    }
  }

  /// play / pause / stop / seek / volume.
  Future<void> control({required String deviceId, required String action, double? value}) async {
    await _ensureBaseUrl();
    try {
      final payload = <String, dynamic>{'device_id': deviceId, 'action': action};
      if (value != null) payload['value'] = value;
      final response = await _dio.post('/api/cast/control', data: payload);
      _requireOk(response);
    } on DioException catch (e) {
      throw ServerException(_messageFor(e, 'Device did not accept $action'), statusCode: e.response?.statusCode);
    }
  }

  Future<CastPlaybackStatus?> status(String deviceId) async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.get('/api/cast/status', queryParameters: {'device_id': deviceId});
      final data = response.data;
      if (response.statusCode == 200 && data is Map<String, dynamic> && data['ok'] == true) {
        return CastPlaybackStatus.fromJson(data);
      }
      return null;
    } on DioException {
      return null;
    }
  }

  void _requireOk(Response response) {
    final data = response.data;
    if (response.statusCode == 200 && data is Map && data['ok'] == true) return;
    final message = (data is Map ? data['error']?.toString() : null) ?? 'Cast request failed';
    throw ServerException(message, statusCode: response.statusCode);
  }

  /// The server answers failures with `{"ok": false, "error": "..."}`; surface that
  /// text because it is the actionable part (e.g. "Chromecast cannot play .mkv ...").
  String _messageFor(DioException e, String fallback) {
    final data = e.response?.data;
    if (data is Map && data['error'] != null) return data['error'].toString();
    return e.message ?? fallback;
  }
}

final castRepositoryProvider = Provider<CastRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final settingsService = ref.watch(settingsServiceProvider);
  return CastRepository(apiClient, settingsService);
});
