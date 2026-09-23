import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/storage_keys.dart';

/// Cryptographically secure device identity service.
///
/// Invariants:
/// 1. Device ID is formatted as `dev_<16 lowercase hex>` generated via [Random.secure()].
/// 2. Device ID is persisted across application restarts and reused on all subsequent requests.
class DeviceIdentityService {
  final FlutterSecureStorage _secureStorage;
  final SharedPreferences? _sharedPreferences;

  String? _cachedDeviceId;

  /// Regex validating the canonical `dev_<16 lowercase hex>` format.
  static final RegExp deviceIdRegex = RegExp(r'^dev_[0-9a-f]{16}$');

  DeviceIdentityService({
    FlutterSecureStorage? secureStorage,
    this._sharedPreferences,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  Future<SharedPreferences?> _getPrefs() async {
    if (_sharedPreferences != null) return _sharedPreferences;
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  /// Validates whether a given string matches the required `dev_<16 lowercase hex>` format.
  static bool isValidDeviceId(String? id) {
    if (id == null) return false;
    return deviceIdRegex.hasMatch(id);
  }

  /// Generates a cryptographically secure device ID using [Random.secure()].
  /// Produces 8 random bytes -> 16 lowercase hex characters prefixed with `dev_`.
  /// Never truncates a UUID.
  static String generateSecureDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'dev_$hex';
  }

  /// Returns the existing persisted device ID, or generates and stores a new one.
  Future<String> getOrCreateDeviceId() async {
    if (_cachedDeviceId != null && isValidDeviceId(_cachedDeviceId)) {
      return _cachedDeviceId!;
    }

    String? storedId;

    // 1. Attempt reading from secure storage first
    try {
      storedId = await _secureStorage.read(key: StorageKeys.deviceId);
    } catch (e) {
      debugPrint('[DeviceIdentityService] Secure storage read failed: $e');
    }

    // 2. Fall back to SharedPreferences if secure storage was empty or failed
    if (!isValidDeviceId(storedId)) {
      try {
        final prefs = await _getPrefs();
        if (prefs != null) {
          storedId = prefs.getString(StorageKeys.deviceId);
        }
      } catch (e) {
        debugPrint('[DeviceIdentityService] SharedPreferences read failed: $e');
      }
    }

    // 3. If an existing valid device ID was found, cache and mirror it
    if (isValidDeviceId(storedId)) {
      _cachedDeviceId = storedId;
      await _persistDeviceId(storedId!);
      return storedId;
    }

    // 4. Generate a new cryptographically secure device ID
    final newId = generateSecureDeviceId();
    _cachedDeviceId = newId;
    await _persistDeviceId(newId);
    return newId;
  }

  /// Persists the device ID to both secure storage and SharedPreferences.
  Future<void> _persistDeviceId(String deviceId) async {
    try {
      await _secureStorage.write(key: StorageKeys.deviceId, value: deviceId);
    } catch (e) {
      debugPrint('[DeviceIdentityService] Secure storage write failed: $e');
    }

    try {
      final prefs = await _getPrefs();
      if (prefs != null) {
        await prefs.setString(StorageKeys.deviceId, deviceId);
      }
    } catch (e) {
      debugPrint('[DeviceIdentityService] SharedPreferences write failed: $e');
    }
  }

  /// Clears the stored device ID (used primarily for test fixtures and resets).
  Future<void> clearDeviceId() async {
    _cachedDeviceId = null;
    try {
      await _secureStorage.delete(key: StorageKeys.deviceId);
    } catch (_) {}
    try {
      final prefs = await _getPrefs();
      if (prefs != null) {
        await prefs.remove(StorageKeys.deviceId);
      }
    } catch (_) {}
  }
}
