import 'package:flutter/foundation.dart';

/// Single recorded administrative audit event.
@immutable
class AuditLogEntry {
  final int id;
  final String actorType;
  final String actorId;
  final String action;
  final String? targetType;
  final String? targetId;
  final Map<String, dynamic>? details;
  final String? ipAddress;
  final String createdAt;

  const AuditLogEntry({
    required this.id,
    required this.actorType,
    required this.actorId,
    required this.action,
    this.targetType,
    this.targetId,
    this.details,
    this.ipAddress,
    required this.createdAt,
  });

  factory AuditLogEntry.fromJson(Map<String, dynamic> json) {
    return AuditLogEntry(
      id: (json['id'] as num?)?.toInt() ?? 0,
      actorType: (json['actor_type'] as String?) ?? 'system',
      actorId: (json['actor_id'] as String?) ?? '',
      action: (json['action'] as String?) ?? '',
      targetType: json['target_type'] as String?,
      targetId: json['target_id'] as String?,
      details: json['details'] is Map<String, dynamic>
          ? json['details'] as Map<String, dynamic>
          : null,
      ipAddress: json['ip_address'] as String?,
      createdAt: (json['created_at'] as String?) ?? '',
    );
  }
}

/// Paginated audit logs response from `GET /api/admin/audit-logs`.
@immutable
class AuditLogResponse {
  final List<AuditLogEntry> logs;
  final int total;
  final int limit;
  final int offset;

  const AuditLogResponse({
    required this.logs,
    required this.total,
    required this.limit,
    required this.offset,
  });

  factory AuditLogResponse.fromJson(Map<String, dynamic> json) {
    final list = (json['logs'] as List<dynamic>?)
            ?.map((e) => AuditLogEntry.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    return AuditLogResponse(
      logs: list,
      total: (json['total'] as num?)?.toInt() ?? 0,
      limit: (json['limit'] as num?)?.toInt() ?? 50,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
    );
  }
}
