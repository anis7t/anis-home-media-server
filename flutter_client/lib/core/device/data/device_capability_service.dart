import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants/storage_keys.dart';
import '../domain/device_capabilities.dart';

/// Service responsible for querying native Android hardware and input attributes
/// to determine whether the running device is a TV / Fire TV or a mobile device.
class DeviceCapabilityService {
  static const MethodChannel _channel =
      MethodChannel('in.anisparvez.media_server_client/device_mode');

  /// Detects device capabilities synchronously if cached, or asynchronously probes
  /// the native platform channel.
  static Future<DeviceCapabilities> detect({SharedPreferences? prefs}) async {
    // 1. Check compile-time environment flag (e.g. --dart-define=TV_MODE=true)
    const compileTimeTv = bool.fromEnvironment('TV_MODE', defaultValue: false);
    if (compileTimeTv) {
      return DeviceCapabilities.tvDefault;
    }

    // 2. Check persistent runtime debug override (from Developer Settings)
    try {
      final p = prefs ?? await SharedPreferences.getInstance();
      if (p.containsKey(StorageKeys.debugTvModeOverride)) {
        final overrideValue = p.getBool(StorageKeys.debugTvModeOverride);
        if (overrideValue != null) {
          return overrideValue
              ? DeviceCapabilities.tvDefault
              : DeviceCapabilities.mobileDefault;
        }
      }
    } catch (_) {
      // Ignore prefs error and proceed to native detection
    }

    // 3. Native platform detection on Android
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'getDeviceCapabilities',
        );
        if (result != null) {
          return DeviceCapabilities.fromMap(result);
        }
      } catch (_) {
        // Fall back gracefully if platform channel is unavailable
      }
    }

    return DeviceCapabilities.mobileDefault;
  }

  /// Sets or clears the debug TV mode override.
  static Future<void> setDebugTvOverride(bool? isTv) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (isTv == null) {
        await p.remove(StorageKeys.debugTvModeOverride);
      } else {
        await p.setBool(StorageKeys.debugTvModeOverride, isTv);
      }
    } catch (_) {}
  }
}

/// Dynamic override notifier for live debug switching.
class DeviceCapabilitiesOverrideNotifier extends Notifier<DeviceCapabilities?> {
  final DeviceCapabilities? _initial;
  DeviceCapabilitiesOverrideNotifier([this._initial]);

  @override
  DeviceCapabilities? build() => _initial;

  void setOverride(DeviceCapabilities? value) {
    state = value;
  }
}

final deviceCapabilitiesOverrideProvider =
    NotifierProvider<DeviceCapabilitiesOverrideNotifier, DeviceCapabilities?>(
  () => DeviceCapabilitiesOverrideNotifier(),
);

/// Provides the current [DeviceCapabilities]. Overridden in main() at app launch
/// or in test suites via ProviderScope(overrides: [...]).
final deviceCapabilitiesProvider = Provider<DeviceCapabilities>((ref) {
  final override = ref.watch(deviceCapabilitiesOverrideProvider);
  if (override != null) return override;
  return DeviceCapabilities.mobileDefault;
});

/// Convenience provider returning true if the active runtime experience is TV mode.
final isTvModeProvider = Provider<bool>((ref) {
  return ref.watch(deviceCapabilitiesProvider).isTv;
});

/// Convenience provider returning true if the device is specifically an Amazon Fire TV.
final isFireTvProvider = Provider<bool>((ref) {
  return ref.watch(deviceCapabilitiesProvider).isAmazonFireTv;
});
