import 'package:flutter/material.dart';

import '../../../../core/widgets/tv_focusable.dart';
import '../../domain/quality_option.dart';

/// Modal sheet for selecting video playback quality on mobile touch and Fire TV / Android TV D-pad.
class QualitySelectorSheet extends StatelessWidget {
  final List<QualityOption> qualityLadder;
  final String selectedQuality;
  final ValueChanged<QualityOption> onQualitySelected;
  final bool supportsDirectPlay;

  const QualitySelectorSheet({
    super.key,
    required this.qualityLadder,
    required this.selectedQuality,
    required this.onQualitySelected,
    this.supportsDirectPlay = true,
  });

  /// Displays the quality selection sheet.
  static Future<void> show({
    required BuildContext context,
    required List<QualityOption> qualityLadder,
    required String selectedQuality,
    required ValueChanged<QualityOption> onQualitySelected,
    bool supportsDirectPlay = true,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => QualitySelectorSheet(
        qualityLadder: qualityLadder,
        selectedQuality: selectedQuality,
        onQualitySelected: onQualitySelected,
        supportsDirectPlay: supportsDirectPlay,
      ),
    );
  }

  List<QualityOption> _buildDisplayItems() {
    final items = <QualityOption>[];

    // 1. Auto (Adaptive)
    items.add(QualityOption.auto);

    // 2. Original (Direct Play) if supported by device/container
    if (supportsDirectPlay) {
      final directOpt = qualityLadder.where((q) => q.isDirect).firstOrNull;
      if (directOpt != null) {
        items.add(directOpt);
      } else {
        items.add(
          const QualityOption(
            label: 'Original (Direct Play)',
            quality: 'source',
            height: 0,
            width: 0,
            bitrate: 0,
            isDirect: true,
            isReady: true,
          ),
        );
      }
    }

    // 3. Dynamic resolution tiers from backend quality ladder
    for (final opt in qualityLadder) {
      if (opt.isDirect) continue;
      items.add(opt);
    }

    return items;
  }

  String _formatOptionTitle(QualityOption option) {
    if (option.quality == 'auto') return 'Auto (Adaptive Stream)';
    if (option.isDirect || option.quality == 'source') {
      if (option.height >= 2160 || option.width >= 3840) {
        return 'Original (4K Direct Play - Lossless)';
      }
      return 'Original (Direct Play)';
    }
    if (option.label.isNotEmpty) return option.label;
    if (option.quality == '2160p' || option.quality == '4k') {
      return '2160p (4K HEVC Stream)';
    }
    return '${option.quality.toUpperCase()} Stream';
  }

  String? _formatOptionSubtitle(QualityOption option) {
    if (option.quality == 'auto') {
      return 'Dynamically adjusts quality based on your network speed';
    }
    if (option.isDirect || option.quality == 'source') {
      final details = <String>[];
      if (option.dimensionsLabel.isNotEmpty) details.add(option.dimensionsLabel);
      details.add('Bitstream direct play without transcoding');
      return details.join(' • ');
    }
    final details = <String>[];
    if (option.dimensionsLabel.isNotEmpty) {
      details.add(option.dimensionsLabel);
    }
    if (option.formattedBitrate.isNotEmpty) {
      details.add(option.formattedBitrate);
    }
    if (option.quality == '2160p' || option.quality == '4k') {
      details.add('HEVC stream');
    }
    if (details.isEmpty) return null;
    return details.join(' • ');
  }

  @override
  Widget build(BuildContext context) {
    final items = _buildDisplayItems();
    final hasMatch = items.any((q) => q.quality == selectedQuality);

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
                    Icons.high_quality_rounded,
                    color: Color(0xFFFF334B),
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Playback Quality',
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
                    focusNode: FocusNode(canRequestFocus: false),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0x1FFFFFFF), height: 1),
            // Quality options list
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.55,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int idx = 0; idx < items.length; idx++) ...[
                      () {
                        final option = items[idx];
                        final isSelected = selectedQuality == option.quality;
                        final isAutofocus = isSelected || (!hasMatch && idx == 0);
                        final subtitle = _formatOptionSubtitle(option);

                        return TvFocusable(
                          autofocus: isAutofocus,
                          borderRadius: BorderRadius.circular(10),
                          onPressed: () {
                            onQualitySelected(option);
                            Navigator.of(context).pop();
                          },
                          builder: (context, isFocused, child) {
                            return Container(
                              height: subtitle != null ? 60 : 52,
                              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
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
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              _formatOptionTitle(option),
                                              style: TextStyle(
                                                color: isSelected
                                                    ? const Color(0xFFFF334B)
                                                    : Colors.white,
                                                fontSize: 14,
                                                fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                              ),
                                            ),
                                            if (!option.isReady && !option.isDirect && option.quality != 'auto') ...[
                                              const SizedBox(width: 8),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                                decoration: BoxDecoration(
                                                  color: const Color(0x26FF9800),
                                                  borderRadius: BorderRadius.circular(4),
                                                  border: Border.all(color: const Color(0x66FF9800)),
                                                ),
                                                child: const Text(
                                                  'ON-DEMAND',
                                                  style: TextStyle(
                                                    color: Color(0xFFFFB74D),
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        if (subtitle != null) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            subtitle,
                                            style: TextStyle(
                                              color: Colors.white.withValues(alpha: 0.65),
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  if (isSelected)
                                    const Icon(
                                      Icons.check_circle_rounded,
                                      color: Color(0xFFFF334B),
                                      size: 20,
                                    ),
                                ],
                              ),
                            );
                          },
                        );
                      }(),
                    ],
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
