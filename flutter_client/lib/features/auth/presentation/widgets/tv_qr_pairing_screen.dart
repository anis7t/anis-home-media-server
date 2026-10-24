import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../../app/theme/app_colors.dart';
import '../controllers/tv_qr_pair_controller.dart';
import '../providers/auth_providers.dart';
import 'tv_admin_pin_pad.dart';

/// Full-screen or modal Android TV QR code pairing view with spatial D-pad focus.
class TvQrPairingScreen extends ConsumerStatefulWidget {
  final VoidCallback? onDismiss;

  const TvQrPairingScreen({
    super.key,
    this.onDismiss,
  });

  @override
  ConsumerState<TvQrPairingScreen> createState() => _TvQrPairingScreenState();
}

class _TvQrPairingScreenState extends ConsumerState<TvQrPairingScreen> {
  bool _showPinPad = false;

  String _formatTime(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_showPinPad) {
      return Scaffold(
        backgroundColor: AppColors.background.withValues(alpha: 0.95),
        body: TvAdminPinPad(
          onSuccess: () {
            widget.onDismiss?.call();
          },
          onCancel: () {
            setState(() {
              _showPinPad = false;
            });
          },
        ),
      );
    }

    final qrState = ref.watch(tvQrPairControllerProvider);

    // Auto-dismiss once confirmed and finalized
    ref.listen<TvQrPairState>(tvQrPairControllerProvider, (prev, next) {
      if (next.status == TvQrStateStatus.confirmed) {
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (mounted) {
            widget.onDismiss?.call();
          }
        });
      }
    });

    return Scaffold(
      backgroundColor: AppColors.background.withValues(alpha: 0.95),
      body: FocusScope(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.escape ||
                event.logicalKey == LogicalKeyboardKey.backspace) {
              widget.onDismiss?.call();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Center(
          child: Container(
            width: 760,
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              color: const Color(0xFF10141E),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: AppColors.borderMedium, width: 1.5),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black87,
                  blurRadius: 48,
                  offset: Offset(0, 20),
                ),
              ],
            ),
            child: _buildBody(context, qrState),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, TvQrPairState qrState) {
    switch (qrState.status) {
      case TvQrStateStatus.loading:
        return const SizedBox(
          height: 320,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: AppColors.brandRed),
                SizedBox(height: 20),
                Text(
                  'Generating secure pairing session...',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
        );

      case TvQrStateStatus.confirmed:
        return SizedBox(
          height: 320,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: const BoxDecoration(
                    color: Color(0xFF10B981),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    color: Colors.white,
                    size: 44,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Device Paired Successfully!',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Signing in to your Media Server...',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        );

      case TvQrStateStatus.expired:
        return SizedBox(
          height: 320,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.timer_off_rounded,
                  color: AppColors.statusWarning,
                  size: 56,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Pairing Code Expired',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'For security, codes expire after 2 minutes.',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _TvActionButton(
                      label: '↻ Generate New Code',
                      isPrimary: true,
                      onPressed: () {
                        ref.read(tvQrPairControllerProvider.notifier).startSession();
                      },
                    ),
                    const SizedBox(width: 16),
                    _TvActionButton(
                      label: 'Enter Admin PIN',
                      isPrimary: false,
                      onPressed: () {
                        setState(() {
                          _showPinPad = true;
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );

      case TvQrStateStatus.error:
        return SizedBox(
          height: 320,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  color: AppColors.statusError,
                  size: 56,
                ),
                const SizedBox(height: 16),
                Text(
                  qrState.errorMessage ?? 'Pairing failed',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 24),
                _TvActionButton(
                  label: '↻ Retry Connection',
                  isPrimary: true,
                  onPressed: () {
                    ref.read(tvQrPairControllerProvider.notifier).startSession();
                  },
                ),
              ],
            ),
          ),
        );

      case TvQrStateStatus.waiting:
        final session = qrState.session!;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Left: QR Code Display
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black45,
                    blurRadius: 20,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: QrImageView(
                data: session.qrUrl,
                version: QrVersions.auto,
                size: 220,
                backgroundColor: Colors.white,
                padding: EdgeInsets.zero,
              ),
            ),
            const SizedBox(width: 36),

            // Right: Code & Instructions
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.brandRedGlow,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AppColors.borderFocus),
                        ),
                        child: const Text(
                          'FAST TV SIGN-IN',
                          style: TextStyle(
                            color: AppColors.brandRedLight,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ),
                      const Spacer(),
                      // Countdown pill
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.schedule_rounded,
                              size: 14,
                              color: AppColors.textSecondary,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              _formatTime(qrState.remainingSeconds),
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Scan with your phone camera',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Or open Settings > Link TV on your phone and enter:',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 14),

                  // 5-Character Pairing Code Badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.borderMedium),
                    ),
                    child: Text(
                      session.code.split('').join('  '),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 4.0,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Action Buttons
                  Row(
                    children: [
                      _TvActionButton(
                        label: 'Admin PIN Pad',
                        icon: Icons.pin_rounded,
                        isPrimary: false,
                        onPressed: () {
                          setState(() {
                            _showPinPad = true;
                          });
                        },
                      ),
                      const SizedBox(width: 12),
                      _TvActionButton(
                        label: 'Cancel',
                        isPrimary: false,
                        onPressed: () {
                          widget.onDismiss?.call();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
    }
  }
}

/// D-pad focusable TV action button with spatial highlight.
class _TvActionButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final bool isPrimary;
  final VoidCallback onPressed;

  const _TvActionButton({
    required this.label,
    this.icon,
    this.isPrimary = false,
    required this.onPressed,
  });

  @override
  State<_TvActionButton> createState() => _TvActionButtonState();
}

class _TvActionButtonState extends State<_TvActionButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.isPrimary ? AppColors.brandRed : AppColors.surfaceElevated;

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
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _isFocused ? Colors.white : AppColors.borderSubtle,
            width: _isFocused ? 2.0 : 1.0,
          ),
          boxShadow: _isFocused
              ? [
                  BoxShadow(
                    color: AppColors.brandRed.withValues(alpha: 0.6),
                    blurRadius: 14,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.icon != null) ...[
                    Icon(
                      widget.icon,
                      size: 16,
                      color: _isFocused ? Colors.white : AppColors.textPrimary,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: _isFocused ? Colors.white : AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
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
