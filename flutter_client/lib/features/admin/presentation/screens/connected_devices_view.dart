import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../providers/admin_providers.dart';
import '../widgets/device_item_card.dart';

class ConnectedDevicesView extends ConsumerWidget {
  const ConnectedDevicesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(connectedDevicesControllerProvider);

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
            Text('Failed to load registered devices', style: AppTypography.titleMedium),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => ref.read(connectedDevicesControllerProvider.notifier).refresh(),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final stats = data.stats;

    return RefreshIndicator(
      onRefresh: () => ref.read(connectedDevicesControllerProvider.notifier).refresh(),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Stats Bar
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _buildStatItem(
                      'Total Devices',
                      '${stats.totalDevices}',
                      AppColors.textPrimary,
                    ),
                  ),
                  Container(width: 1, height: 32, color: AppColors.borderSubtle),
                  Expanded(
                    child: _buildStatItem(
                      'Active Now',
                      '${stats.activeNow}',
                      AppColors.statusSuccess,
                    ),
                  ),
                  Container(width: 1, height: 32, color: AppColors.borderSubtle),
                  Expanded(
                    child: _buildStatItem(
                      'Offline',
                      '${stats.offlineCount}',
                      AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Registered Clients (${data.devices.length})',
                  style: AppTypography.titleMedium.copyWith(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                Text(
                  '${stats.lanCount} LAN • ${stats.cloudflareCount} Tunnel',
                  style: AppTypography.labelSmall.copyWith(color: AppColors.textMuted),
                ),
              ],
            ),
            const SizedBox(height: 12),

            if (data.devices.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: const Center(
                  child: Text('No devices registered yet', style: TextStyle(color: AppColors.textSecondary)),
                ),
              )
            else
              ...data.devices.map((d) => DeviceItemCard(device: d)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value, Color color) {
    return Column(
      children: [
        Text(value, style: AppTypography.titleMedium.copyWith(color: color, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
      ],
    );
  }
}
