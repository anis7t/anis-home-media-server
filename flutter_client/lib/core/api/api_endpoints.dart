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
  static const String progress = '/api/progress';
  static const String scan = '/api/scan';
  static const String transcodeStart = '/api/transcode/start';
  static const String transcodeStatus = '/api/transcode-status';
  static const String appUpdate = '/api/app/update';
  static const String appDownload = '/api/app/download';

  // Authentication & Session
  static const String authMe = '/api/auth/me';
  static const String loginPin = '/api/auth/login-pin';
  static const String logout = '/auth/logout';

  // Remote Pairing / QR Login
  static const String qrSession = '/api/auth/qr';
  static const String qrLookup = '/api/auth/qr/lookup';
  static String qrStatus(String id) => '/api/auth/qr/$id/status';
  static String qrConfirm(String id) => '/api/auth/qr/$id/confirm';
  static String qrFinalize(String id) => '/api/auth/qr/$id/finalize';
  static String qrWait(String id) => '/api/auth/qr/$id/wait';
}

