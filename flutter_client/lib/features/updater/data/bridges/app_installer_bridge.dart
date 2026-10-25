import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Application information returned by the native host platform.
class AppPlatformInfo {
  final String packageName;
  final String versionName;
  final int versionCode;

  const AppPlatformInfo({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
  });
}

/// Abstract bridge contract for querying app package information and invoking native installation.
abstract class AppInstallerBridge {
  Future<AppPlatformInfo> getAppInfo();
  Future<bool> canInstallUnknownPackages();
  Future<void> openInstallPermissionSettings();
  Future<bool> installApk(String filePath);
}

/// Production Android implementation communicating over MethodChannel with MainActivity.
class NativeAppInstallerBridge implements AppInstallerBridge {
  static const MethodChannel _channel =
      MethodChannel('in.anisparvez.media_server_client/app_updater');

  @override
  Future<AppPlatformInfo> getAppInfo() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final result = await _channel.invokeMapMethod<String, dynamic>('getAppInfo');
        if (result != null) {
          final pkg = result['packageName']?.toString() ?? 'in.anisparvez.media_server_client';
          final vName = result['versionName']?.toString() ?? '1.0.0';
          final vCode = (result['versionCode'] as num?)?.toInt() ?? 100;
          return AppPlatformInfo(
            packageName: pkg,
            versionName: vName,
            versionCode: vCode,
          );
        }
      } catch (e) {
        debugPrint('[NativeAppInstallerBridge] getAppInfo failed: $e');
      }
    }
    // Fallback default for desktop / test environments
    return const AppPlatformInfo(
      packageName: 'in.anisparvez.media_server_client',
      versionName: '1.0.0',
      versionCode: 100,
    );
  }

  @override
  Future<bool> canInstallUnknownPackages() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final res = await _channel.invokeMethod<bool>('canInstallUnknownPackages');
        return res ?? true;
      } catch (e) {
        debugPrint('[NativeAppInstallerBridge] canInstallUnknownPackages failed: $e');
      }
    }
    return true;
  }

  @override
  Future<void> openInstallPermissionSettings() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('openInstallPermissionSettings');
      } catch (e) {
        debugPrint('[NativeAppInstallerBridge] openInstallPermissionSettings failed: $e');
      }
    }
  }

  @override
  Future<bool> installApk(String filePath) async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final res = await _channel.invokeMethod<bool>('installApk', {'filePath': filePath});
        return res ?? false;
      } catch (e) {
        debugPrint('[NativeAppInstallerBridge] installApk failed: $e');
        return false;
      }
    }
    debugPrint('[NativeAppInstallerBridge] installApk not supported on current platform.');
    return false;
  }
}
