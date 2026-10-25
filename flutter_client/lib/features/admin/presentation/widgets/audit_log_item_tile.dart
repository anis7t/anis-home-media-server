import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../domain/models/audit_log_model.dart';

class AuditLogItemTile extends StatelessWidget {
  final AuditLogEntry entry;

  const AuditLogItemTile({super.key, required this.entry});

  IconData _getActionIcon() {
    switch (entry.action) {
      case 'pin_change':
        return Icons.password_rounded;
      case 'device_rename':
        return Icons.edit_note_rounded;
      case 'device_delete':
        return Icons.delete_forever_rounded;
      case 'device_assign':
        return Icons.person_add_alt_1_rounded;
      case 'cache_purge':
        return Icons.delete_sweep_rounded;
      default:
        return Icons.security_rounded;
    }
  }

  Color _getActionColor() {
    switch (entry.action) {
      case 'pin_change':
        return AppColors.statusWarning;
      case 'device_delete':
      case 'cache_purge':
        return AppColors.brandRed;
      case 'device_rename':
      case 'device_assign':
        return AppColors.statusSuccess;
      default:
        return AppColors.textSecondary;
    }
  }

  String _formatActionTitle() {
    switch (entry.action) {
      case 'pin_change':
        return 'Admin PIN Changed';
      case 'device_rename':
        return 'Device Renamed';
      case 'device_delete':
        return 'Device Revoked';
      case 'device_assign':
        return 'Device Assigned to User';
      case 'cache_purge':
        return 'Orphaned Caches Purged';
      default:
        return entry.action.replaceAll('_', ' ').toUpperCase();
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _getActionColor();
    final icon = _getActionIcon();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatActionTitle(),
                      style: AppTypography.titleMedium.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      entry.createdAt.length > 16
                          ? entry.createdAt.substring(0, 16).replaceAll('T', ' ')
                          : entry.createdAt,
                      style: const TextStyle(fontSize: 10, color: AppColors.textMuted),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      'Actor: ${entry.actorType} (${entry.actorId})',
                      style: AppTypography.labelSmall.copyWith(color: AppColors.textSecondary, fontSize: 11),
                    ),
                    if (entry.ipAddress != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        '• ${entry.ipAddress}',
                        style: const TextStyle(fontSize: 10, color: AppColors.textMuted),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
