import 'package:dio/dio.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_endpoints.dart';
import '../../../core/errors/app_exception.dart';
import '../domain/models/audit_log_model.dart';
import '../domain/models/connected_device_model.dart';
import '../domain/models/library_scan_model.dart';
import '../domain/models/storage_audit_model.dart';
import '../domain/models/transcode_dashboard_model.dart';

/// Repository coordinating all administrative calls across storage, transcodes,
/// devices, and library maintenance against the Rust backend.
class AdminRepository {
  final ApiClient _apiClient;

  AdminRepository(this._apiClient);

  Dio get _dio => _apiClient.dio;

  // ==========================================
  // Storage & Retention Management
  // ==========================================

  /// Audit active vs orphaned cache directories across storage pools.
  Future<StorageAuditReport> getStorageAudit() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        ApiEndpoints.storageAudit,
      );
      if (res.statusCode == 200 && res.data != null) {
        return StorageAuditReport.fromJson(res.data!);
      }
      throw AppException(
        'Failed to audit storage caches',
        statusCode: res.statusCode,
      );
    } on DioException catch (e) {
      throw _mapDioError(e, 'Failed to audit storage');
    }
  }

  /// Query current post-transcode retention policy.
  Future<StorageRetentionSettings> getStorageSettings() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        ApiEndpoints.storageSettings,
      );
      if (res.statusCode == 200 && res.data != null) {
        return StorageRetentionSettings.fromJson(res.data!);
      }
      throw AppException(
        'Failed to fetch storage retention settings',
        statusCode: res.statusCode,
      );
    } on DioException catch (e) {
      throw _mapDioError(e, 'Failed to fetch storage settings');
    }
  }

  /// Update storage retention policy in PostgreSQL (`keep`, `archive`, `purge_cache`).
  Future<bool> updateStorageSettings(
    String policy, {
    String? adminPin,
  }) async {
    try {
      final payload = <String, dynamic>{
        'retention_policy': policy,
        if (adminPin != null && adminPin.isNotEmpty) 'admin_pin': adminPin,
      };
      final res = await _dio.post<Map<String, dynamic>>(
        ApiEndpoints.storageSettings,
        data: payload,
      );
      return res.statusCode == 200;
    } on DioException catch (e) {
      throw _mapDioError(e, 'Failed to update storage retention policy');
    }
  }

  /// Purge verified orphaned HLS and preview caches.
  Future<PurgeResult> purgeOrphanedCaches({
    bool dryRun = false,
    String? adminPin,
  }) async {
    try {
      final payload = <String, dynamic>{
        'dry_run': dryRun,
        if (adminPin != null && adminPin.isNotEmpty) 'admin_pin': adminPin,
      };
      final res = await _dio.post<Map<String, dynamic>>(
        ApiEndpoints.storagePurgeOrphans,
        data: payload,
      );
      if (res.statusCode == 200 && res.data != null) {
        final resultJson = res.data!['result'] as Map<String, dynamic>? ?? {};
        return PurgeResult.fromJson(resultJson);
      }
      throw AppException(
        'Failed to purge orphaned caches',
        statusCode: res.statusCode,
      );
    } on DioException catch (e) {
      throw _mapDioError(e, 'Failed to purge orphaned caches');
    }
  }

  // ==========================================
  // Transcode Dashboard & Dual-GPU Telemetry
  // ==========================================

  /// Fetch full transcode dashboard telemetry, active streams, and recent history.
  Future<TranscodeDashboardResponse> getTranscodeDashboard() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        ApiEndpoints.transcodeDashboard,
      );
      if (res.statusCode == 200 && res.data != null) {
        return TranscodeDashboardResponse.fromJson(res.data!);
      }
      throw AppException(
        'Failed to load transcode dashboard',
        statusCode: res.statusCode,
      );
    } on DioException catch (e) {
      throw _mapDioError(e, 'Failed to load transcode dashboard');
    }
  }

  /// Cancel an actively running or queued transcode job.
  Future<bool> cancelTranscodeJob(String filename) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        ApiEndpoints.transcodeCancel(Uri.encodeComponent(filename)),
      );
      return res.statusCode == 200;
    } on DioException catch (e) {
      throw _mapDioError(e, 'Failed to cancel transcode job');
    }
  }

  /// Sweep stale or abandoned transcode jobs.
  Future<bool> sweepStaleTranscodes() async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        ApiEndpoints.transcodeSweep,
      );
      return res.statusCode == 200;
    } on DioException catch (e) {
      throw _mapDioError(e, 'Failed to sweep transcode jobs');
    }
  }

  // ==========================================
  // Connected Devices Management
  // ==========================================

  /// Fetch all registered client devices with online presence states.
  Future<DeviceListResponse> getDevices() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        ApiEndpoints.devices,
      );
      if (res.statusCode == 200 && res.data != null) {
        return DeviceListResponse.fromJson(res.data!);
      }
      throw AppException(
        'Failed to fetch registered devices',
        statusCode: res.statusCode,
      );
    } on DioException catch (e) {
      throw _mapDioError(e, 'Failed to fetch registered devices');
    }
  }

  /// Rename a device friendly label.
  Future<bool> renameDevice(String deviceId, String name) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        ApiEndpoints.deviceRename,
        data: {'device_id': deviceId, 'name': name},
      );
      return res.statusCode == 200;
    } on DioException catch (e) {
      throw _mapDioError(e, 'Failed to rename device');
    }
  }

  /// Revoke or delete a registered client device.
  Future<bool> deleteDevice(String deviceId) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        ApiEndpoints.deviceDelete,
        data: {'device_id': deviceId},
      );
      return res.statusCode == 200;
    } on DioException catch (e) {
      throw _mapDioError(e, 'Failed to delete device');
    }
  }

  // ==========================================
  // Library Maintenance & Security Tools
  // ==========================================

  /// Query current TMDb media library scanning status.
  Future<LibraryScanStatus> getScanStatus() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        ApiEndpoints.scan,
      );
      if (res.statusCode == 200 && res.data != null) {
        return LibraryScanStatus.fromJson(res.data!);
      }
      throw AppException(
        'Failed to query scan status',
        statusCode: res.statusCode,
      );
    } on DioException catch (e) {
      throw _mapDioError(e, 'Failed to query scan status');
    }
  }

  /// Trigger full library scan.
  Future<bool> triggerScan({String? adminPin}) async {
    try {
      final payload = <String, dynamic>{
        if (adminPin != null && adminPin.isNotEmpty) 'admin_pin': adminPin,
      };
      final res = await _dio.post<Map<String, dynamic>>(
        ApiEndpoints.scan,
        data: payload,
      );
      return res.statusCode == 200 || res.statusCode == 202;
    } on DioException catch (e) {
      throw _mapDioError(e, 'Failed to trigger library scan');
    }
  }

  /// Rotate administrator PIN.
  Future<bool> updateAdminPin(String currentPin, String newPin) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        ApiEndpoints.adminPin,
        data: {
          'current_pin': currentPin,
          'new_pin': newPin,
        },
      );
      return res.statusCode == 200;
    } on DioException catch (e) {
      throw _mapDioError(e, 'Failed to update admin PIN');
    }
  }

  /// Retrieve paginated administrator audit logs.
  Future<AuditLogResponse> getAuditLogs({
    int limit = 50,
    int offset = 0,
    String? action,
  }) async {
    try {
      final queryParams = <String, dynamic>{
        'limit': limit,
        'offset': offset,
        if (action != null && action.isNotEmpty) 'action': action,
      };
      final res = await _dio.get<Map<String, dynamic>>(
        ApiEndpoints.adminAuditLogs,
        queryParameters: queryParams,
      );
      if (res.statusCode == 200 && res.data != null) {
        return AuditLogResponse.fromJson(res.data!);
      }
      throw AppException(
        'Failed to fetch audit logs',
        statusCode: res.statusCode,
      );
    } on DioException catch (e) {
      throw _mapDioError(e, 'Failed to fetch audit logs');
    }
  }

  // ==========================================
  // Helper Error Mapping
  // ==========================================

  AppException _mapDioError(DioException e, String defaultMessage) {
    final status = e.response?.statusCode;
    if (status == 401 || status == 403) {
      return UnauthorizedException(
        e.response?.data is Map && (e.response!.data as Map)['error'] != null
            ? (e.response!.data as Map)['error'].toString()
            : 'Administrator access required',
        statusCode: status,
      );
    }
    final message =
        e.response?.data is Map && (e.response!.data as Map)['error'] != null
            ? (e.response!.data as Map)['error'].toString()
            : e.message ?? defaultMessage;
    return AppException(message, statusCode: status);
  }
}
