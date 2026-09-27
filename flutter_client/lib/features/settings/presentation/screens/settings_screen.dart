import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../updater/presentation/widgets/settings_content.dart';

/// Full-screen Settings tab embedded in the persistent bottom navigation shell.
/// Reuses [SettingsContent] to share exact update channel, server, and version logic.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildFrostedHeader(),
            const Expanded(
              child: SettingsContent(
                isModal: false,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFrostedHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.borderMedium),
              boxShadow: const [
                BoxShadow(
                  color: AppColors.brandRedGlow,
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: const Center(
              child: Icon(
                Icons.settings_rounded,
                color: AppColors.brandRed,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Settings & Updates',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'PREFERENCES • CHANNELS • SYSTEM',
                  style: AppTypography.labelSmall.copyWith(
                    color: AppColors.textMuted,
                    letterSpacing: 1.2,
                    fontSize: 9.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
