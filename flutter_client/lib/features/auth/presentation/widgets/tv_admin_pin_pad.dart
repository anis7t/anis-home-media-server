import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/theme/app_colors.dart';
import '../providers/auth_providers.dart';

/// Full-screen or modal 10-key numeric PIN pad navigable via Android TV D-pad remote.
class TvAdminPinPad extends ConsumerStatefulWidget {
  final VoidCallback? onSuccess;
  final VoidCallback? onCancel;

  const TvAdminPinPad({
    super.key,
    this.onSuccess,
    this.onCancel,
  });

  @override
  ConsumerState<TvAdminPinPad> createState() => _TvAdminPinPadState();
}

class _TvAdminPinPadState extends ConsumerState<TvAdminPinPad> {
  final List<String> _enteredDigits = [];
  bool _isLoading = false;
  String? _errorMessage;
  bool _rememberPin = true;

  void _onDigitPressed(String digit) {
    if (_isLoading) return;
    if (_enteredDigits.length >= 4) return;

    setState(() {
      _errorMessage = null;
      _enteredDigits.add(digit);
    });

    if (_enteredDigits.length == 4) {
      _submitPin();
    }
  }

  void _onBackspacePressed() {
    if (_isLoading || _enteredDigits.isEmpty) return;
    setState(() {
      _errorMessage = null;
      _enteredDigits.removeLast();
    });
  }

  void _onClearAllPressed() {
    if (_isLoading || _enteredDigits.isEmpty) return;
    setState(() {
      _errorMessage = null;
      _enteredDigits.clear();
    });
  }

  Future<void> _submitPin() async {
    if (_enteredDigits.length != 4) {
      setState(() {
        _errorMessage = 'Please enter a 4-digit PIN';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final pin = _enteredDigits.join();
    final success =
        await ref.read(authNotifierProvider.notifier).loginWithPin(pin);

    if (!mounted) return;

    if (success) {
      if (_rememberPin) {
        await ref.read(authSecureStorageProvider).saveAdminPin(pin);
      }
      setState(() {
        _isLoading = false;
      });
      widget.onSuccess?.call();
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Invalid PIN. Please try again.';
        _enteredDigits.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          final logicalKey = event.logicalKey;
          if (logicalKey == LogicalKeyboardKey.backspace ||
              logicalKey == LogicalKeyboardKey.delete) {
            _onBackspacePressed();
            return KeyEventResult.handled;
          }
          if (logicalKey == LogicalKeyboardKey.escape) {
            widget.onCancel?.call();
            return KeyEventResult.handled;
          }
          final char = event.character;
          if (char != null && RegExp(r'^[0-9]$').hasMatch(char)) {
            _onDigitPressed(char);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Center(
        child: Container(
          width: 480,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
          decoration: BoxDecoration(
            color: const Color(0xFF10141E),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.borderMedium, width: 1.5),
            boxShadow: const [
              BoxShadow(
                color: Colors.black87,
                blurRadius: 40,
                offset: Offset(0, 16),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.brandRedGlow,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.admin_panel_settings_rounded,
                      color: AppColors.brandRed,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Admin PIN Sign-In',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Use your remote control to enter the server PIN',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.onCancel != null)
                    _TvKeypadButton(
                      label: '✕',
                      width: 40,
                      height: 40,
                      backgroundColor: Colors.white.withValues(alpha: 0.05),
                      onPressed: widget.onCancel!,
                    ),
                ],
              ),
              const SizedBox(height: 24),

              // PIN Slot Indicators
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(4, (index) {
                  final isFilled = index < _enteredDigits.length;
                  return Container(
                    width: 44,
                    height: 52,
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: isFilled
                          ? AppColors.brandRedGlow
                          : Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isFilled
                            ? AppColors.brandRed
                            : Colors.white.withValues(alpha: 0.15),
                        width: 1.5,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: isFilled
                        ? Container(
                            width: 12,
                            height: 12,
                            decoration: const BoxDecoration(
                              color: AppColors.textPrimary,
                              shape: BoxShape.circle,
                            ),
                          )
                        : null,
                  );
                }),
              ),
              const SizedBox(height: 16),

              // Error feedback
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.statusError.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.statusError.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline_rounded,
                          color: AppColors.statusError, size: 16),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(
                            color: AppColors.statusError,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // 10-key numeric grid (3 columns x 4 rows)
              Column(
                children: [
                  _buildKeypadRow(['1', '2', '3']),
                  const SizedBox(height: 8),
                  _buildKeypadRow(['4', '5', '6']),
                  const SizedBox(height: 8),
                  _buildKeypadRow(['7', '8', '9']),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _TvKeypadButton(
                        label: '⌫',
                        width: 72,
                        height: 52,
                        onPressed: _onBackspacePressed,
                        backgroundColor: Colors.white.withValues(alpha: 0.06),
                      ),
                      const SizedBox(width: 12),
                      _TvKeypadButton(
                        label: '0',
                        width: 72,
                        height: 52,
                        onPressed: () => _onDigitPressed('0'),
                      ),
                      const SizedBox(width: 12),
                      _TvKeypadButton(
                        label: _isLoading ? '...' : '✓',
                        width: 72,
                        height: 52,
                        backgroundColor: _enteredDigits.length == 4
                            ? AppColors.brandRed
                            : Colors.white.withValues(alpha: 0.06),
                        onPressed: _submitPin,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Clear row / Remember PIN toggle
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: _enteredDigits.isNotEmpty ? _onClearAllPressed : null,
                    icon: const Icon(Icons.restart_alt_rounded, size: 16),
                    label: const Text('Clear All', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                    ),
                  ),
                  InkWell(
                    onTap: () {
                      setState(() {
                        _rememberPin = !_rememberPin;
                      });
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _rememberPin
                                ? Icons.check_box_rounded
                                : Icons.check_box_outline_blank_rounded,
                            size: 16,
                            color: _rememberPin ? AppColors.brandRed : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'Remember PIN on TV',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
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

  Widget _buildKeypadRow(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: digits.map((digit) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: _TvKeypadButton(
            label: digit,
            width: 72,
            height: 52,
            onPressed: () => _onDigitPressed(digit),
          ),
        );
      }).toList(),
    );
  }
}

/// D-pad focusable TV keypad button with spatial outline and hover/focus elevation.
class _TvKeypadButton extends StatefulWidget {
  final String label;
  final double width;
  final double height;
  final VoidCallback onPressed;
  final Color? backgroundColor;

  const _TvKeypadButton({
    required this.label,
    required this.width,
    required this.height,
    required this.onPressed,
    this.backgroundColor,
  });

  @override
  State<_TvKeypadButton> createState() => _TvKeypadButtonState();
}

class _TvKeypadButtonState extends State<_TvKeypadButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.backgroundColor ?? AppColors.surfaceElevated;

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
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: _isFocused ? AppColors.brandRed : bg,
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
            child: Center(
              child: Text(
                widget.label,
                style: TextStyle(
                  color: _isFocused ? Colors.white : AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
