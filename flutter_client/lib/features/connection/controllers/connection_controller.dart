import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/storage/device_identity_service.dart';
import '../../../core/storage/settings_service.dart';
import '../models/connection_state.dart';

class ConnectionController extends Notifier<ServerConnectionState> {
  late final ApiClient _apiClient;
  late final SettingsService _settingsService;
  late final DeviceIdentityService _deviceIdentityService;

  @override
  ServerConnectionState build() {
    _apiClient = ref.watch(apiClientProvider);
    _settingsService = ref.watch(settingsServiceProvider);
    _deviceIdentityService = ref.watch(deviceIdentityServiceProvider);

    _initialize();

    return const ServerConnectionState(
      serverUrl: SettingsService.defaultServerUrl,
      deviceId: 'Loading...',
    );
  }

  Future<void> _initialize() async {
    final savedUrl = await _settingsService.getServerBaseUrl();
    final devId = await _deviceIdentityService.getOrCreateDeviceId();

    _apiClient.updateBaseUrl(savedUrl);

    state = state.copyWith(
      serverUrl: savedUrl,
      deviceId: devId,
    );
  }

  void updateUrl(String newUrl) {
    state = state.copyWith(
      serverUrl: newUrl,
      status: ConnectionStatus.untested,
      errorMessage: null,
    );
  }

  Future<void> testConnection() async {
    state = state.copyWith(
      status: ConnectionStatus.testing,
      errorMessage: null,
    );

    final result = await _apiClient.testConnection(
      overrideUrl: state.serverUrl,
    );

    if (result.success) {
      state = state.copyWith(
        status: ConnectionStatus.connected,
        latencyMs: result.latencyMs,
        serverVersion: result.serverVersion,
        hostname: result.hostname,
        errorMessage: null,
      );
    } else {
      state = state.copyWith(
        status: ConnectionStatus.failed,
        latencyMs: result.latencyMs,
        errorMessage: result.errorMessage ?? 'Connection failed',
      );
    }
  }

  Future<bool> saveSettings() async {
    state = state.copyWith(isSaving: true);
    try {
      await _settingsService.setServerBaseUrl(state.serverUrl);
      _apiClient.updateBaseUrl(state.serverUrl);
      state = state.copyWith(isSaving: false);
      return true;
    } catch (e) {
      state = state.copyWith(
        isSaving: false,
        errorMessage: 'Failed to save settings: $e',
      );
      return false;
    }
  }
}

final connectionControllerProvider =
    NotifierProvider<ConnectionController, ServerConnectionState>(() {
  return ConnectionController();
});
