import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/storage_keys.dart';
import '../models/app_channel.dart';
import 'device_identity_service.dart';

/// Service managing persistent application settings.
class SettingsService {
  final SharedPreferences? _prefs;

  static const String defaultServerUrl = 'https://media.anisparvez.in';

  SettingsService([this._prefs]);

  Future<SharedPreferences> _getPrefs() async {
    return _prefs ?? await SharedPreferences.getInstance();
  }

  /// Retrieves the saved server base URL, or returns the default.
  Future<String> getServerBaseUrl() async {
    try {
      final p = await _getPrefs();
      final saved = p.getString(StorageKeys.serverBaseUrl);
      if (saved != null && saved.trim().isNotEmpty) {
        final sanitized = sanitizeUrl(saved);
        // On mobile devices, localhost/127.0.0.1 is always unusable (server runs on host machine).
        // Automatically migrate legacy localhost defaults to the public internet endpoint.
        if (!kIsWeb &&
            Platform.isAndroid &&
            (sanitized == 'http://127.0.0.1:8000' ||
                sanitized == 'http://localhost:8000' ||
                sanitized == 'http://10.0.2.2:8000')) {
          await p.setString(StorageKeys.serverBaseUrl, defaultServerUrl);
          return defaultServerUrl;
        }
        return sanitized;
      }
    } catch (_) {}
    return defaultServerUrl;
  }

  /// Persists a new server base URL.
  Future<void> setServerBaseUrl(String url) async {
    final sanitized = sanitizeUrl(url);
    final p = await _getPrefs();
    await p.setString(StorageKeys.serverBaseUrl, sanitized);
  }

  /// Removes trailing slashes and normalizes http scheme if missing.
  static String sanitizeUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) {
      return defaultServerUrl;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// Retrieves the persisted update channel, or falls back to compile-time default.
  Future<AppChannel> getUpdateChannel() async {
    try {
      final p = await _getPrefs();
      final saved = p.getString(StorageKeys.updateChannel);
      if (saved != null && saved.trim().isNotEmpty) {
        return AppChannel.fromString(saved.trim());
      }
    } catch (_) {}
    return AppChannel.compileTimeDefault;
  }

  /// Persists the user's selected update channel.
  Future<void> setUpdateChannel(AppChannel channel) async {
    final p = await _getPrefs();
    await p.setString(StorageKeys.updateChannel, channel.id);
  }

  /// Retrieves the last update check timestamp.
  Future<DateTime?> getLastUpdateCheckTime() async {
    try {
      final p = await _getPrefs();
      final saved = p.getString(StorageKeys.lastUpdateCheckTime);
      if (saved != null && saved.trim().isNotEmpty) {
        return DateTime.tryParse(saved);
      }
    } catch (_) {}
    return null;
  }

  /// Persists the last update check timestamp.
  Future<void> setLastUpdateCheckTime(DateTime timestamp) async {
    final p = await _getPrefs();
    await p.setString(StorageKeys.lastUpdateCheckTime, timestamp.toUtc().toIso8601String());
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final deviceIdentityServiceProvider = Provider<DeviceIdentityService>((ref) {
  return DeviceIdentityService();
});

final settingsServiceProvider = Provider<SettingsService>((ref) {
  return SettingsService();
});

/// Asynchronously loads and provides the persistent device ID.
final deviceIdProvider = FutureProvider<String>((ref) async {
  final service = ref.watch(deviceIdentityServiceProvider);
  return await service.getOrCreateDeviceId();
});

/// Provides the current server base URL.
final serverBaseUrlProvider = FutureProvider<String>((ref) async {
  final service = ref.watch(settingsServiceProvider);
  return await service.getServerBaseUrl();
});

/// Provides the currently active update channel.
final activeChannelProvider = FutureProvider<AppChannel>((ref) async {
  final service = ref.watch(settingsServiceProvider);
  return await service.getUpdateChannel();
});
