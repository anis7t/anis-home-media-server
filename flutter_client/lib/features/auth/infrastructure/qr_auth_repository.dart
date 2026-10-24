import 'package:dio/dio.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_endpoints.dart';
import '../../../core/errors/app_exception.dart';
import '../domain/models/qr_pair_session.dart';
import 'auth_secure_storage.dart';

/// Repository coordinating remote QR authentication and device pairing workflows.
class QrAuthRepository {
  final ApiClient apiClient;
  final AuthSecureStorage secureStorage;

  const QrAuthRepository({
    required this.apiClient,
    required this.secureStorage,
  });

  /// Extracts a named cookie value from a list of `Set-Cookie` header strings.
  String? _extractCookie(List<String>? setCookieHeaders, String cookieName) {
    if (setCookieHeaders == null) return null;
    final regex = RegExp('$cookieName=([^;]+)');
    for (final header in setCookieHeaders) {
      final match = regex.firstMatch(header);
      if (match != null) {
        return match.group(1);
      }
    }
    return null;
  }

  /// Creates a new QR pairing session for display on TV or web.
  ///
  /// Calls `POST /api/auth/qr` and extracts the path-scoped `ms_qr_secret` proof cookie.
  Future<QrPairSession> createPairSession() async {
    try {
      final response = await apiClient.dio.post(ApiEndpoints.qrSession);
      final data = response.data is Map<String, dynamic>
          ? response.data as Map<String, dynamic>
          : <String, dynamic>{};

      final secret = _extractCookie(response.headers['set-cookie'], 'ms_qr_secret');
      return QrPairSession.fromJson(data, secret: secret);
    } on DioException catch (e) {
      throw AppException(
        e.message ?? 'Failed to initialize QR pairing session',
        statusCode: e.response?.statusCode ?? 500,
      );
    }
  }

  /// Polls the status of an active pairing session (`GET /api/auth/qr/{id}/status`).
  Future<QrPairStatus> getPairStatus(String qrId) async {
    try {
      final response = await apiClient.dio.get(ApiEndpoints.qrStatus(qrId));
      final data = response.data is Map<String, dynamic>
          ? response.data as Map<String, dynamic>
          : <String, dynamic>{};

      return QrPairStatus.fromString(data['status'] as String?);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return QrPairStatus.expired;
      }
      throw AppException(
        e.message ?? 'Failed to query pairing status',
        statusCode: e.response?.statusCode ?? 500,
      );
    }
  }

  /// Finalizes the pairing session on the waiting TV (`GET /api/auth/qr/{id}/finalize`).
  ///
  /// Proves ownership using the `ms_qr_secret` cookie, extracts the issued `session_token`,
  /// saves it to hardware-backed secure storage, and returns the token.
  Future<String> finalizePairSession(String qrId, String? secret) async {
    try {
      final headers = <String, dynamic>{};
      if (secret != null && secret.isNotEmpty) {
        headers['Cookie'] = 'ms_qr_secret=$secret';
      }

      final response = await apiClient.dio.get(
        ApiEndpoints.qrFinalize(qrId),
        options: Options(
          headers: headers,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final sessionToken = _extractCookie(response.headers['set-cookie'], 'session_token');
      if (sessionToken == null || sessionToken.isEmpty) {
        throw const ServerException('Server did not return a session token upon finalize');
      }

      await secureStorage.saveSessionToken(sessionToken);
      return sessionToken;
    } on DioException catch (e) {
      throw AppException(
        e.message ?? 'Failed to finalize pairing session',
        statusCode: e.response?.statusCode ?? 500,
      );
    }
  }

  /// Resolves a 5-character pairing code entered on a phone (`POST /api/auth/qr/lookup`).
  Future<QrLookupResult> lookupPairCode(String code) async {
    final cleanCode = code.trim().toUpperCase();
    if (cleanCode.length != 5) {
      throw const ValidationException('Pairing code must be 5 characters');
    }

    try {
      final response = await apiClient.dio.post(
        ApiEndpoints.qrLookup,
        data: {'code': cleanCode},
      );

      final data = response.data is Map<String, dynamic>
          ? response.data as Map<String, dynamic>
          : <String, dynamic>{};

      return QrLookupResult.fromJson(data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw const UnauthorizedException(
          'You must be signed in on your phone before pairing a TV',
        );
      }
      if (e.response?.statusCode == 404) {
        throw const ValidationException(
          'Pairing code not found or expired. Please check your TV screen.',
        );
      }
      throw AppException(
        e.message ?? 'Failed to verify pairing code',
        statusCode: e.response?.statusCode ?? 500,
      );
    }
  }

  /// Confirms pairing from a phone (`POST /api/auth/qr/{id}/confirm`).
  Future<bool> confirmPairSession({
    required String qrId,
    required String deviceName,
    String? code,
    String? sig,
  }) async {
    final cleanName = deviceName.trim();
    if (cleanName.isEmpty) {
      throw const ValidationException('Please enter a name for this device');
    }

    try {
      final payload = <String, dynamic>{
        'device_name': cleanName,
        if (code != null && code.isNotEmpty) 'code': code.trim().toUpperCase(),
        if (sig != null && sig.isNotEmpty) 'sig': sig,
      };

      final response = await apiClient.dio.post(
        ApiEndpoints.qrConfirm(qrId),
        data: payload,
      );

      return response.statusCode == 200;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw const UnauthorizedException(
          'You must be signed in on your phone to complete pairing',
        );
      }
      throw AppException(
        e.message ?? 'Failed to confirm device pairing',
        statusCode: e.response?.statusCode ?? 500,
      );
    }
  }
}
