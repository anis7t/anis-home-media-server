import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../core/api/api_client.dart';
import '../../../../core/models/app_channel.dart';
import '../../../../core/storage/settings_service.dart';
import '../../data/models/update_manifest.dart';
import '../../data/repositories/update_repository.dart';
import '../../infrastructure/app_installer_bridge.dart';

enum UpdateStatus {
  idle,
  checking,
  updateAvailable,
  downloading,
  readyToInstall,
  upToDate,
  error,
}

class UpdateState {
  final UpdateStatus status;
  final AppChannel activeChannel;
  final String installedVersionName;
  final int installedVersionCode;
  final UpdateManifest? availableManifest;
  final double downloadProgress;
  final int downloadedBytes;
  final int totalBytes;
  final double downloadSpeedBytesPerSec;
  final int? etaSeconds;
  final String? errorMessage;
  final String? downloadedApkPath;
  final DateTime? lastChecked;

  const UpdateState({
    this.status = UpdateStatus.idle,
    this.activeChannel = AppChannel.production,
    this.installedVersionName = '1.0.0',
    this.installedVersionCode = 100,
    this.availableManifest,
    this.downloadProgress = 0.0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.downloadSpeedBytesPerSec = 0.0,
    this.etaSeconds,
    this.errorMessage,
    this.downloadedApkPath,
    this.lastChecked,
  });

  UpdateState copyWith({
    UpdateStatus? status,
    AppChannel? activeChannel,
    String? installedVersionName,
    int? installedVersionCode,
    UpdateManifest? availableManifest,
    double? downloadProgress,
    int? downloadedBytes,
    int? totalBytes,
    double? downloadSpeedBytesPerSec,
    int? etaSeconds,
    String? errorMessage,
    String? downloadedApkPath,
    DateTime? lastChecked,
    bool clearManifest = false,
    bool clearError = false,
  }) {
    return UpdateState(
      status: status ?? this.status,
      activeChannel: activeChannel ?? this.activeChannel,
      installedVersionName: installedVersionName ?? this.installedVersionName,
      installedVersionCode: installedVersionCode ?? this.installedVersionCode,
      availableManifest: clearManifest ? null : (availableManifest ?? this.availableManifest),
      downloadProgress: downloadProgress ?? this.downloadProgress,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadSpeedBytesPerSec: downloadSpeedBytesPerSec ?? this.downloadSpeedBytesPerSec,
      etaSeconds: etaSeconds ?? this.etaSeconds,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      downloadedApkPath: downloadedApkPath ?? this.downloadedApkPath,
      lastChecked: lastChecked ?? this.lastChecked,
    );
  }

  String get formattedDownloadProgress {
    final curMb = (downloadedBytes / (1024 * 1024)).toStringAsFixed(1);
    final totMb = (totalBytes / (1024 * 1024)).toStringAsFixed(1);
    return '$curMb MB / $totMb MB (${(downloadProgress * 100).toInt()}%)';
  }

  String get formattedSpeed {
    if (downloadSpeedBytesPerSec < 1024) return '${downloadSpeedBytesPerSec.toInt()} B/s';
    if (downloadSpeedBytesPerSec < 1024 * 1024) {
      return '${(downloadSpeedBytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(downloadSpeedBytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  String get formattedEta {
    if (etaSeconds == null || etaSeconds! <= 0) return 'Calculating...';
    if (etaSeconds! < 60) return '${etaSeconds!}s';
    final m = etaSeconds! ~/ 60;
    final s = etaSeconds! % 60;
    return '${m}m ${s}s';
  }
}

class UpdateController extends Notifier<UpdateState> {
  late UpdateRepository _repository;
  late SettingsService _settingsService;
  late AppInstallerBridge _installerBridge;

  CancelToken? _downloadCancelToken;
  DateTime? _lastDownloadSpeedUpdate;
  int _lastBytesReceived = 0;
  double _smoothSpeed = 0.0;

