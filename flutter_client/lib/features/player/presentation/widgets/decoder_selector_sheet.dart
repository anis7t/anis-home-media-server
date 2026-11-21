import 'package:flutter/material.dart';

import '../../../../core/widgets/tv_focusable.dart';
import '../../domain/player_models.dart';

/// Modal sheet for selecting hardware/software decoding acceleration mode.
///
/// Supports mobile touch, Fire TV, and Android TV D-pad navigation.
class DecoderSelectorSheet extends StatelessWidget {
  final DecoderMode currentMode;
  final ValueChanged<DecoderMode> onModeSelected;

  const DecoderSelectorSheet({
    super.key,
    required this.currentMode,
    required this.onModeSelected,
  });

  /// Displays the decoder selection sheet.
  static Future<void> show({
    required BuildContext context,
    required DecoderMode currentMode,
    required ValueChanged<DecoderMode> onModeSelected,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => DecoderSelectorSheet(
        currentMode: currentMode,
        onModeSelected: onModeSelected,
      ),
    );
  }

  static const List<DecoderMode> _modes = [
    DecoderMode.hardwareDirect,
    DecoderMode.hardwareCopy,
    DecoderMode.software,
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          decoration: BoxDecoration(
            color: const Color(0xFF161922),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 20,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    const Icon(
                      Icons.memory_rounded,
                      color: Color(0xFFFF334B),
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Hardware Acceleration / Decoder',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Switch decoding pipeline to resolve frame drops or rendering artifacts',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white54),
                      onPressed: () => Navigator.of(context).pop(),
                      tooltip: 'Close',
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white10, height: 1),

              // Mode list
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: _modes.map((mode) {
                    final isSelected = mode == currentMode;
                    return TvFocusable(
                      borderRadius: BorderRadius.circular(10),
                      onPressed: () {
                        onModeSelected(mode);
                        Navigator.of(context).pop();
                      },
                      builder: (context, isFocused, child) {
                        return Container(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: isFocused
                                ? Colors.white12
                                : (isSelected
                                    ? const Color(0x20FF334B)
                                    : Colors.transparent),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isFocused
                                  ? const Color(0xFFFF334B)
                                  : (isSelected
                                      ? const Color(0x60FF334B)
                                      : Colors.transparent),
                              width: isFocused ? 2 : 1,
                            ),
                          ),
                          child: ListTile(
                            onTap: () {
                              onModeSelected(mode);
                              Navigator.of(context).pop();
                            },
                            leading: Icon(
                              mode == DecoderMode.software
                                  ? Icons.speed_rounded
                                  : Icons.flash_on_rounded,
                              color: isSelected
                                  ? const Color(0xFFFF334B)
                                  : (isFocused ? Colors.white : Colors.white54),
                              size: 24,
                            ),
                            title: Row(
                              children: [
                                Text(
                                  mode.label,
                                  style: TextStyle(
                                    color: isSelected
                                        ? const Color(0xFFFF334B)
                                        : Colors.white,
                                    fontSize: 15,
                                    fontWeight: isSelected
                                        ? FontWeight.bold
                                        : FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? const Color(0x40FF334B)
                                        : Colors.white10,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    mode.toMpvHwdec(),
                                    style: TextStyle(
                                      color: isSelected
                                          ? const Color(0xFFFF334B)
                                          : Colors.white60,
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                mode.description,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            trailing: isSelected
                                ? const Icon(
                                    Icons.check_circle_rounded,
                                    color: Color(0xFFFF334B),
                                    size: 22,
                                  )
                                : null,
                          ),
                        );
                      },
                    );
                  }).toList(),
                ),
              ),

              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
