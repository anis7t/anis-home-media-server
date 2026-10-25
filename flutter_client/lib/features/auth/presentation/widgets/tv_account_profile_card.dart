import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/theme/app_colors.dart';
import '../providers/auth_providers.dart';
import 'tv_admin_pin_pad.dart';
import 'tv_qr_pairing_screen.dart';

/// Android TV and 10-foot UI account status card for the TV Settings screen.
class TvAccountProfileCard extends ConsumerWidget {
  const TvAccountProfileCard({super.key});

  void _openQrPairing(BuildContext context) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => TvQrPairingScreen(
        onDismiss: () => Navigator.of(context).pop(),
      ),
    );
  }

  void _openPinPad(BuildContext context) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => Scaffold(
        backgroundColor: Colors.transparent,
        body: TvAdminPinPad(
          onSuccess: () => Navigator.of(context).pop(),
          onCancel: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authNotifierProvider);
    final identity = authState.identity;
    final isAuthenticated = authState.isAuthenticated;
    final isAdmin = authState.isAdmin;

    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF10141E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isAdmin
              ? AppColors.brandRed.withValues(alpha: 0.5)
              : AppColors.borderMedium,
          width: 1.5,
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: isAuthenticated
          ? _buildAuthenticatedContent(context, ref, identity, isAdmin)
          : _buildUnauthenticatedContent(context),
    );
  }

  Widget _buildUnauthenticatedContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.brandRedGlow,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.borderFocus),
              ),
              child: const Icon(
                Icons.tv_rounded,
                color: AppColors.brandRed,
                size: 28,
              ),
            ),
            const SizedBox(width: 16),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Guest Mode',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(width: 10),
                      _TvBadge(label: 'TV VIEWER', isHighlighted: false),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Sign in with your phone or remote control to access admin settings and history.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Divider(color: AppColors.borderSubtle, height: 1),
        const SizedBox(height: 18),

        // Action Buttons Row (D-pad Focusable)
        Row(
          children: [
            _TvCardButton(
              label: 'Pair with Phone (QR Code)',
              icon: Icons.qr_code_rounded,
              isPrimary: true,
              onPressed: () => _openQrPairing(context),
            ),
            const SizedBox(width: 14),
            _TvCardButton(
              label: 'Admin PIN Pad',
              icon: Icons.pin_rounded,
              isPrimary: false,
              onPressed: () => _openPinPad(context),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAuthenticatedContent(
    BuildContext context,
    WidgetRef ref,
    dynamic identity,
    bool isAdmin,
  ) {
    final name = identity?.name as String? ?? identity?.email as String? ?? 'User';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'U';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // User Letter Avatar
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: isAdmin ? AppColors.brandRedGlow : Colors.white.withValues(alpha: 0.08),
            shape: BoxShape.circle,
            border: Border.all(
              color: isAdmin ? AppColors.brandRed : Colors.white.withValues(alpha: 0.2),
              width: 2,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            initial,
            style: TextStyle(
              color: isAdmin ? AppColors.brandRedLight : Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 18),

        // Identity Information
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 10),
                  _TvBadge(
                    label: isAdmin ? 'ADMIN' : 'VIEWER',
                    isHighlighted: isAdmin,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                identity?.email as String? ?? 'Signed In',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),

        // Sign Out Button
        _TvCardButton(
          label: 'Sign Out',
          icon: Icons.logout_rounded,
          isPrimary: false,
          onPressed: () async {
            await ref.read(authNotifierProvider.notifier).logout();
          },
        ),
      ],
    );
  }
}

class _TvBadge extends StatelessWidget {
  final String label;
  final bool isHighlighted;

  const _TvBadge({
    required this.label,
    required this.isHighlighted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isHighlighted
            ? AppColors.brandRedGlow
            : Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isHighlighted
              ? AppColors.brandRed.withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: 0.15),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isHighlighted ? AppColors.brandRedLight : AppColors.textSecondary,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _TvCardButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool isPrimary;
  final VoidCallback onPressed;

  const _TvCardButton({
    required this.label,
    required this.icon,
    required this.isPrimary,
    required this.onPressed,
  });

  @override
  State<_TvCardButton> createState() => _TvCardButtonState();
}

class _TvCardButtonState extends State<_TvCardButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.isPrimary
        ? AppColors.brandRed
        : Colors.white.withValues(alpha: 0.06);

    return Focus(
      onFocusChange: (focused) {
        setState(() {
          _isFocused = focused;
        });
      },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter) {
            widget.onPressed();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: _isFocused ? AppColors.brandRedLight : bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _isFocused ? Colors.white : AppColors.borderSubtle,
            width: _isFocused ? 2.0 : 1.0,
          ),
          boxShadow: _isFocused
              ? [
                  BoxShadow(
                    color: AppColors.brandRed.withValues(alpha: 0.6),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.icon,
                    size: 18,
                    color: _isFocused ? Colors.white : AppColors.textPrimary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: _isFocused ? Colors.white : AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
