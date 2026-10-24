import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../core/api/api_client.dart';
import '../providers/auth_providers.dart';
import 'admin_pin_sheet.dart';
import 'tv_pairing_sheet.dart';

/// Premium account profile card embedded in the Settings screen.
/// Displays authenticated user identity, role badges, Google Sign-In,
/// Admin PIN unlock, and Sign-Out actions.
class AccountProfileCard extends ConsumerWidget {
  const AccountProfileCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authNotifierProvider);
    final identity = authState.identity;
    final isAuthenticated = authState.isAuthenticated;
    final isAdmin = authState.isAdmin;
    final baseUrl = ref.watch(serverBaseUrlProvider);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isAdmin
              ? AppColors.brandRed.withValues(alpha: 0.35)
              : AppColors.borderSubtle,
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: isAdmin ? AppColors.brandRedGlow : Colors.black45,
            blurRadius: 20,
            spreadRadius: isAdmin ? 1 : 0,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // User Avatar & Identity Details
          Row(
            children: [
              _buildAvatar(identity, isAuthenticated),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            isAuthenticated
                                ? (identity?.name ?? identity?.email ?? 'User')
                                : 'Guest Mode',
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildRoleBadge(isAuthenticated, isAdmin, identity?.role),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      isAuthenticated
                          ? (identity?.email ?? 'Signed in')
                          : 'Browsing as local guest',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (isAuthenticated)
                IconButton(
                  icon: const Icon(
                    Icons.logout_rounded,
                    color: AppColors.textSecondary,
                    size: 20,
                  ),
                  tooltip: 'Sign Out',
                  onPressed: () async {
                    await ref.read(authNotifierProvider.notifier).logout();
                  },
                ),
            ],
          ),

          // Authenticated Actions (Link TV / Remote Device)
          if (isAuthenticated) ...[
            const SizedBox(height: 14),
            const Divider(color: AppColors.borderSubtle, height: 1),
            const SizedBox(height: 10),
            InkWell(
              onTap: () => TvPairingSheet.show(context),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: AppColors.brandRedGlow,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.tv_rounded,
                        size: 16,
                        color: AppColors.brandRed,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Link Android TV / Remote Device',
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'Enter 5-character code displayed on TV',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: AppColors.textSecondary,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
          ],

          // Unauthenticated Action Buttons (Google Sign-In & Admin PIN)
          if (!isAuthenticated) ...[
            const SizedBox(height: 18),
            const Divider(color: AppColors.borderSubtle, height: 1),
            const SizedBox(height: 16),
            Row(
              children: [
                // Google Sign-In Button
                Expanded(
                  flex: 3,
                  child: OutlinedButton.icon(
                    onPressed: authState.isLoading
                        ? null
                        : () async {
                            final launcher = ref.read(oauthLauncherServiceProvider);
                            final ok = await launcher.launchGoogleSignIn(baseUrl);
                            if (!ok && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Could not open browser for Google Sign-In'),
                                  backgroundColor: AppColors.brandRed,
                                ),
                              );
                            }
                          },
                    icon: const _GoogleIcon(),
                    label: const Text(
                      'Sign In with Google',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.borderMedium),
                      backgroundColor: AppColors.surface,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),

                // Admin PIN Button
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: authState.isLoading
                        ? null
                        : () {
                            AdminPinSheet.show(context);
                          },
                    icon: const Icon(
                      Icons.shield_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                    label: const Text(
                      'Admin PIN',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brandRed,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 2,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAvatar(dynamic identity, bool isAuthenticated) {
    final pictureUrl = identity?.pictureUrl as String?;
    final name = identity?.name as String? ?? identity?.email as String? ?? 'G';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'G';

    return Stack(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.surface,
            border: Border.all(
              color: isAuthenticated ? AppColors.brandRed : AppColors.borderMedium,
              width: 1.5,
            ),
          ),
          child: ClipOval(
            child: pictureUrl != null && pictureUrl.isNotEmpty
                ? Image.network(
                    pictureUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _buildLetterAvatar(initial),
                  )
                : _buildLetterAvatar(initial),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: 13,
            height: 13,
            decoration: BoxDecoration(
              color: isAuthenticated ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.surfaceElevated, width: 2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLetterAvatar(String initial) {
    return Container(
      color: AppColors.surface,
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildRoleBadge(bool isAuthenticated, bool isAdmin, String? role) {
    if (!isAuthenticated) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(9999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: const Text(
          'GUEST',
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      );
    }

    if (isAdmin) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.brandRedGlow,
          borderRadius: BorderRadius.circular(9999),
          border: Border.all(color: AppColors.brandRed.withValues(alpha: 0.5)),
        ),
        child: const Text(
          'ADMIN',
          style: TextStyle(
            color: Color(0xFFFCA5A5),
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(9999),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.4)),
      ),
      child: const Text(
        'VIEWER',
        style: TextStyle(
          color: Color(0xFF93C5FD),
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _GoogleIcon extends StatelessWidget {
  const _GoogleIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: const Text(
        'G',
        style: TextStyle(
          color: Color(0xFF4285F4),
          fontWeight: FontWeight.w900,
          fontSize: 12,
          height: 1,
        ),
      ),
    );
  }
}
