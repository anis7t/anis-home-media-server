import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/device/data/device_capability_service.dart';
import '../../../../core/widgets/tv_focusable.dart';
import '../../../auth/presentation/providers/auth_providers.dart';
import '../../../auth/presentation/widgets/admin_pin_sheet.dart';
import '../../../auth/presentation/widgets/tv_admin_pin_pad.dart';
import '../providers/admin_providers.dart';

/// Entry tile embedded in Settings for accessing the Admin Management Hub.
/// Role-gated: opens directly for Admins; prompts for Admin PIN for viewers/guests.
class AdminHubTile extends ConsumerWidget {
  const AdminHubTile({super.key});

  static const Color goldAccent = Color(0xFFE5A93B);

  Future<void> _handleTap(
    BuildContext context,
    WidgetRef ref,
    bool isTv,
  ) async {
    final isAdmin = ref.read(isAdminProvider);
    final isLocked = ref.read(adminHubLockedProvider);
    if (isAdmin && !isLocked) {
      context.push(AppRoutes.adminHub);
      return;
    }

    final unlockOnly = isAdmin && isLocked;
    if (isTv) {
      showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 48,
            vertical: 24,
          ),
          child: TvAdminPinPad(
            isUnlockOnly: unlockOnly,
            onSuccess: () {
              ref.read(adminHubLockedProvider.notifier).unlock();
              Navigator.of(ctx).pop();
              context.push(AppRoutes.adminHub);
            },
            onCancel: () => Navigator.of(ctx).pop(),
          ),
        ),
      );
    } else {
      final success = await AdminPinSheet.show(
        context,
        isUnlockOnly: unlockOnly,
      );
      if (success && context.mounted) {
        ref.read(adminHubLockedProvider.notifier).unlock();
        context.push(AppRoutes.adminHub);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTv = ref.watch(isTvModeProvider);
    final isAdmin = ref.watch(isAdminProvider);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isTv ? 24 : 16, vertical: 8),
      child: TvFocusable(
        borderRadius: BorderRadius.circular(16),
        onPressed: () => _handleTap(context, ref, isTv),
        builder: (context, isFocused, _) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isFocused
                  ? AppColors.surfaceHighlight
                  : AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isFocused
                    ? goldAccent
                    : (isAdmin
                          ? goldAccent.withValues(alpha: 0.35)
                          : AppColors.borderSubtle),
                width: isFocused ? 4 : 1.0,
              ),
              boxShadow: isFocused
                  ? [
                      BoxShadow(
                        color: goldAccent.withValues(alpha: 0.75),
                        blurRadius: 24,
                        spreadRadius: 3,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isAdmin
                        ? goldAccent.withValues(alpha: 0.15)
                        : AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isAdmin
                          ? goldAccent.withValues(alpha: 0.4)
                          : AppColors.borderSubtle,
                    ),
                  ),
                  child: Center(
                    child: Icon(
                      isAdmin
                          ? Icons.admin_panel_settings_rounded
                          : Icons.lock_outline_rounded,
                      color: isAdmin ? goldAccent : AppColors.textMuted,
                      size: 24,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              'Admin Management Hub',
                              style: AppTypography.titleMedium.copyWith(
                                color: isFocused
                                    ? goldAccent
                                    : AppColors.textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: isAdmin
                                  ? goldAccent.withValues(alpha: 0.2)
                                  : AppColors.surface,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: isAdmin
                                    ? goldAccent
                                    : AppColors.borderSubtle,
                                width: 0.8,
                              ),
                            ),
                            child: Text(
                              isAdmin ? 'UNLOCKED' : 'LOCKED',
                              style: TextStyle(
                                color: isAdmin
                                    ? goldAccent
                                    : AppColors.textMuted,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isAdmin
                            ? 'Storage, Transcodes, Devices & Library Maintenance'
                            : 'Enter Admin PIN to unlock server management tools',
                        style: AppTypography.bodyMedium.copyWith(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: isFocused ? goldAccent : AppColors.textMuted,
                  size: 24,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
