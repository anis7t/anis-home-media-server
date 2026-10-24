import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../domain/models/connected_device_model.dart';
import '../providers/admin_providers.dart';

class DeviceItemCard extends ConsumerWidget {
  final ConnectedDevice device;

  const DeviceItemCard({super.key, required this.device});

  void _showRenameDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController(text: device.displayName);

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.borderMedium),
        ),
        title: Text('Rename Device', style: AppTypography.titleLarge),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter a friendly name for "${device.displayName}":',
              style: AppTypography.labelSmall.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              style: AppTypography.bodyMedium,
              decoration: InputDecoration(
                hintText: 'e.g. Living Room Fire TV',
                hintStyle: TextStyle(color: AppColors.textMuted),
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.borderSubtle),
                ),
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
            onPressed: () {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                Navigator.of(ctx).pop();
                ref
                    .read(connectedDevicesControllerProvider.notifier)
                    .renameDevice(device.deviceId, newName);
              }
            },
            child: const Text('Save Name'),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.borderMedium),
        ),
        title: Text('Revoke Device?', style: AppTypography.titleLarge),
        content: Text(
          'Are you sure you want to remove "${device.displayName}" from registered devices?\n\nIf active, it will be deregistered and must reconnect.',
          style: AppTypography.bodyMedium.copyWith(color: AppColors.textSecondary),
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
            onPressed: () {
              Navigator.of(ctx).pop();
              ref
                  .read(connectedDevicesControllerProvider.notifier)
                  .deleteDevice(device.deviceId);
            },
            child: const Text('Revoke Device'),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor() {
    if (device.isActive) return AppColors.statusSuccess;
    if (device.lastSeenAgo.contains('minute') || device.lastSeenAgo.contains('now')) {
      return AppColors.statusWarning;
    }
    return AppColors.textMuted;
  }

  String _getStatusLabel() {
    if (device.isActive) return 'Active Now';
    return 'Last seen ${device.lastSeenAgo}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusColor = _getStatusColor();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: device.isCurrent
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
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: Center(
                  child: Icon(
                    device.deviceType == 'tv'
                        ? Icons.tv_rounded
                        : Icons.smartphone_rounded,
                    color: AppColors.textSecondary,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            device.displayName,
                            style: AppTypography.titleMedium.copyWith(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (device.isCurrent) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppColors.brandRed.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: AppColors.brandRed,
                                width: 0.8,
                              ),
                            ),
                            child: const Text(
                              'THIS DEVICE',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: AppColors.brandRedLight,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _getStatusLabel(),
                          style: AppTypography.labelSmall.copyWith(color: AppColors.textMuted),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded, color: AppColors.textMuted, size: 20),
                color: AppColors.surfaceElevated,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: const BorderSide(color: AppColors.borderSubtle),
                ),
                onSelected: (val) {
                  if (val == 'rename') {
                    _showRenameDialog(context, ref);
                  } else if (val == 'delete') {
                    _showDeleteDialog(context, ref);
                  }
                },
                itemBuilder: (ctx) => [
                  const PopupMenuItem(
                    value: 'rename',
                    child: Row(
                      children: [
                        Icon(Icons.edit_outlined, size: 18, color: AppColors.textSecondary),
                        SizedBox(width: 8),
                        Text('Rename Device'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline_rounded, size: 18, color: AppColors.brandRed),
                        SizedBox(width: 8),
                        Text('Revoke / Forget', style: TextStyle(color: AppColors.brandRed)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (device.deviceModel != null && device.deviceModel!.isNotEmpty)
                _buildInfoBadge(Icons.devices_rounded, device.deviceModel!),
              if (device.deviceOs != null && device.deviceOs!.isNotEmpty)
                _buildInfoBadge(Icons.terminal_rounded, device.deviceOs!),
              if (device.clientIp != null && device.clientIp!.isNotEmpty)
                _buildInfoBadge(Icons.network_check_rounded, device.clientIp!),
              if (device.connectionType != null && device.connectionType!.isNotEmpty)
                _buildInfoBadge(Icons.hub_rounded, device.connectionType!),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoBadge(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppColors.textMuted),
          const SizedBox(width: 4),
          Text(
            text,
            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
