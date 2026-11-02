import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/device/data/device_capability_service.dart';
import '../../../../core/widgets/tv_focusable.dart';
import '../../../auth/presentation/providers/auth_providers.dart';
import '../providers/admin_providers.dart';
import 'connected_devices_view.dart';
import 'library_maintenance_view.dart';
import 'media_inventory_view.dart';
import 'storage_management_view.dart';
import 'transcode_dashboard_view.dart';

class AdminHubScreen extends ConsumerWidget {
  const AdminHubScreen({super.key});

  static const _tabs = [
    (title: 'Storage & Retention', icon: Icons.storage_rounded),
    (title: 'Media Inventory', icon: Icons.video_library_rounded),
    (title: 'Transcodes & Dual-GPU', icon: Icons.speed_rounded),
    (title: 'Connected Devices', icon: Icons.devices_rounded),
    (title: 'Library & Security', icon: Icons.build_rounded),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTv = ref.watch(isTvModeProvider);
    final activeTab = ref.watch(adminHubTabProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: isTv
            ? _buildTvLayout(context, ref, activeTab)
            : _buildPhoneLayout(context, ref, activeTab),
      ),
    );
  }

  Widget _buildPhoneLayout(BuildContext context, WidgetRef ref, int activeTab) {
    final isAdmin = ref.watch(isAdminProvider);
    return Column(
      children: [
        // Frosted AppBar
        Container(
          padding: const EdgeInsets.fromLTRB(8, 12, 16, 12),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(
                  Icons.arrow_back_rounded,
                  color: AppColors.textPrimary,
                ),
                onPressed: () => context.pop(),
              ),
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.brandRed.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppColors.brandRed.withValues(alpha: 0.3),
                  ),
                ),
                child: const Center(
                  child: Icon(
                    Icons.admin_panel_settings_rounded,
                    color: AppColors.brandRed,
                    size: 18,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Admin Management Hub',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.titleMedium.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (isAdmin)
                IconButton(
                  tooltip: 'Lock Admin Controls',
                  icon: const Icon(
                    Icons.lock_outline_rounded,
                    color: AppColors.textSecondary,
                  ),
                  onPressed: () {
                    ref.read(adminHubLockedProvider.notifier).lock();
                    context.pop();
                  },
                ),
            ],
          ),
        ),

        // Horizontal Segmented Pill Tabs
        Container(
          height: 48,
          margin: const EdgeInsets.symmetric(vertical: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: List.generate(_tabs.length, (index) {
                final tab = _tabs[index];
                final isSelected = activeTab == index;

                return Padding(
                  padding: EdgeInsets.only(
                    right: index == _tabs.length - 1 ? 0 : 8,
                  ),
                  child: ChoiceChip(
                    showCheckmark: false,
                    avatar: Icon(
                      tab.icon,
                      size: 16,
                      color: isSelected
                          ? AppColors.background
                          : AppColors.textSecondary,
                    ),
                    label: Text(tab.title),
                    selected: isSelected,
                    selectedColor: AppColors.brandRed,
                    backgroundColor: AppColors.surfaceElevated,
                    labelStyle: TextStyle(
                      color: isSelected
                          ? AppColors.textOnBrand
                          : AppColors.textPrimary,
                      fontSize: 12,
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(
                        color: isSelected
                            ? AppColors.brandRed
                            : AppColors.borderSubtle,
                      ),
                    ),
                    onSelected: (_) =>
                        ref.read(adminHubTabProvider.notifier).selectTab(index),
                  ),
                );
              }),
            ),
          ),
        ),

        // Content Area
        Expanded(child: _buildTabContent(activeTab)),
      ],
    );
  }

  Widget _buildTvLayout(BuildContext context, WidgetRef ref, int activeTab) {
    final isAdmin = ref.watch(isAdminProvider);
    return Row(
      children: [
        // Left Navigation Rail for TV
        Container(
          width: 280,
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(right: BorderSide(color: AppColors.borderSubtle)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
                child: Row(
                  children: [
                    TvFocusable(
                      borderRadius: BorderRadius.circular(8),
                      onPressed: () => context.pop(),
                      builder: (context, isFocused, _) => Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isFocused
                              ? AppColors.brandRedLight
                              : AppColors.surfaceElevated,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isFocused
                                ? AppColors.brandRedLight
                                : AppColors.borderSubtle,
                            width: isFocused ? 4 : 1,
                          ),
                          boxShadow: isFocused
                              ? [
                                  BoxShadow(
                                    color: AppColors.brandRedGlow.withValues(
                                      alpha: 0.95,
                                    ),
                                    blurRadius: 22,
                                    spreadRadius: 3,
                                  ),
                                ]
                              : null,
                        ),
                        child: Icon(
                          Icons.arrow_back_rounded,
                          size: 18,
                          color: isFocused
                              ? AppColors.background
                              : AppColors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Admin Hub',
                            style: AppTypography.titleMedium.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Text(
                            'Server Management',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isAdmin) ...[
                      const SizedBox(width: 8),
                      Tooltip(
                        message: 'Lock Admin Controls',
                        child: TvFocusable(
                          borderRadius: BorderRadius.circular(8),
                          scaleOnFocus: false,
                          onPressed: () {
                            ref.read(adminHubLockedProvider.notifier).lock();
                            context.pop();
                          },
                          builder: (context, isFocused, _) => Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: isFocused
                                  ? AppColors.brandRedLight
                                  : AppColors.surfaceElevated,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isFocused
                                    ? AppColors.brandRedLight
                                    : AppColors.borderSubtle,
                                width: isFocused ? 4 : 1,
                              ),
                              boxShadow: isFocused
                                  ? [
                                      BoxShadow(
                                        color: AppColors.brandRedGlow
                                            .withValues(alpha: 0.95),
                                        blurRadius: 22,
                                        spreadRadius: 3,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Icon(
                              Icons.lock_outline_rounded,
                              size: 18,
                              color: isFocused
                                  ? AppColors.background
                                  : AppColors.textPrimary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(color: AppColors.borderSubtle, height: 1),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _tabs.length,
                  itemBuilder: (ctx, index) {
                    final tab = _tabs[index];
                    final isSelected = activeTab == index;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TvFocusable(
                        borderRadius: BorderRadius.circular(10),
                        onPressed: () => ref
                            .read(adminHubTabProvider.notifier)
                            .selectTab(index),
                        builder: (context, isFocused, _) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: isFocused
                                  ? AppColors.surfaceHighlight
                                  : (isSelected
                                        ? AppColors.surfaceElevated
                                        : Colors.transparent),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isFocused
                                    ? AppColors.brandRedLight
                                    : (isSelected
                                          ? AppColors.brandRed.withValues(
                                              alpha: 0.4,
                                            )
                                          : Colors.transparent),
                                width: isFocused ? 4.0 : 1.0,
                              ),
                              boxShadow: isFocused
                                  ? [
                                      BoxShadow(
                                        color: AppColors.brandRedGlow
                                            .withValues(alpha: 0.95),
                                        blurRadius: 22,
                                        spreadRadius: 3,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  tab.icon,
                                  size: 18,
                                  color: isSelected || isFocused
                                      ? AppColors.brandRed
                                      : AppColors.textSecondary,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    tab.title,
                                    style: TextStyle(
                                      color: isSelected || isFocused
                                          ? AppColors.textPrimary
                                          : AppColors.textSecondary,
                                      fontWeight: isSelected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),

        // Right Content Area
        Expanded(child: _buildTabContent(activeTab)),
      ],
    );
  }

  Widget _buildTabContent(int activeTab) {
    switch (activeTab) {
      case 0:
        return const StorageManagementView();
      case 1:
        return const MediaInventoryView();
      case 2:
        return const TranscodeDashboardView();
      case 3:
        return const ConnectedDevicesView();
      case 4:
        return const LibraryMaintenanceView();
      default:
        return const StorageManagementView();
    }
  }
}
