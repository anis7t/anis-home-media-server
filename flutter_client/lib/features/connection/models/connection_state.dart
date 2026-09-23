enum ConnectionStatus {
  untested,
  testing,
  connected,
  failed,
}

class ServerConnectionState {
  final String serverUrl;
  final String deviceId;
  final ConnectionStatus status;
  final int? latencyMs;
  final String? serverVersion;
  final String? hostname;
  final String? errorMessage;
  final bool isSaving;

  const ServerConnectionState({
    required this.serverUrl,
    required this.deviceId,
    this.status = ConnectionStatus.untested,
    this.latencyMs,
    this.serverVersion,
    this.hostname,
    this.errorMessage,
    this.isSaving = false,
  });

  ServerConnectionState copyWith({
    String? serverUrl,
    String? deviceId,
    ConnectionStatus? status,
    int? latencyMs,
    String? serverVersion,
    String? hostname,
    String? errorMessage,
    bool? isSaving,
  }) {
    return ServerConnectionState(
      serverUrl: serverUrl ?? this.serverUrl,
      deviceId: deviceId ?? this.deviceId,
      status: status ?? this.status,
      latencyMs: latencyMs ?? this.latencyMs,
      serverVersion: serverVersion ?? this.serverVersion,
      hostname: hostname ?? this.hostname,
      errorMessage: errorMessage ?? this.errorMessage,
      isSaving: isSaving ?? this.isSaving,
    );
  }
}
