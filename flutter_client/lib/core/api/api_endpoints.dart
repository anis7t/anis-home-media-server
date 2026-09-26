/// API endpoint constants for Anis' Home Media Server.
class ApiEndpoints {
  ApiEndpoints._();

  static const String systemStatus = '/api/system-status';
  static const String devices = '/api/devices';
  static const String deviceHeartbeat = '/api/devices/heartbeat';
  static const String deviceClientHints = '/api/devices/client-hints';
  static const String movies = '/api/movies';
  static const String movieDetails = '/api/movie';
  static const String mediaInfo = '/api/media-info';
  static const String scan = '/api/scan';
  static const String appUpdate = '/api/app/update';
  static const String appDownload = '/api/app/download';
}

