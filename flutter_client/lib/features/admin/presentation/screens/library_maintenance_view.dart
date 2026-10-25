import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../providers/admin_providers.dart';
import '../widgets/audit_log_item_tile.dart';
import '../widgets/change_pin_sheet.dart';

class LibraryMaintenanceView extends ConsumerWidget {
  const LibraryMaintenanceView({super.key});

  void _showChangePinSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const ChangePinSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(libraryMaintenanceControllerProvider);

    if (state.isLoading && state.scanStatus == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(color: AppColors.brandRed),
        ),
      );
    }

    final scan = state.scanStatus;
    final isScanning = state.isScanning;
    final logs = state.auditLogs?.logs ?? [];

    return RefreshIndicator(
      onRefresh: () => ref.read(libraryMaintenanceControllerProvider.notifier).refresh(),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // TMDb Media Scanner Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isScanning
                      ? AppColors.brandRed.withValues(alpha: 0.5)
                      : AppColors.borderSubtle,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.sync_rounded,
                            color: isScanning ? AppColors.brandRed : AppColors.textSecondary,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text('TMDb Library Scanner', style: AppTypography.titleMedium),
                        ],
                      ),
                      if (isScanning)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.brandRed.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: AppColors.brandRed),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 10,
                                height: 10,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                  color: AppColors.brandRed,
                                ),
                              ),
                              SizedBox(width: 6),
                              Text(
                                'SCANNING',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.brandRedLight,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Scans video storage roots (`D:/Flicks`) to ingest newly added files, queries TMDb metadata, and synchronizes embedded and external subtitles.',
                    style: AppTypography.labelSmall.copyWith(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  if (scan != null) ...[
                    Row(
                      children: [
                        Expanded(
                          child: _buildMetricTile(
                            'Indexed',
                            '${scan.moviesIndexed}',
                            '${scan.filesDiscovered} discovered',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _buildMetricTile(
                            'Subtitles',
                            '${scan.subtitlesAcquired}',
                            '${scan.orphansPruned} pruned',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.brandRed,
                        foregroundColor: AppColors.textOnBrand,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: isScanning
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.textOnBrand,
                              ),
                            )
                          : const Icon(Icons.refresh_rounded, size: 20),
                      label: Text(
                        isScanning ? 'Scan in progress...' : 'Trigger Full Library Scan',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      onPressed: isScanning || state.isActionInProgress
                          ? null
                          : () => ref.read(libraryMaintenanceControllerProvider.notifier).triggerScan(),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Admin PIN Rotation Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.borderSubtle),
                    ),
                    child: const Center(
                      child: Icon(Icons.password_rounded, color: AppColors.brandRed, size: 20),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Admin Security PIN', style: AppTypography.titleMedium.copyWith(fontSize: 14, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text('Rotate server administrator PIN', style: AppTypography.labelSmall.copyWith(color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: () => _showChangePinSheet(context),
                    child: const Text('Change PIN'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Security Audit Logs
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Security Audit Logs (${logs.length})',
                  style: AppTypography.titleMedium.copyWith(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                Text(
                  'PostgreSQL 18.4',
                  style: AppTypography.labelSmall.copyWith(color: AppColors.textMuted),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (logs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text('No recorded administrative events', style: TextStyle(color: AppColors.textMuted)),
                ),
              )
            else
              ...logs.map((entry) => AuditLogItemTile(entry: entry)),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricTile(String label, String value, String sub) {
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
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
          const SizedBox(height: 2),
          Text(value, style: AppTypography.titleMedium.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