  static const Duration automaticCheckThrottle = Duration(hours: 4);

  @override
  UpdateState build() {
    _repository = ref.watch(updateRepositoryProvider);
    _settingsService = ref.watch(settingsServiceProvider);
    _installerBridge = ref.watch(appInstallerBridgeProvider);

    Future.microtask(() => init());

    return const UpdateState();
  }

  Future<void> init() async {
    try {
      final info = await _installerBridge.getAppInfo();
      final channel = await _settingsService.getUpdateChannel();
      final lastCheck = await _settingsService.getLastUpdateCheckTime();

      state = state.copyWith(
        installedVersionName: info.versionName,
        installedVersionCode: info.versionCode,
        activeChannel: channel,
        lastChecked: lastCheck,
      );

      // Perform throttled check on initialization
      final shouldCheck = lastCheck == null || DateTime.now().difference(lastCheck) > automaticCheckThrottle;
      if (shouldCheck) {
        await checkForUpdates(isManual: false);
      }
    } catch (e) {
      debugPrint('[UpdateController] Initialization error: $e');
    }
  }

  /// Checks the active channel feed for newer releases.
  Future<void> checkForUpdates({bool isManual = true}) async {
    if (state.status == UpdateStatus.checking || state.status == UpdateStatus.downloading) {
      return;
    }

    state = state.copyWith(
      status: UpdateStatus.checking,
      clearError: true,
    );

    try {
      final result = await _repository.fetchAndValidateManifest(
        channel: state.activeChannel,
        installedVersionCode: state.installedVersionCode,
      );

      final now = DateTime.now();
      await _settingsService.setLastUpdateCheckTime(now);

      if (result.isValid && result.manifest != null) {
        state = state.copyWith(
          status: UpdateStatus.updateAvailable,
          availableManifest: result.manifest,
          lastChecked: now,
        );
      } else {
        final msg = result.errorMessage;
        final isUpToDate = msg != null && (msg.contains('not newer') || msg.contains('No update'));
        state = state.copyWith(
          status: isUpToDate ? UpdateStatus.upToDate : UpdateStatus.error,
          errorMessage: msg,
          clearManifest: true,
          lastChecked: now,
        );
      }
    } catch (e) {
      state = state.copyWith(
        status: UpdateStatus.error,
        errorMessage: 'Update check failed: $e',
        clearManifest: true,
      );
    }
  }

  /// Explicitly switches the user's active update channel.
  Future<void> switchChannel(AppChannel newChannel) async {
    if (state.activeChannel == newChannel) return;

    await _settingsService.setUpdateChannel(newChannel);
    state = state.copyWith(
      activeChannel: newChannel,
      status: UpdateStatus.idle,
      clearManifest: true,
      clearError: true,
    );

    // Immediately query the newly subscribed channel feed
    await checkForUpdates(isManual: true);
  }

