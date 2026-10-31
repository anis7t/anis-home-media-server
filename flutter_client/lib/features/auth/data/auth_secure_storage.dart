import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/constants/storage_keys.dart';

/// Hardware-backed secure storage service for authentication credentials.
class AuthSecureStorage {
  final FlutterSecureStorage _secureStorage;
  final SharedPreferences? prefs;

  AuthSecureStorage({
    FlutterSecureStorage? secureStorage,
    this.prefs,
  })  : _secureStorage = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(),
            );

  /// Retrieves the active persistent session token.
  Future<String?> getSessionToken() async {
    try {
      final token = await _secureStorage.read(key: StorageKeys.sessionToken);
      if (token != null && token.isNotEmpty) {
        return token;
      }
    } catch (e) {
      debugPrint('[AuthSecureStorage] Failed to read session token from secure storage: $e');
    }

    // Fallback check in SharedPreferences in case secure storage failed
    try {
      final p = prefs ?? await SharedPreferences.getInstance();
      return p.getString(StorageKeys.sessionToken);
    } catch (_) {
      return null;
    }
  }

  /// Persists a session token to secure storage.
  Future<void> saveSessionToken(String token) async {
    try {
      await _secureStorage.write(key: StorageKeys.sessionToken, value: token);
    } catch (e) {
      debugPrint('[AuthSecureStorage] Failed to write session token to secure storage: $e');
      // Fallback to SharedPreferences
      try {
        final p = prefs ?? await SharedPreferences.getInstance();
        await p.setString(StorageKeys.sessionToken, token);
      } catch (_) {}
    }
  }

  /// Deletes the session token.
  Future<void> clearSessionToken() async {
    try {
      await _secureStorage.delete(key: StorageKeys.sessionToken);
    } catch (e) {
      debugPrint('[AuthSecureStorage] Failed to delete session token from secure storage: $e');
    }
    try {
      final p = prefs ?? await SharedPreferences.getInstance();
      await p.remove(StorageKeys.sessionToken);
    } catch (_) {}
  }

  /// Retrieves the stored Admin PIN. Deprecated: OTPs are never stored; always returns null.
  Future<String?> getAdminPin() async {
    return null;
  }

  /// Saves the Admin PIN. Deprecated: One-time access codes (OTP) are single-use and must never be persisted.
  Future<void> saveAdminPin(String pin) async {
    // No-op: Single-use OTPs are never persisted in secure storage.
  }

  /// Clears the stored Admin PIN.
  Future<void> clearAdminPin() async {
    try {
      await _secureStorage.delete(key: StorageKeys.adminPin);
    } catch (e) {
      debugPrint('[AuthSecureStorage] Failed to delete admin PIN: $e');
    }
  }

  /// Clears all authentication credentials.
  Future<void> clearAll() async {
    await clearSessionToken();
    await clearAdminPin();
  }
}
