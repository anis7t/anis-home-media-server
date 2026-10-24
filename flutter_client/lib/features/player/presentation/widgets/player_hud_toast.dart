import 'package:flutter/material.dart';

/// Translucent HUD overlay badge providing immediate visual feedback for player actions
/// (e.g. speed change, subtitle switch, volume change).
class PlayerHudToast extends StatelessWidget {
  final String? message;
  final IconData? icon;
  final bool isVisible;

  const PlayerHudToast({
    super.key,
    required this.message,
    this.icon,
    required this.isVisible,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: isVisible && message != null ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xE6141822),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.15),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, color: const Color(0xFFFF334B), size: 20),
                  const SizedBox(width: 8),
                ],
                Text(
                  message ?? '',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
