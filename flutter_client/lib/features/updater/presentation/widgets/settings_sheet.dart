import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../app/routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/models/app_channel.dart';
import '../../../../core/storage/settings_service.dart';
import '../controllers/update_controller.dart';
import 'update_prompt_dialog.dart';

class SettingsSheet extends ConsumerWidget {
  const SettingsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const SettingsSheet(),
    );
  }

  void _showChannelSwitchDialog(BuildContext context, WidgetRef ref, AppChannel targetChannel) {
    if (targetChannel == AppChannel.developer) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppColors.borderMedium),
          ),
          title: Text('Enable Developer Channel?', style: AppTypography.titleLarge),
          content: Text(
            'Developer builds are updated frequently during active development and may contain experimental features, incomplete work, or bugs.\n\nAre you sure you want to switch?',
            style: AppTypography.bodyMedium.copyWith(color: AppColors.textSecondary, height: 1.45),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.brandRed,
                foregroundColor: AppColors.textOnBrand,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                ref.read(updateControllerProvider.notifier).switchChannel(AppChannel.developer);
              },
              child: const Text('Switch to Developer'),
            ),
          ],
        ),
      );
    } else {
      // Switching to Production
      final currentCode = ref.read(updateControllerProvider).installedVersionCode;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppColors.borderMedium),
          ),
          title: Text('Switch to Production Channel?', style: AppTypography.titleLarge),
          content: Text(
            'You are returning to the stable release channel.\n\nNote: If your current Developer build (Build $currentCode) is newer than the latest Production release, your app will remain on this build until a newer Production version is published to avoid unsafe downgrades.',
            style: AppTypography.bodyMedium.copyWith(color: AppColors.textSecondary, height: 1.45),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.brandRed,
                foregroundColor: AppColors.textOnBrand,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                ref.read(updateControllerProvider.notifier).switchChannel(AppChannel.production);
              },
              child: const Text('Switch to Production'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updateState = ref.watch(updateControllerProvider);
    final baseUrlAsync = ref.watch(serverBaseUrlProvider);
    final baseUrl = baseUrlAsync.value ?? SettingsService.defaultServerUrl;
    final deviceIdAsync = ref.watch(deviceIdProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      maxChildSize: 0.92,
      minChildSize: 0.45,
      builder: (ctx, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.fromBorderSide(BorderSide(color: AppColors.borderMedium)),
          ),
          child: Column(
            children: [
              // Top drag pill
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.borderMedium,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // Header Row
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.settings_rounded, color: AppColors.brandRed, size: 22),
                    const SizedBox(width: 10),
                    Text('Settings', style: AppTypography.titleLarge.copyWith(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: AppColors.textSecondary, size: 20),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(color: AppColors.borderSubtle, height: 1),

              // Scrollable Settings Content
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  children: [
                    // Section 1: Server & Connection
                    _buildSectionHeader('SERVER & CONNECTION'),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: AppColors.statusSuccess,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  baseUrl,
                                  style: AppTypography.bodyMedium.copyWith(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              TextButton(
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                onPressed: () {
                                  Navigator.pop(context);
                                  context.push(AppRoutes.connection);
                                },
                                child: const Text('Change', style: TextStyle(color: AppColors.brandRedLight, fontSize: 13)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          deviceIdAsync.when(
                            data: (id) => Row(
                              children: [
                                Text('Device ID: ', style: AppTypography.labelSmall.copyWith(color: AppColors.textMuted)),
                                Text(
                                  id,
                                  style: AppTypography.labelSmall.copyWith(
                                    color: AppColors.textSecondary,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                                const SizedBox(width: 4),
                                GestureDetector(
                                  onTap: () {
                                    Clipboard.setData(ClipboardData(text: id));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Device ID copied to clipboard'), duration: Duration(seconds: 1)),
                                    );
                                  },
                                  child: const Icon(Icons.copy_rounded, color: AppColors.textMuted, size: 14),
                                ),
                              ],
                            ),
                            loading: () => const SizedBox.shrink(),
                            error: (_, _) => const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Section 2: Application Version
                    _buildSectionHeader('APPLICATION VERSION'),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Version ${updateState.installedVersionName}',
                                style: AppTypography.bodyMedium.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Build ${updateState.installedVersionCode}',
                                style: AppTypography.labelSmall.copyWith(color: AppColors.textMuted),
                              ),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: updateState.activeChannel == AppChannel.developer
                                  ? AppColors.brandRed.withValues(alpha: 0.15)
                                  : AppColors.statusInfo.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: updateState.activeChannel == AppChannel.developer
                                    ? AppColors.brandRed.withValues(alpha: 0.35)
                                    : AppColors.statusInfo.withValues(alpha: 0.35),
                              ),
                            ),
                            child: Text(
                              updateState.activeChannel.displayName.toUpperCase(),
                              style: AppTypography.labelSmall.copyWith(
                                color: updateState.activeChannel == AppChannel.developer
                                    ? AppColors.brandRedLight
                                    : AppColors.statusInfo,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Section 3: Update Channel Selection
                    _buildSectionHeader('UPDATE CHANNEL'),
                    const SizedBox(height: 8),
                    _buildChannelCard(
                      title: 'Production (Stable)',
                      description: 'Conservative releases verified for daily use.',
                      isSelected: updateState.activeChannel == AppChannel.production,
                      onTap: () {
                        if (updateState.activeChannel != AppChannel.production) {
                          _showChannelSwitchDialog(context, ref, AppChannel.production);
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    _buildChannelCard(
                      title: 'Developer',
                      description: 'Bleeding-edge development builds with active features.',
                      isSelected: updateState.activeChannel == AppChannel.developer,
                      isDeveloper: true,
                      onTap: () {
                        if (updateState.activeChannel != AppChannel.developer) {
                          _showChannelSwitchDialog(context, ref, AppChannel.developer);
                        }
                      },
                    ),
                    const SizedBox(height: 20),

                    // Section 4: Update Status & Check Button
                    _buildSectionHeader('UPDATES'),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Icon(
                                updateState.status == UpdateStatus.updateAvailable
                                    ? Icons.system_update_rounded
                                    : updateState.status == UpdateStatus.checking
                                        ? Icons.sync_rounded
                                        : Icons.check_circle_outline_rounded,
                                color: updateState.status == UpdateStatus.updateAvailable
                                    ? AppColors.brandRed
                                    : updateState.status == UpdateStatus.error
                                        ? AppColors.statusError
                                        : AppColors.statusSuccess,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  updateState.status == UpdateStatus.checking
                                      ? 'Checking for updates...'
                                      : updateState.status == UpdateStatus.updateAvailable
                                          ? 'Update available: ${updateState.availableManifest?.version}'
                                          : updateState.status == UpdateStatus.error
                                              ? (updateState.errorMessage ?? 'Update check failed')
                                              : 'Your application is up to date',
                                  style: AppTypography.bodyMedium.copyWith(
                                    color: updateState.status == UpdateStatus.updateAvailable
                                        ? AppColors.brandRedLight
                                        : updateState.status == UpdateStatus.error
                                            ? AppColors.statusError
                                            : AppColors.textPrimary,
                                    fontWeight: updateState.status == UpdateStatus.updateAvailable ? FontWeight.w700 : FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (updateState.lastChecked != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              'Last checked: ${_formatTimeAgo(updateState.lastChecked!)}',
                              style: AppTypography.labelSmall.copyWith(color: AppColors.textMuted),
                            ),
                          ],
                          const SizedBox(height: 14),
                          if (updateState.status == UpdateStatus.updateAvailable)
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.brandRed,
                                foregroundColor: AppColors.textOnBrand,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              icon: const Icon(Icons.arrow_circle_down_rounded, size: 18),
                              label: const Text('View Available Update', style: TextStyle(fontWeight: FontWeight.w700)),
                              onPressed: () {
                                showDialog(context: context, builder: (_) => const UpdatePromptDialog());
                              },
                            )
                          else
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.textPrimary,
                                side: const BorderSide(color: AppColors.borderMedium),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              icon: updateState.status == UpdateStatus.checking
                                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandRed))
                                  : const Icon(Icons.sync_rounded, size: 16),
                              label: const Text('Check for Updates'),
                              onPressed: updateState.status == UpdateStatus.checking
                                  ? null
                                  : () => ref.read(updateControllerProvider.notifier).checkForUpdates(isManual: true),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: AppTypography.labelSmall.copyWith(
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      ),
    );
  }

  Widget _buildChannelCard({
    required String title,
    required String description,
    required bool isSelected,
    required VoidCallback onTap,
    bool isDeveloper = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.surfaceElevated : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColors.brandRed : AppColors.borderSubtle,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: isSelected ? AppColors.brandRed : AppColors.textMuted,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTypography.bodyMedium.copyWith(
                      color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: AppTypography.labelSmall.copyWith(color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
