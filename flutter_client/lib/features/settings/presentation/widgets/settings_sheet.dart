import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import 'settings_content.dart';

/// Modal bottom sheet representation of application and server settings.
/// Reuses [SettingsContent] for zero duplicate logic.
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      maxChildSize: 0.92,
      minChildSize: 0.45,
      builder: (ctx, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.fromBorderSide(
              BorderSide(color: AppColors.borderMedium),
            ),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.settings_rounded,
                      color: AppColors.brandRed,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Settings',
                      style: AppTypography.titleLarge.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppColors.textSecondary,
                        size: 20,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(color: AppColors.borderSubtle, height: 1),

              // Reusable Settings Content
              Expanded(
                child: SettingsContent(
                  scrollController: scrollController,
                  isModal: true,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
