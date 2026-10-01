import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/widgets/tv_focusable.dart';

/// TV-friendly confirmation dialog prompted when pressing Back at the root Home screen.
class TvExitDialog extends StatefulWidget {
  const TvExitDialog({super.key});

  static bool _isShowing = false;

  /// Displays the TV exit dialog and returns true if the user confirmed exit.
  static Future<bool> show(BuildContext context) async {
    if (_isShowing) return false;
    _isShowing = true;
    try {
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black.withValues(alpha: 0.75),
        builder: (ctx) => const TvExitDialog(),
      );
      return result ?? false;
    } finally {
      _isShowing = false;
    }
  }

  @override
  State<TvExitDialog> createState() => _TvExitDialogState();
}

class _TvExitDialogState extends State<TvExitDialog> {
  bool _canDismissOnBack = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) {
        setState(() {
          _canDismissOnBack = true;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // Debounce: ignore any back event arriving within 350ms of opening to eliminate
        // double-invocation from the initial hardware key release / Android OS back event.
        if (!_canDismissOnBack) {
          return;
        }
        Navigator.of(context).pop(false);
      },
      child: Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: Container(
        width: 440,
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderMedium, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.7),
              blurRadius: 32,
              spreadRadius: 4,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
                    child: Icon(
                      Icons.power_settings_new_rounded,
                      color: AppColors.brandRedLight,
                      size: 24,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Exit Application?',
                    style: AppTypography.titleLarge.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Are you sure you want to close Anis\' Home Media Server?',
              style: AppTypography.bodyMedium.copyWith(
                color: AppColors.textSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Cancel button (Autofocused for safety)
                TvFocusable(
                  autofocus: true,
                  borderRadius: BorderRadius.circular(10),
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.borderMedium),
                    ),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),

                // Exit button
                TvFocusable(
                  borderRadius: BorderRadius.circular(10),
                  focusedBackgroundColor: AppColors.brandRed.withValues(alpha: 0.3),
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.brandRed,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'Exit',
                      style: TextStyle(
                        color: AppColors.textOnBrand,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
}
