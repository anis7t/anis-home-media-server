import 'package:flutter/foundation.dart';

/// One drive within the server's storage pool (e.g. Drive D: or Drive E:).
@immutable
class StorageDriveInfo {
  final String drive;
  final String label;
  final double percent;
  final int used;
  final int free;
  final int total;
  final String usedStr;
  final String freeStr;
  final String totalStr;

  const StorageDriveInfo({
    required this.drive,
    required this.label,
    required this.percent,
    required this.used,
    required this.free,
    required this.total,
    required this.usedStr,
    required this.freeStr,
    required this.totalStr,
  });

  factory StorageDriveInfo.fromJson(Map<String, dynamic> json) {
    return StorageDriveInfo(
      drive: (json['drive'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
      percent: ((json['percent'] as num?) ?? 0).toDouble(),
      used: (json['used'] as num?)?.toInt() ?? 0,
      free: (json['free'] as num?)?.toInt() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
      usedStr: (json['used_str'] as String?) ?? '',
      freeStr: (json['free_str'] as String?) ?? '',
      totalStr: (json['total_str'] as String?) ?? '',
    );
  }
}

/// Overall storage telemetry for the host machine.
@immutable
class ServerStorageInfo {
  final double percent;
  final int used;
  final int free;
  final int total;
  final String usedStr;
  final String freeStr;
  final String totalStr;
  final List<StorageDriveInfo> drives;

  const ServerStorageInfo({
    required this.percent,
    required this.used,
    required this.free,
    required this.total,
    required this.usedStr,
    required this.freeStr,
    required this.totalStr,
    required this.drives,
  });

  factory ServerStorageInfo.fromJson(Map<String, dynamic> json) {
    final drivesList = (json['drives'] as List<dynamic>?)
            ?.map((e) => StorageDriveInfo.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    return ServerStorageInfo(
      percent: ((json['percent'] as num?) ?? 0).toDouble(),
      used: (json['used'] as num?)?.toInt() ?? 0,
      free: (json['free'] as num?)?.toInt() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
      usedStr: (json['used_str'] as String?) ?? '',
      freeStr: (json['free_str'] as String?) ?? '',
      totalStr: (json['total_str'] as String?) ?? '',
      drives: drivesList,
    );
  }
}

/// Audit report breakdown for active vs orphaned cache directories.
@immutable
class CacheAuditData {
  final int totalOrphanedBytes;
  final int totalOrphanedDirs;
  final int totalActiveBytes;
  final int totalActiveDirs;
  final bool degraded;
  final List<String> degradedReasons;

  const CacheAuditData({
    required this.totalOrphanedBytes,
    required this.totalOrphanedDirs,
    required this.totalActiveBytes,
    required this.totalActiveDirs,
    required this.degraded,
    required this.degradedReasons,
  });

  factory CacheAuditData.fromJson(Map<String, dynamic> json) {
    return CacheAuditData(
      totalOrphanedBytes: (json['total_orphaned_bytes'] as num?)?.toInt() ?? 0,
      totalOrphanedDirs: (json['total_orphaned_dirs'] as num?)?.toInt() ?? 0,
      totalActiveBytes: (json['total_active_bytes'] as num?)?.toInt() ?? 0,
      totalActiveDirs: (json['total_active_dirs'] as num?)?.toInt() ?? 0,
      degraded: (json['degraded'] as bool?) ?? false,
      degradedReasons: (json['degraded_reasons'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }
}

/// Full response from `GET /api/storage/audit`.
@immutable
class StorageAuditReport {
  final ServerStorageInfo storage;
  final CacheAuditData audit;

  const StorageAuditReport({
    required this.storage,
    required this.audit,
  });

  factory StorageAuditReport.fromJson(Map<String, dynamic> json) {
    return StorageAuditReport(
      storage: ServerStorageInfo.fromJson(
        (json['storage'] as Map<String, dynamic>?) ?? {},
      ),
      audit: CacheAuditData.fromJson(
        (json['audit'] as Map<String, dynamic>?) ?? {},
      ),
    );
  }
}

/// Post-transcode retention settings.
@immutable
class StorageRetentionSettings {
  final String retentionPolicy;
  final List<String> allowedPolicies;
  final String archiveDir;

  const StorageRetentionSettings({
    required this.retentionPolicy,
    required this.allowedPolicies,
    required this.archiveDir,
  });

  factory StorageRetentionSettings.fromJson(Map<String, dynamic> json) {
    return StorageRetentionSettings(
      retentionPolicy: (json['retention_policy'] as String?) ?? 'keep',
      allowedPolicies: (json['allowed_policies'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          ['keep', 'archive', 'purge_cache'],
      archiveDir: (json['archive_dir'] as String?) ?? '',
    );
  }
}

/// Outcome of purging orphaned caches.
@immutable
class PurgeResult {
  final int freedBytes;
  final int purgedCount;
  final bool dryRun;

  const PurgeResult({
    required this.freedBytes,
    required this.purgedCount,
    required this.dryRun,
  });

  factory PurgeResult.fromJson(Map<String, dynamic> json) {
    return PurgeResult(
      freedBytes: (json['freed_bytes'] as num?)?.toInt() ?? 0,
      purgedCount: (json['purged_count'] as num?)?.toInt() ?? 0,
      dryRun: (json['dry_run'] as bool?) ?? false,
    );
  }
}
