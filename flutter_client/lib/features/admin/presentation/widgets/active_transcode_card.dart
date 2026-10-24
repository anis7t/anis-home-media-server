import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../domain/models/transcode_dashboard_model.dart';
import '../providers/admin_providers.dart';

class ActiveTranscodeCard extends ConsumerWidget {
  final TranscodeActiveJob job;

  const ActiveTranscodeCard({super.key, required this.job});

  void _showCancelDialog(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.borderMedium),
        ),
        title: Text('Cancel Transcode?', style: AppTypography.titleLarge),
        content: Text(
          'Are you sure you want to stop transcoding "${job.title}" (${job.presetLabel})?\n\nIn-progress chunks will be safely closed.',
          style: AppTypography.bodyMedium.copyWith(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Keep Transcoding', style: TextStyle(color: AppColors.textSecondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brandRed,
              foregroundColor: AppColors.textOnBrand,
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              ref
                  .read(transcodeDashboardControllerProvider.notifier)
                  .cancelJob(job.filename);
            },
            child: const Text('Cancel Job'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pct = (job.percent / 100.0).clamp(0.0, 1.0);
    final isRunning = job.status == 'running';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isRunning
              ? AppColors.brandRed.withValues(alpha: 0.4)
              : AppColors.borderSubtle,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: isRunning ? AppColors.statusSuccess : AppColors.brandRed,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  job.title,
                  style: AppTypography.titleMedium.copyWith(fontSize: 14, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: Text(
                  job.presetLabel.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: const Icon(Icons.cancel_outlined, color: AppColors.brandRed, size: 20),
                tooltip: 'Cancel job',
                onPressed: () => _showCancelDialog(context, ref),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6,
              backgroundColor: AppColors.surface,
              valueColor: const AlwaysStoppedAnimation<Color>(AppColors.brandRed),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${job.percent.toStringAsFixed(1)}% • ${job.currentSizeStr} of ${job.estimatedTotalSizeStr}',
                style: AppTypography.labelSmall.copyWith(color: AppColors.textMuted),
              ),
              Row(
                children: [
                  if (job.speedStr != null) ...[
                    Text(
                      job.speedStr!,
                      style: AppTypography.labelSmall.copyWith(
                        color: AppColors.brandRedLight,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (job.fpsStr != null) ...[
                    Text(
                      job.fpsStr!,
                      style: AppTypography.labelSmall.copyWith(color: AppColors.textSecondary),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (job.etaStr != null)
                    Text(
                      'ETA ${job.etaStr}',
                      style: AppTypography.labelSmall.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
