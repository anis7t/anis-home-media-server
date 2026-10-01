import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/models/app_channel.dart';
import '../../../../core/storage/settings_service.dart';
import '../../../../core/device/infrastructure/device_capability_service.dart';
import '../../../../core/widgets/tv_focusable.dart';
import '../../../intro/presentation/controllers/intro_controller.dart';
import '../controllers/update_controller.dart';
import 'update_prompt_dialog.dart';

/// Reusable settings content displaying server origin, device identity,
/// application version, update channel selector, and live update checks.
/// Shared between [SettingsSheet] (modal) and [SettingsScreen] (tab).
class SettingsContent extends ConsumerWidget {
  final ScrollController? scrollController;
  final EdgeInsetsGeometry padding;
  final bool isModal;

  const SettingsContent({
    super.key,
    this.scrollController,
    this.padding = const EdgeInsets.fromLTRB(20, 16, 20, 24),
    this.isModal = false,
  });

  void _showChannelSwitchDialog(
    BuildContext context,
    WidgetRef ref,
    AppChannel targetChannel,
  ) {
    if (targetChannel == AppChannel.developer) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppColors.borderMedium),
          ),
          title: Text(
            'Enable Developer Channel?',
            style: AppTypography.titleLarge,
          ),
          content: Text(
            'Developer builds are updated frequently during active development and may contain experimental features, incomplete work, or bugs.\n\nAre you sure you want to switch?',
            style: AppTypography.bodyMedium.copyWith(
              color: AppColors.textSecondary,
              height: 1.45,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.brandRed,
                foregroundColor: AppColors.textOnBrand,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                ref
                    .read(updateControllerProvider.notifier)
                    .switchChannel(AppChannel.developer);
              },
              child: const Text('Switch to Developer'),
            ),
          ],
        ),
      );
    } else {
      // Switching to Production
      final currentCode =
          ref.read(updateControllerProvider).installedVersionCode;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppColors.borderMedium),
          ),
          title: Text(
            'Switch to Production Channel?',
            style: AppTypography.titleLarge,
          ),
          content: Text(
            'You are returning to the stable release channel.\n\nNote: If your current Developer build (Build $currentCode) is newer than the latest Production release, your app will remain on this build until a newer Production version is published to avoid unsafe downgrades.',
            style: AppTypography.bodyMedium.copyWith(
              color: AppColors.textSecondary,
              height: 1.45,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.brandRed,
                foregroundColor: AppColors.textOnBrand,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                ref
                    .read(updateControllerProvider.notifier)
                    .switchChannel(AppChannel.production);
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
    final isTv = ref.watch(isTvModeProvider);

    final effectivePadding = isTv
        ? const EdgeInsets.fromLTRB(24, 20, 24, 120)
        : padding;

    return ListView(
      controller: scrollController,
      padding: effectivePadding,
      children: [
        // Section 1: Server & Connection
        _buildSectionHeader('SERVER & CONNECTION'),
        const SizedBox(height: 8),
        TvFocusable(
          borderRadius: BorderRadius.circular(12),
          onPressed: () {
            if (isModal && Navigator.canPop(context)) {
              Navigator.pop(context);
            }
            context.push(AppRoutes.connection);
          },
          builder: (context, isFocused, _) {
            return Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isFocused
                    ? AppColors.surfaceHighlight
                    : AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isFocused ? AppColors.brandRed : AppColors.borderSubtle,
                  width: isFocused ? 2.5 : 1.0,
                ),
                boxShadow: isFocused
                    ? [
                        BoxShadow(
                          color: AppColors.brandRedGlow.withValues(alpha: 0.65),
                          blurRadius: 18,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.statusSuccess,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          baseUrl,
                          style: AppTypography.bodyMedium.copyWith(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Connected • Press to change server address',
                          style: AppTypography.labelSmall.copyWith(
                            color: isFocused
                                ? AppColors.brandRedLight
                                : AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: isFocused
                          ? AppColors.brandRed.withValues(alpha: 0.22)
                          : AppColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isFocused
                            ? AppColors.brandRed
                            : AppColors.borderSubtle,
                      ),
                    ),
                    child: const Text(
                      'Change',
                      style: TextStyle(
                        color: AppColors.brandRedLight,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        deviceIdAsync.when(
          data: (id) => TvFocusable(
            borderRadius: BorderRadius.circular(10),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: id));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Device ID copied to clipboard'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            builder: (context, isFocused, _) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isFocused
                      ? AppColors.surfaceHighlight
                      : AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isFocused ? AppColors.brandRed : AppColors.borderSubtle,
                    width: isFocused ? 2.5 : 1.0,
                  ),
                  boxShadow: isFocused
                      ? [
                          BoxShadow(
                            color: AppColors.brandRedGlow.withValues(alpha: 0.6),
                            blurRadius: 14,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  children: [
                    Text(
                      'Device ID: ',
                      style: AppTypography.labelSmall.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        id,
                        style: AppTypography.labelSmall.copyWith(
                          color: AppColors.textSecondary,
                          fontFamily: 'monospace',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.copy_rounded,
                      color: AppColors.textMuted,
                      size: 14,
                    ),
                  ],
                ),
              );
            },
          ),
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const SizedBox.shrink(),
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
                    style: AppTypography.bodyMedium.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Build ${updateState.installedVersionCode}',
                    style: AppTypography.labelSmall.copyWith(
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
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
          description:
              'Bleeding-edge development builds with active features.',
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
                                  ? (updateState.errorMessage ??
                                      'Update check failed')
                                  : 'Your application is up to date',
                      style: AppTypography.bodyMedium.copyWith(
                        color: updateState.status == UpdateStatus.updateAvailable
                            ? AppColors.brandRedLight
                            : updateState.status == UpdateStatus.error
                                ? AppColors.statusError
                                : AppColors.textPrimary,
                        fontWeight:
                            updateState.status == UpdateStatus.updateAvailable
                                ? FontWeight.w700
                                : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              if (updateState.lastChecked != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Last checked: ${_formatTimeAgo(updateState.lastChecked!)}',
                  style: AppTypography.labelSmall.copyWith(
                    color: AppColors.textMuted,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              if (updateState.status == UpdateStatus.updateAvailable)
                TvFocusable(
                  borderRadius: BorderRadius.circular(8),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (_) => const UpdatePromptDialog(),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.brandRed,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.arrow_circle_down_rounded, size: 20, color: AppColors.textOnBrand),
                        SizedBox(width: 8),
                        Text(
                          'View Available Update',
                          style: TextStyle(
                            color: AppColors.textOnBrand,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                TvFocusable(
                  borderRadius: BorderRadius.circular(8),
                  onPressed: updateState.status == UpdateStatus.checking
                      ? null
                      : () => ref
                          .read(updateControllerProvider.notifier)
                          .checkForUpdates(isManual: true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.borderMedium),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (updateState.status == UpdateStatus.checking)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.brandRed,
                            ),
                          )
                        else
                          const Icon(Icons.sync_rounded, size: 16, color: AppColors.textPrimary),
                        const SizedBox(width: 8),
                        Text(
                          updateState.status == UpdateStatus.checking
                              ? 'Checking for updates...'
                              : 'Check for Updates',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Section 5: Display & Device Mode
        _buildSectionHeader('DISPLAY & DEVICE MODE'),
        const SizedBox(height: 8),
        TvFocusable(
          borderRadius: BorderRadius.circular(12),
          onPressed: () async {
            final currentVal = ref.read(isTvModeProvider);
            final newVal = !currentVal;
            await DeviceCapabilityService.setDebugTvOverride(newVal);
            final current = ref.read(deviceCapabilitiesProvider);
            ref.read(deviceCapabilitiesOverrideProvider.notifier).setOverride(
                  current.copyWith(isTv: newVal),
                );
          },
          builder: (context, isFocused, child) {
            final isTvMode = ref.watch(isTvModeProvider);
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: isFocused
                    ? AppColors.brandRed.withValues(alpha: 0.15)
                    : AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isFocused ? AppColors.brandRed : AppColors.borderSubtle,
                  width: isFocused ? 2.5 : 1.0,
                ),
                boxShadow: isFocused
                    ? [
                        const BoxShadow(
                          color: AppColors.brandRedGlow,
                          blurRadius: 18,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                children: [
                  const Icon(Icons.tv_rounded, color: AppColors.brandRed, size: 22),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Force TV UI Mode',
                          style: AppTypography.bodyMedium.copyWith(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Swaps between touch mobile UI and 10-foot TV navigation rail with borderless fullscreen player.',
                          style: AppTypography.labelSmall.copyWith(
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  ExcludeFocus(
                    child: Switch.adaptive(
                      value: isTvMode,
                      activeTrackColor: AppColors.brandRed,
                      onChanged: (val) async {
                        await DeviceCapabilityService.setDebugTvOverride(val);
                        final current = ref.read(deviceCapabilitiesProvider);
                        ref.read(deviceCapabilitiesOverrideProvider.notifier).setOverride(
                              current.copyWith(isTv: val),
                            );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 20),

        // Section 6: Brand & Experience
        _buildSectionHeader('BRAND & EXPERIENCE'),
        const SizedBox(height: 8),
        TvFocusable(
          borderRadius: BorderRadius.circular(12),
          onPressed: () {
            ref.read(introControllerProvider.notifier).replay();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Brand Intro will replay on next launch or navigation'),
                duration: Duration(seconds: 2),
              ),
            );
          },
          builder: (context, isFocused, child) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: isFocused
                    ? AppColors.brandRed.withValues(alpha: 0.15)
                    : AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isFocused ? AppColors.brandRed : AppColors.borderSubtle,
                  width: isFocused ? 2.5 : 1.0,
                ),
                boxShadow: isFocused
                    ? [
                        const BoxShadow(
                          color: AppColors.brandRedGlow,
                          blurRadius: 18,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                children: [
                  const Icon(Icons.movie_filter_rounded, color: AppColors.brandRed, size: 22),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Replay Brand Intro',
                          style: AppTypography.bodyMedium.copyWith(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Play the signature opening sting animation and score.',
                          style: AppTypography.labelSmall.copyWith(
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.play_circle_outline_rounded, color: AppColors.brandRedLight, size: 20),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 20),
      ],
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
    return TvFocusable(
      borderRadius: BorderRadius.circular(12),
      onPressed: onTap,
      scaleOnFocus: true,
      glowOnFocus: true,
      builder: (context, isFocused, child) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: isFocused
                ? AppColors.brandRed.withValues(alpha: 0.15)
                : (isSelected ? AppColors.surfaceElevated : AppColors.surface),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isFocused
                  ? AppColors.brandRed
                  : (isSelected
                      ? AppColors.brandRed.withValues(alpha: 0.4)
                      : AppColors.borderSubtle),
              width: isFocused ? 2.5 : 1.2,
            ),
            boxShadow: isFocused
                ? [
                    const BoxShadow(
                      color: AppColors.brandRedGlow,
                      blurRadius: 18,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: isSelected ? AppColors.brandRed : AppColors.textMuted,
                size: 22,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: AppTypography.bodyMedium.copyWith(
                            color: isSelected || isFocused
                                ? AppColors.textPrimary
                                : AppColors.textSecondary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (isSelected) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.brandRed.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: AppColors.brandRed.withValues(alpha: 0.35),
                                width: 0.8,
                              ),
                            ),
                            child: const Text(
                              'ACTIVE',
                              style: TextStyle(
                                color: AppColors.brandRedLight,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      style: AppTypography.labelSmall.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (isFocused)
                const Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: AppColors.brandRed,
                  size: 14,
                ),
            ],
          ),
        );
      },
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
