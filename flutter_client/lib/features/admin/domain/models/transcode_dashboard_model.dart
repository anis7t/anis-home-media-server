import 'package:flutter/foundation.dart';

/// Single GPU hardware engine status (e.g. discrete RX 560X or integrated Vega 8).
@immutable
class GpuEngineStatus {
  final String name;
  final int adapter;
  final String backend;
  final String status;

  const GpuEngineStatus({
    required this.name,
    required this.adapter,
    required this.backend,
    required this.status,
  });

  factory GpuEngineStatus.fromJson(Map<String, dynamic> json) {
    return GpuEngineStatus(
      name: (json['name'] as String?) ?? '',
      adapter: (json['adapter'] as num?)?.toInt() ?? 0,
      backend: (json['backend'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'Idle / Standby',
    );
  }
}

/// Dual-GPU hardware configuration and operational status.
@immutable
class DualGpuHardwareInfo {
  final GpuEngineStatus primary;
  final GpuEngineStatus secondary;

  const DualGpuHardwareInfo({
    required this.primary,
    required this.secondary,
  });

  factory DualGpuHardwareInfo.fromJson(Map<String, dynamic> json) {
    return DualGpuHardwareInfo(
      primary: GpuEngineStatus.fromJson(
        (json['primary'] as Map<String, dynamic>?) ?? {},
      ),
      secondary: GpuEngineStatus.fromJson(
        (json['secondary'] as Map<String, dynamic>?) ?? {},
      ),
    );
  }
}

/// Aggregated telemetry summary of transcoding workload.
@immutable
class TranscodeDashboardSummary {
  final int activeCount;
  final int runningCount;
  final int queuedCount;
  final int totalCurrentBytes;
  final String totalCurrentSizeStr;
  final int totalEstimatedBytes;
  final String totalEstimatedSizeStr;
  final double overallEtaSeconds;
  final String overallEtaStr;
  final DualGpuHardwareInfo hardwareEngine;

  const TranscodeDashboardSummary({
    required this.activeCount,
    required this.runningCount,
    required this.queuedCount,
    required this.totalCurrentBytes,
    required this.totalCurrentSizeStr,
    required this.totalEstimatedBytes,
    required this.totalEstimatedSizeStr,
    required this.overallEtaSeconds,
    required this.overallEtaStr,
    required this.hardwareEngine,
  });

  factory TranscodeDashboardSummary.fromJson(Map<String, dynamic> json) {
    return TranscodeDashboardSummary(
      activeCount: (json['active_count'] as num?)?.toInt() ?? 0,
      runningCount: (json['running_count'] as num?)?.toInt() ?? 0,
      queuedCount: (json['queued_count'] as num?)?.toInt() ?? 0,
      totalCurrentBytes: (json['total_current_bytes'] as num?)?.toInt() ?? 0,
      totalCurrentSizeStr: (json['total_current_size_str'] as String?) ?? '0 B',
      totalEstimatedBytes:
          (json['total_estimated_bytes'] as num?)?.toInt() ?? 0,
      totalEstimatedSizeStr:
          (json['total_estimated_size_str'] as String?) ?? '0 B',
      overallEtaSeconds:
          ((json['overall_eta_seconds'] as num?) ?? 0).toDouble(),
      overallEtaStr: (json['overall_eta_str'] as String?) ?? '0s',
      hardwareEngine: DualGpuHardwareInfo.fromJson(
        (json['hardware_engine'] as Map<String, dynamic>?) ?? {},
      ),
    );
  }
}

/// One active or running transcode job.
@immutable
class TranscodeActiveJob {
  final int id;
  final String filename;
  final String title;
  final int? year;
  final int? runtime;
  final String posterUrl;
  final String mode;
  final String presetLabel;
  final String status;
  final double percent;
  final String? speedStr;
  final String? fpsStr;
  final String? etaStr;
  final String currentSizeStr;
  final String estimatedTotalSizeStr;

  const TranscodeActiveJob({
    required this.id,
    required this.filename,
    required this.title,
    this.year,
    this.runtime,
    required this.posterUrl,
    required this.mode,
    required this.presetLabel,
    required this.status,
    required this.percent,
    this.speedStr,
    this.fpsStr,
    this.etaStr,
    required this.currentSizeStr,
    required this.estimatedTotalSizeStr,
  });

  factory TranscodeActiveJob.fromJson(Map<String, dynamic> json) {
    return TranscodeActiveJob(
      id: (json['id'] as num?)?.toInt() ?? 0,
      filename: (json['filename'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      year: (json['year'] as num?)?.toInt(),
      runtime: (json['runtime'] as num?)?.toInt(),
      posterUrl: (json['poster_url'] as String?) ?? '',
      mode: (json['mode'] as String?) ?? '',
      presetLabel: (json['preset_label'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'queued',
      percent: ((json['percent'] as num?) ?? 0).toDouble(),
      speedStr: json['speed_str'] as String?,
      fpsStr: json['fps_str'] as String?,
      etaStr: json['eta_str'] as String?,
      currentSizeStr: (json['current_size_str'] as String?) ?? '0 B',
      estimatedTotalSizeStr:
          (json['estimated_total_size_str'] as String?) ?? '0 B',
    );
  }
}

/// One recently completed, canceled, or failed transcode job.
@immutable
class TranscodeRecentJob {
  final int id;
  final String filename;
  final String title;
  final String status;
  final String? elapsedStr;
  final String? updatedAt;

  const TranscodeRecentJob({
    required this.id,
    required this.filename,
    required this.title,
    required this.status,
    this.elapsedStr,
    this.updatedAt,
  });

  factory TranscodeRecentJob.fromJson(Map<String, dynamic> json) {
    return TranscodeRecentJob(
      id: (json['id'] as num?)?.toInt() ?? 0,
      filename: (json['filename'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'completed',
      elapsedStr: json['elapsed_str'] as String?,
      updatedAt: json['updated_at'] as String?,
    );
  }
}

/// Full response from `GET /api/transcode/dashboard`.
@immutable
class TranscodeDashboardResponse {
  final TranscodeDashboardSummary summary;
  final List<TranscodeActiveJob> activeJobs;
  final List<TranscodeRecentJob> recentJobs;

  const TranscodeDashboardResponse({
    required this.summary,
    required this.activeJobs,
    required this.recentJobs,
  });

  factory TranscodeDashboardResponse.fromJson(Map<String, dynamic> json) {
    final active = (json['active_jobs'] as List<dynamic>?)
            ?.map((e) => TranscodeActiveJob.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    final recent = (json['recent_jobs'] as List<dynamic>?)
            ?.map((e) => TranscodeRecentJob.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    return TranscodeDashboardResponse(
      summary: TranscodeDashboardSummary.fromJson(
        (json['summary'] as Map<String, dynamic>?) ?? {},
      ),
      activeJobs: active,
      recentJobs: recent,
    );
  }
}
