import 'package:flutter/material.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/widgets/tv_focusable.dart';

/// Modal dialog displaying privacy guarantees, operational telemetry scope,
/// and self-hosted architectural principles for the media server platform.
class PrivacyPolicyDialog extends StatelessWidget {
  const PrivacyPolicyDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surfaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.borderMedium),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.statusSuccess.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.statusSuccess.withValues(alpha: 0.35),
                      ),
                    ),
                    child: const Icon(
                      Icons.shield_outlined,
                      color: AppColors.statusSuccess,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Privacy & Architecture',
                      style: AppTypography.titleLarge.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close_rounded,
                      color: AppColors.textMuted,
                      size: 20,
                    ),
                    onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Scrollable Content
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSection(
                        title: 'Zero Third-Party Tracking',
                        body:
                            "Anis' Home Media Server is a private, self-hosted media platform. It contains zero advertising trackers, analytics SDKs, marketing beacons, or third-party cookies. Your personal data, browsing behavior, and watch activity are never transmitted, sold, or shared with external parties.",
                      ),
                      const SizedBox(height: 14),
                      _buildSection(
                        title: 'First-Party Operational Diagnostics',
                        body:
                            'The server gathers internal operational telemetry—including hardware GPU/CPU utilization, playback performance metrics ("Stats for Nerds"), client device hints, and network presence heartbeats—strictly for local media transcoding orchestration and fleet management. Telemetry is privacy-scoped to your active device by default.',
                      ),
                      const SizedBox(height: 14),
                      _buildSection(
                        title: 'Local Database Persistence',
                        body:
                            "Playback progress, user accounts, and paired device identities are stored strictly in the server's local PostgreSQL database on your host machine.",
                      ),
                      const SizedBox(height: 14),
                      _buildSection(
                        title: 'External Media Metadata',
                        body:
                            'During media library scans, the backend server makes direct API queries to The Movie Database (TMDb) solely to fetch poster artwork, ratings, and synopses. No user identities or viewing activity are included in these metadata requests.',
                      ),
                      const SizedBox(height: 14),
                      _buildSection(
                        title: 'Encrypted Remote Transport',
                        body:
                            'Remote access is routed through a dedicated Cloudflare Named Tunnel strictly as an encrypted transport bridge; no user-facing trackers or third-party cookies are injected.',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Close Action
              Align(
                alignment: Alignment.centerRight,
                child: TvFocusable(
                  borderRadius: BorderRadius.circular(8),
                  borderWidth: 2,
                  focusedBorderColor: AppColors.brandRedLight,
                  focusedBackgroundColor: AppColors.surfaceHighlight,
                  onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.brandRed,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Close',
                      style: TextStyle(
                        color: AppColors.textOnBrand,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSection({required String title, required String body}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: AppTypography.bodyMedium.copyWith(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          body,
          style: AppTypography.bodyMedium.copyWith(
            color: AppColors.textSecondary,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}
