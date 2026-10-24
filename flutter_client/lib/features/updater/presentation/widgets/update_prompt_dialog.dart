import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/models/app_channel.dart';
import '../controllers/update_controller.dart';

class UpdatePromptDialog extends ConsumerWidget {
  const UpdatePromptDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updateState = ref.watch(updateControllerProvider);
    final manifest = updateState.availableManifest;

    if (manifest == null && updateState.status != UpdateStatus.downloading && updateState.status != UpdateStatus.readyToInstall) {
      return const SizedBox.shrink();
    }

    final isDev = manifest?.channel == AppChannel.developer;
    final isDownloading = updateState.status == UpdateStatus.downloading;
    final isReady = updateState.status == UpdateStatus.readyToInstall;

    return Dialog(
      backgroundColor: AppColors.surfaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.borderMedium),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header Badge & Title
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: isDev ? AppColors.brandRed.withValues(alpha: 0.15) : AppColors.statusInfo.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isDev ? AppColors.brandRed.withValues(alpha: 0.4) : AppColors.statusInfo.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      manifest?.channel.displayName.toUpperCase() ?? 'UPDATE',
                      style: AppTypography.labelSmall.copyWith(
                        color: isDev ? AppColors.brandRedLight : AppColors.statusInfo,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (!isDownloading && !(manifest?.mandatory ?? false))
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: AppColors.textMuted, size: 20),
                      onPressed: () {
                        ref.read(updateControllerProvider.notifier).dismissUpdate();
                        Navigator.of(context, rootNavigator: true).pop();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Update Available: ${manifest?.version ?? ""}',
                style: AppTypography.titleLarge.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Build ${manifest?.versionCode ?? 0} • ${manifest?.formattedFileSize ?? ""}',
                style: AppTypography.bodyMedium.copyWith(color: AppColors.textMuted),
              ),
              const SizedBox(height: 16),

              // Release Notes
              if (manifest != null && manifest.releaseNotes.isNotEmpty) ...[
                Text(
                  "WHAT'S NEW",
                  style: AppTypography.labelSmall.copyWith(color: AppColors.textSecondary, letterSpacing: 0.6),
                ),
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 140),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.borderSubtle),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      manifest.releaseNotes,
                      style: AppTypography.bodyMedium.copyWith(color: AppColors.textPrimary, height: 1.4),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Downloading Progress Section
              if (isDownloading) ...[
                Text(
                  'Downloading update...',
                  style: AppTypography.bodyMedium.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: updateState.downloadProgress,
                    backgroundColor: AppColors.surface,
                    color: AppColors.brandRed,
                    minHeight: 8,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      updateState.formattedDownloadProgress,
                      style: AppTypography.labelSmall.copyWith(color: AppColors.textMuted),
                    ),
                    Text(
                      '${updateState.formattedSpeed} • ${updateState.formattedEta}',
                      style: AppTypography.labelSmall.copyWith(color: AppColors.textMuted),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: const BorderSide(color: AppColors.borderMedium),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    ref.read(updateControllerProvider.notifier).cancelDownload();
                  },
                  child: const Text('Cancel Download'),
                ),
              ] else if (isReady) ...[
                // Ready to Install
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.statusSuccess.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.statusSuccess.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_rounded, color: AppColors.statusSuccess, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Update downloaded and cryptographically verified (SHA-256).',
                          style: AppTypography.bodyMedium.copyWith(color: AppColors.statusSuccess),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.brandRed,
                    foregroundColor: AppColors.textOnBrand,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.system_update_rounded, size: 20),
                  label: const Text('Install Now', style: TextStyle(fontWeight: FontWeight.w700)),
                  onPressed: () async {
                    final success = await ref.read(updateControllerProvider.notifier).installDownloadedUpdate();
                    if (context.mounted && success) {
                      Navigator.of(context, rootNavigator: true).pop();
                    }
                  },
                ),
              ] else ...[
                // Action Buttons
                Row(
                  children: [
                    if (!(manifest?.mandatory ?? false))
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.textSecondary,
                            side: const BorderSide(color: AppColors.borderMedium),
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: () {
                            ref.read(updateControllerProvider.notifier).dismissUpdate();
                            Navigator.of(context, rootNavigator: true).pop();
                          },
                          child: const Text('Later'),
                        ),
                      ),
                    if (!(manifest?.mandatory ?? false)) const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.brandRed,
                          foregroundColor: AppColors.textOnBrand,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () {
                          ref.read(updateControllerProvider.notifier).startDownload();
                        },
                        child: const Text('Update Now', style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
