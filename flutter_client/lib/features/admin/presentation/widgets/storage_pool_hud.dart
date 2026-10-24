import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../domain/models/storage_audit_model.dart';
import '../providers/admin_providers.dart';

class StoragePoolHud extends ConsumerWidget {
  const StoragePoolHud({super.key});

  void _showPurgeConfirmation(BuildContext context, WidgetRef ref, StorageAuditReport report) {
    final orphanSize = report.audit.totalOrphanedBytes;
    final orphanDirs = report.audit.totalOrphanedDirs;

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.borderMedium),
        ),
        title: Text(
          'Purge Orphaned Caches?',
          style: AppTypography.titleLarge,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will permanently delete $orphanDirs unlinked HLS and preview cache directories (${_formatBytes(orphanSize)}).',
              style: AppTypography.bodyMedium.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Active playback caches and media files are not affected.',
              style: AppTypography.labelSmall.copyWith(
                color: AppColors.textMuted,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brandRed,
              foregroundColor: AppColors.textOnBrand,
            ),
            onPressed: () async {
              Navigator.of(ctx).pop();
              final result = await ref
                  .read(storageControllerProvider.notifier)
                  .purgeOrphans(dryRun: false);
              if (result != null && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Successfully freed ${_formatBytes(result.freedBytes)} (${result.purgedCount} directories purged)',
                    ),
                  ),
                );
              }
            },
            child: const Text('Purge Orphans'),
          ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double val = bytes.toDouble();
    while (val >= 1024 && i < suffixes.length - 1) {
      val /= 1024;
      i++;
    }
    return '${val.toStringAsFixed(1)} ${suffixes[i]}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(storageControllerProvider);

    if (state.isLoading && state.report == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(color: AppColors.brandRed),
        ),
      );
    }

    final report = state.report;
    final settings = state.settings;

    if (report == null) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, color: AppColors.brandRed, size: 36),
            const SizedBox(height: 12),
            Text('Failed to load storage telemetry', style: AppTypography.titleMedium),
            const SizedBox(height: 8),
            Text(state.errorMessage ?? 'Unknown error', style: AppTypography.labelSmall),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => ref.read(storageControllerProvider.notifier).refresh(),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Drives Card Group
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.storage_rounded, color: AppColors.brandRed, size: 20),
                      const SizedBox(width: 8),
                      Text('Storage Pool Telemetry', style: AppTypography.titleMedium),
                    ],
                  ),
                  Text(
                    '${report.storage.usedStr} / ${report.storage.totalStr}',
                    style: AppTypography.labelSmall.copyWith(color: AppColors.textSecondary),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ...report.storage.drives.map((d) => _buildDriveRow(d)),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Cache Audit & Retention Settings Card
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.cleaning_services_rounded, color: AppColors.brandRed, size: 20),
                  const SizedBox(width: 8),
                  Text('Cache Audit & Retention Policy', style: AppTypography.titleMedium),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _buildMetricTile(
                      label: 'Active Caches',
                      value: _formatBytes(report.audit.totalActiveBytes),
                      sub: '${report.audit.totalActiveDirs} streams',
                      color: AppColors.statusSuccess,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildMetricTile(
                      label: 'Orphaned Caches',
                      value: _formatBytes(report.audit.totalOrphanedBytes),
                      sub: '${report.audit.totalOrphanedDirs} unlinked',
                      color: report.audit.totalOrphanedDirs > 0
                          ? AppColors.brandRed
                          : AppColors.textMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (settings != null) ...[
                Text(
                  'Post-Transcode Retention Policy',
                  style: AppTypography.labelSmall.copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.borderSubtle),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: settings.retentionPolicy,
                      isExpanded: true,
                      dropdownColor: AppColors.surfaceElevated,
                      items: const [
                        DropdownMenuItem(
                          value: 'keep',
                          child: Text('Keep • Retain all HLS chunks permanently'),
                        ),
                        DropdownMenuItem(
                          value: 'archive',
                          child: Text('Archive • Move to cold archive after grace period'),
                        ),
                        DropdownMenuItem(
                          value: 'purge_cache',
                          child: Text('Purge Cache • Auto-purge to maximize SSD space'),
                        ),
                      ],
                      onChanged: (newPolicy) {
                        if (newPolicy != null) {
                          ref
                              .read(storageControllerProvider.notifier)
                              .setRetentionPolicy(newPolicy);
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: report.audit.totalOrphanedDirs > 0
                        ? AppColors.brandRed
                        : AppColors.surfaceHighlight,
                    foregroundColor: report.audit.totalOrphanedDirs > 0
                        ? AppColors.textOnBrand
                        : AppColors.textMuted,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: state.isPurging
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.delete_sweep_rounded, size: 20),
                  label: Text(
                    state.isPurging
                        ? 'Purging Caches...'
                        : 'Purge Orphaned Caches (${_formatBytes(report.audit.totalOrphanedBytes)})',
                  ),
                  onPressed: report.audit.totalOrphanedDirs > 0 && !state.isPurging
                      ? () => _showPurgeConfirmation(context, ref, report)
                      : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDriveRow(StorageDriveInfo drive) {
    final pct = (drive.percent / 100.0).clamp(0.0, 1.0);
    final isWarning = drive.percent >= 85;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${drive.drive} (${drive.label})',
                style: AppTypography.bodyMedium.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(
                '${drive.percent.toStringAsFixed(1)}% • ${drive.freeStr} free',
                style: AppTypography.labelSmall.copyWith(
                  color: isWarning ? AppColors.brandRed : AppColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 8,
              backgroundColor: AppColors.surface,
              valueColor: AlwaysStoppedAnimation<Color>(
                isWarning ? AppColors.brandRed : AppColors.statusSuccess,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricTile({
    required String label,
    required String value,
    required String sub,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTypography.labelSmall.copyWith(color: AppColors.textMuted)),
          const SizedBox(height: 4),
          Text(
            value,
            style: AppTypography.titleMedium.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(sub, style: AppTypography.labelSmall.copyWith(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