  /// Begins downloading the available update APK with progress telemetry.
  Future<void> startDownload() async {
    final manifest = state.availableManifest;
    if (manifest == null) return;

    state = state.copyWith(
      status: UpdateStatus.downloading,
      downloadProgress: 0.0,
      downloadedBytes: 0,
      totalBytes: manifest.fileSizeBytes,
      clearError: true,
    );

    _downloadCancelToken = CancelToken();
    _lastDownloadSpeedUpdate = DateTime.now();
    _lastBytesReceived = 0;
    _smoothSpeed = 0.0;

    String destPath;
    try {
      final cacheDir = await getTemporaryDirectory();
      destPath = '${cacheDir.path}/updates/media-server-update-${manifest.versionCode}.apk';
    } catch (e) {
      state = state.copyWith(
        status: UpdateStatus.error,
        errorMessage: 'Unable to resolve temporary download directory: $e',
      );
      return;
    }

    try {
      final success = await _repository.downloadApk(
        downloadUrl: manifest.apkUrl,
        destinationPath: destPath,
        cancelToken: _downloadCancelToken,
        onProgress: (received, total) {
          final now = DateTime.now();
          final effectiveTotal = total > 0 ? total : manifest.fileSizeBytes;
          final dt = _lastDownloadSpeedUpdate != null ? now.difference(_lastDownloadSpeedUpdate!).inMilliseconds / 1000.0 : 0.0;

          if (dt >= 0.3) {
            final bytesDelta = received - _lastBytesReceived;
            final instSpeed = bytesDelta / dt;
            _smoothSpeed = _smoothSpeed > 0 ? (_smoothSpeed * 0.7 + instSpeed * 0.3) : instSpeed;
            _lastBytesReceived = received;
            _lastDownloadSpeedUpdate = now;

            final remBytes = effectiveTotal - received;
            final remSec = _smoothSpeed > 0 ? (remBytes / _smoothSpeed).round() : null;

            state = state.copyWith(
              downloadProgress: (received / effectiveTotal).clamp(0.0, 1.0),
              downloadedBytes: received,
              totalBytes: effectiveTotal,
              downloadSpeedBytesPerSec: _smoothSpeed,
              etaSeconds: remSec,
            );
          } else {
            state = state.copyWith(
              downloadProgress: (received / effectiveTotal).clamp(0.0, 1.0),
              downloadedBytes: received,
              totalBytes: effectiveTotal,
            );
          }
        },
      );

      if (!success) {
        state = state.copyWith(
          status: UpdateStatus.error,
          errorMessage: 'Download incomplete or truncated.',
        );
        return;
      }

      // Cryptographic SHA-256 Checksum Verification
      final hashMatches = await _repository.verifyChecksum(destPath, manifest.sha256);
      if (!hashMatches) {
        await _repository.cleanupFile(destPath);
        state = state.copyWith(
          status: UpdateStatus.error,
          errorMessage: 'Cryptographic verification failed: SHA-256 mismatch. Corrupted file deleted.',
        );
        return;
      }

      state = state.copyWith(
        status: UpdateStatus.readyToInstall,
        downloadProgress: 1.0,
        downloadedApkPath: destPath,
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        state = state.copyWith(
          status: UpdateStatus.updateAvailable,
          downloadProgress: 0.0,
        );
      } else {
        state = state.copyWith(
          status: UpdateStatus.error,
          errorMessage: 'Download failed: ${e.message}',
        );
      }
    } catch (e) {
      state = state.copyWith(
        status: UpdateStatus.error,
        errorMessage: 'Unexpected download error: $e',
      );
    }
  }

  /// Cancels in-progress download.
  void cancelDownload() {
    _downloadCancelToken?.cancel('User cancelled download');
    state = state.copyWith(
      status: UpdateStatus.updateAvailable,
      downloadProgress: 0.0,
      downloadedBytes: 0,
    );
  }

  /// Hands the verified APK file to Android's native package installer.
  Future<bool> installDownloadedUpdate() async {
    final apkPath = state.downloadedApkPath;
    if (apkPath == null || state.status != UpdateStatus.readyToInstall) {
      return false;
    }

    final canInstall = await _installerBridge.canInstallUnknownPackages();
    if (!canInstall) {
      await _installerBridge.openInstallPermissionSettings();
      return false;
    }

    return await _installerBridge.installApk(apkPath);
  }

  void dismissUpdate() {
    state = state.copyWith(
      status: UpdateStatus.idle,
      clearManifest: true,
      clearError: true,
    );
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final appInstallerBridgeProvider = Provider<AppInstallerBridge>((ref) {
  return NativeAppInstallerBridge();
});

final updateRepositoryProvider = Provider<UpdateRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return UpdateRepository(apiClient.dio);
});

final updateControllerProvider = NotifierProvider<UpdateController, UpdateState>(UpdateController.new);
