import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../domain/models/transcode_dashboard_model.dart';
import '../providers/admin_providers.dart';
import '../widgets/active_transcode_card.dart';

class TranscodeDashboardView extends ConsumerWidget {
  const TranscodeDashboardView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(transcodeDashboardControllerProvider);

    if (state.isLoading && state.data == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(color: AppColors.brandRed),
        ),
      );
    }

    final data = state.data;
    if (data == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, color: AppColors.brandRed, size: 36),
            const SizedBox(height: 12),
            Text('Failed to load transcode telemetry', style: AppTypography.titleMedium),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => ref.read(transcodeDashboardControllerProvider.notifier).refresh(),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final summary = data.summary;
    final hw = summary.hardwareEngine;

    return RefreshIndicator(
      onRefresh: () => ref.read(transcodeDashboardControllerProvider.notifier).refresh(),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Dual-GPU Engine Telemetry
            Container(
              padding: const EdgeInsets.all(16),
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
                          const Icon(Icons.speed_rounded, color: AppColors.brandRed, size: 20),
                          const SizedBox(width: 8),
                          Text('Dual-GPU Hardware Engines', style: AppTypography.titleMedium),
                        ],
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.refresh_rounded, size: 20, color: AppColors.textMuted),
                        tooltip: 'Sweep stale jobs',
                        onPressed: state.isActionInProgress
                            ? null
                            : () => ref.read(transcodeDashboardControllerProvider.notifier).sweepStaleJobs(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(child: _buildGpuCard(hw.primary, true)),
                      const SizedBox(width: 12),
                      Expanded(child: _buildGpuCard(hw.secondary, false)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Transcode Summary Metrics
            Row(
              children: [
                Expanded(
                  child: _buildSummaryBox(
                    label: 'Active Jobs',
                    value: '${summary.activeCount}',
                    sub: '${summary.runningCount} running • ${summary.queuedCount} queued',
                    color: summary.activeCount > 0 ? AppColors.brandRed : AppColors.textPrimary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildSummaryBox(
                    label: 'Queue ETA',
                    value: summary.overallEtaStr,
                    sub: summary.totalEstimatedSizeStr,
                    color: AppColors.brandRedLight,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Active Jobs Section
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Active Transcode Jobs (${data.activeJobs.length})',
                  style: AppTypography.titleMedium.copyWith(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                if (summary.activeCount > 0)
                  Text(
                    'Auto-refreshing (2s)',
                    style: AppTypography.labelSmall.copyWith(color: AppColors.statusSuccess),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (data.activeJobs.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 24),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: const Column(
                  children: [
                    Icon(Icons.check_circle_outline_rounded, color: AppColors.textMuted, size: 32),
                    SizedBox(height: 8),
                    Text('No active transcode streams', style: TextStyle(color: AppColors.textSecondary)),
                  ],
                ),
              )
            else
              ...data.activeJobs.map((j) => ActiveTranscodeCard(job: j)),

            const SizedBox(height: 20),

            // Recent Jobs History
            Text(
              'Recent History (${data.recentJobs.length})',
              style: AppTypography.titleMedium.copyWith(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            if (data.recentJobs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No recent transcode history', style: TextStyle(color: AppColors.textMuted)),
              )
            else
              ...data.recentJobs.map((j) => _buildRecentJobRow(j)),
          ],
        ),
      ),
    );
  }

  Widget _buildGpuCard(GpuEngineStatus gpu, bool isDiscrete) {
    final isActive = gpu.status.toLowerCase().contains('active');

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isActive
              ? AppColors.brandRed.withValues(alpha: 0.5)
              : AppColors.borderSubtle,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: isActive ? AppColors.statusSuccess : AppColors.textMuted,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  gpu.name,
                  style: AppTypography.titleMedium.copyWith(fontSize: 12, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            isDiscrete ? 'Discrete • dx11:1' : 'Integrated • dx11:0',
            style: const TextStyle(fontSize: 10, color: AppColors.textMuted),
          ),
          const SizedBox(height: 6),
          Text(
            gpu.status,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isActive ? AppColors.brandRed : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryBox({
    required String label,
    required String value,
    required String sub,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTypography.labelSmall.copyWith(color: AppColors.textMuted)),
          const SizedBox(height: 4),
          Text(
            value,
            style: AppTypography.titleLarge.copyWith(color: color, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(sub, style: AppTypography.labelSmall.copyWith(color: AppColors.textSecondary)),
        ],
      ),
    );
  }

  Widget _buildRecentJobRow(TranscodeRecentJob job) {
    Color statusColor;
    IconData statusIcon;
    switch (job.status.toLowerCase()) {
      case 'completed':
        statusColor = AppColors.statusSuccess;
        statusIcon = Icons.check_circle_rounded;
        break;
      case 'canceled':
        statusColor = AppColors.textMuted;
        statusIcon = Icons.cancel_rounded;
        break;
      default:
        statusColor = AppColors.brandRed;
        statusIcon = Icons.error_rounded;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        children: [
          Icon(statusIcon, color: statusColor, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  job.title,
                  style: AppTypography.titleMedium.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${job.status.toUpperCase()} ${job.elapsedStr != null ? '• ${job.elapsedStr}' : ''}',
                  style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
