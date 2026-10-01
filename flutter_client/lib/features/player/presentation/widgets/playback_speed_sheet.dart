import 'package:flutter/material.dart';

import '../../../../core/widgets/tv_focusable.dart';

/// Modal bottom sheet for selecting playback speed.
///
/// Designed with obsidian glass styling and high touch-target heights (>= 52dp)
/// for comfortable Android and desktop interaction.
class PlaybackSpeedSheet extends StatelessWidget {
  final double currentRate;
  final ValueChanged<double> onRateSelected;

  static const List<double> supportedRates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  const PlaybackSpeedSheet({
    super.key,
    required this.currentRate,
    required this.onRateSelected,
  });

  /// Displays the playback speed sheet.
  static Future<void> show({
    required BuildContext context,
    required double currentRate,
    required ValueChanged<double> onRateSelected,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => PlaybackSpeedSheet(
        currentRate: currentRate,
        onRateSelected: onRateSelected,
      ),
    );
  }

  String _formatRate(double rate) {
    if (rate == 1.0) return '1.0× (Normal)';
    String str = rate.toString();
    if (str.endsWith('.0')) str = str.substring(0, str.length - 2);
    return '$str×';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF141822),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        border: Border(
          top: BorderSide(color: Color(0x33FFFFFF), width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle pill
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.speed_rounded,
                    color: Color(0xFFFF334B),
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Playback Speed',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0x1FFFFFFF), height: 1),
            // Speed options list
            ...supportedRates.map((rate) {
              final isSelected = (currentRate - rate).abs() < 0.05;
              return TvFocusable(
                borderRadius: BorderRadius.circular(10),
                onPressed: () {
                  onRateSelected(rate);
                  Navigator.of(context).pop();
                },
                builder: (context, isFocused, child) {
                  return Container(
                    height: 52,
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: isFocused
                          ? const Color(0x33FF334B)
                          : (isSelected ? Colors.white10 : Colors.transparent),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isFocused ? const Color(0xFFFF334B) : Colors.transparent,
                        width: isFocused ? 2.5 : 1.0,
                      ),
                      boxShadow: isFocused
                          ? const [
                              BoxShadow(
                                color: Color(0x99FF334B),
                                blurRadius: 14.0,
                                spreadRadius: 1.0,
                              ),
                            ]
                          : null,
                    ),
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: [
                        Text(
                          _formatRate(rate),
                          style: TextStyle(
                            color: isSelected ? const Color(0xFFFF334B) : Colors.white,
                            fontSize: 15,
                            fontWeight: isSelected || isFocused ? FontWeight.bold : FontWeight.w500,
                          ),
                        ),
                        const Spacer(),
                        if (isSelected)
                          const Icon(
                            Icons.check_rounded,
                            color: Color(0xFFFF334B),
                            size: 20,
                          ),
                      ],
                    ),
                  );
                },
              );
            }),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
