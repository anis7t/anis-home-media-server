import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_endpoints.dart';
import '../../../core/errors/app_exception.dart';
import '../domain/models/user_identity.dart';
import 'auth_secure_storage.dart';

/// Repository coordinating remote authentication endpoints and token persistence.
class AuthRepository {
  final ApiClient apiClient;
  final AuthSecureStorage secureStorage;

  AuthRepository({
    required this.apiClient,
    required this.secureStorage,
  });

  /// Queries `/api/auth/me` to hydrate the active caller's identity.
  Future<UserIdentity> getMe() async {
    try {
      final response = await apiClient.dio.get(ApiEndpoints.authMe);
      if (response.data is Map<String, dynamic>) {
        return UserIdentity.fromAccountJson(response.data as Map<String, dynamic>);
      }
      return UserIdentity.guest;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        return UserIdentity.guest;
      }
      rethrow;
    } catch (e) {
      debugPrint('[AuthRepository] getMe error: $e');
      return UserIdentity.guest;
    }
  }

  /// Authenticates using the configured server-side Admin PIN via `POST /api/auth/login-pin`.
  ///
  /// Extracts the minted `session_token` from the response body or `Set-Cookie` header,
  /// saves it to hardware-backed secure storage, and returns the authenticated user identity.
  Future<({UserIdentity identity, String sessionToken})> loginWithPin(String pin) async {
    final cleanPin = pin.trim();
    if (cleanPin.isEmpty) {
      throw const ValidationException('Please enter the Admin PIN');
    }

    try {
      final response = await apiClient.dio.post(
        ApiEndpoints.loginPin,
        data: {'pin': cleanPin},
      );

      final data = response.data is Map<String, dynamic>
          ? response.data as Map<String, dynamic>
          : <String, dynamic>{};

      // Extract session token from JSON or Set-Cookie header
      String? sessionToken = data['session_token'] as String?;
      if (sessionToken == null || sessionToken.isEmpty) {
        final setCookie = response.headers['set-cookie'];
        if (setCookie != null) {
          for (final header in setCookie) {
            final match = RegExp(r'session_token=([^;]+)').firstMatch(header);
            if (match != null) {
              sessionToken = match.group(1);
              break;
            }
          }
        }
      }

      if (sessionToken == null || sessionToken.isEmpty) {
        throw const ServerException(
          'Server did not return a session token upon PIN login',
        );
      }

      // Persist session token securely
      await secureStorage.saveSessionToken(sessionToken);

      final identity = UserIdentity.fromLoginPinJson(data);
      return (identity: identity, sessionToken: sessionToken);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        throw const UnauthorizedException('Invalid Admin PIN. Please try again.');
      }
      rethrow;
    }
  }

  /// Verifies an Admin PIN without minting a full session token via `POST /api/admin/verify-pin`.
  Future<bool> verifyAdminPin(String pin) async {
    final cleanPin = pin.trim();
    if (cleanPin.isEmpty) return false;

    try {
      final response = await apiClient.dio.post(
        '/api/admin/verify-pin',
        data: {'pin': cleanPin, 'admin_pin': cleanPin},
      );
      if (response.data is Map<String, dynamic>) {
        final data = response.data as Map<String, dynamic>;
        return data['success'] == true && data['admin'] == true;
      }
      return false;
    } catch (e) {
      debugPrint('[AuthRepository] verifyAdminPin failed: $e');
      return false;
    }
  }

  /// Logs out the user remotely and purges stored local session credentials.
  Future<void> logout() async {
    try {
      await apiClient.dio.post(ApiEndpoints.logout);
    } catch (e) {
      debugPrint('[AuthRepository] Remote logout failed (proceeding to local wipe): $e');
    } finally {
      await secureStorage.clearAll();
    }
  }
}
