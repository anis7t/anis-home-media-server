import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/tv_focusable.dart';
import '../../domain/player_models.dart';
import '../../domain/subtitle_settings.dart';

/// Modal bottom sheet for choosing between available Audio Tracks.
class AudioTrackSheet extends StatelessWidget {
  final List<PlayerAudioTrack> tracks;
  final PlayerAudioTrack currentTrack;
  final ValueChanged<PlayerAudioTrack> onTrackSelected;

  const AudioTrackSheet({
    super.key,
    required this.tracks,
    required this.currentTrack,
    required this.onTrackSelected,
  });

  /// Displays the audio track selection sheet.
  static Future<void> show({
    required BuildContext context,
    required List<PlayerAudioTrack> tracks,
    required PlayerAudioTrack currentTrack,
    required ValueChanged<PlayerAudioTrack> onTrackSelected,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => AudioTrackSheet(
        tracks: tracks,
        currentTrack: currentTrack,
        onTrackSelected: onTrackSelected,
      ),
    );
  }

  String _formatTrackTitle(PlayerAudioTrack track) {
    if (track.id == 'no') return 'Off';
    if (track.id == 'auto') return 'Auto (Default)';
    var label = track.title;
    if (label.isEmpty) {
      label = track.language != null ? 'Audio (${track.language})' : 'Track ${track.id}';
    }
    return label;
  }

  String? _formatTrackSubtitle(PlayerAudioTrack track) {
    final details = <String>[];
    if (track.channels != null && track.channels!.isNotEmpty) {
      details.add(track.channels!);
    }
    if (track.codec != null && track.codec!.isNotEmpty) {
      details.add(track.codec!.toUpperCase());
    }
    if (details.isEmpty) return null;
    return details.join(' • ');
  }

  @override
  Widget build(BuildContext context) {
    final displayTracks = tracks.isEmpty
        ? [const PlayerAudioTrack(id: 'auto', title: 'Default Audio')]
        : tracks;

    final hasMatch = displayTracks.any((t) => t.id == currentTrack.id);

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
                    Icons.audiotrack_rounded,
                    color: Color(0xFFFF334B),
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Audio Tracks',
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
            // Tracks list
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.45,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int idx = 0; idx < displayTracks.length; idx++) ...[
                      () {
                        final track = displayTracks[idx];
                        final isSelected = currentTrack.id == track.id;
                        final isAutofocus = isSelected || (!hasMatch && idx == 0);
                        final subtitle = _formatTrackSubtitle(track);

                        return TvFocusable(
                          autofocus: isAutofocus,
                          borderRadius: BorderRadius.circular(10),
                          onPressed: () {
                            onTrackSelected(track);
                            Navigator.of(context).pop();
                          },
                          builder: (context, isFocused, child) {
                            return Container(
                              height: subtitle != null ? 58 : 52,
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
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          _formatTrackTitle(track),
                                          style: TextStyle(
                                            color: isSelected ? const Color(0xFFFF334B) : Colors.white,
                                            fontSize: 15,
                                            fontWeight: isSelected || isFocused ? FontWeight.bold : FontWeight.w500,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (subtitle != null)
                                          Text(
                                            subtitle,
                                            style: TextStyle(
                                              color: Colors.white.withValues(alpha: 0.6),
                                              fontSize: 12,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                      ],
                                    ),
                                  ),
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
                      }(),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// Tabs available inside [SubtitleTrackSheet].
enum SubtitleSheetTab {
  tracks('Tracks'),
  size('Size'),
  position('Position');

  final String label;
  const SubtitleSheetTab(this.label);
}

/// Modal bottom sheet for choosing Subtitle Tracks and Subtitle Size/Position Settings.
class SubtitleTrackSheet extends ConsumerStatefulWidget {
  final List<PlayerSubtitleTrack> tracks;
  final PlayerSubtitleTrack currentTrack;
  final ValueChanged<PlayerSubtitleTrack> onTrackSelected;

  const SubtitleTrackSheet({
    super.key,
    required this.tracks,
    required this.currentTrack,
    required this.onTrackSelected,
  });

  /// Displays the subtitle track and settings selection sheet.
  static Future<void> show({
    required BuildContext context,
    required List<PlayerSubtitleTrack> tracks,
    required PlayerSubtitleTrack currentTrack,
    required ValueChanged<PlayerSubtitleTrack> onTrackSelected,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => SubtitleTrackSheet(
        tracks: tracks,
        currentTrack: currentTrack,
        onTrackSelected: onTrackSelected,
      ),
    );
  }

  @override
  ConsumerState<SubtitleTrackSheet> createState() => _SubtitleTrackSheetState();
}

class _SubtitleTrackSheetState extends ConsumerState<SubtitleTrackSheet> {
  SubtitleSheetTab _activeTab = SubtitleSheetTab.tracks;

  String _formatTrackTitle(PlayerSubtitleTrack track) {
    if (track.id == 'no') return 'Off';
    if (track.id == 'auto') return 'Auto';
    return track.title.isNotEmpty ? track.title : 'Track ${track.id}';
  }

  /// Deduplicates tracks ensuring Off and Auto appear first.
  List<PlayerSubtitleTrack> _getDeduplicatedTracks() {
    final list = <PlayerSubtitleTrack>[];
    final seen = <String>{};

    // 1. Off option always first
    list.add(PlayerSubtitleTrack.no);
    seen.add('no');

    // 2. Auto option second
    list.add(PlayerSubtitleTrack.auto);
    seen.add('auto');

    // 3. User & sidecar tracks
    for (final t in widget.tracks) {
      if (t.id == 'no' || t.id == 'auto') continue;
      // Deduplicate by clean ID or URL
      final key = t.id.trim().toLowerCase();
      if (seen.add(key)) {
        list.add(t);
      }
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final displayTracks = _getDeduplicatedTracks();
    final hasMatch = displayTracks.any((t) => t.id == widget.currentTrack.id);
    final subSettings = ref.watch(subtitleSettingsProvider);

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

            // Header & Navigation Tabs
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(
                children: [
                  const Icon(
                    Icons.subtitles_rounded,
                    color: Color(0xFFFF334B),
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Subtitles',
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

            // Section Tabs: [ Tracks ] [ Size ] [ Position ]
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: const Color(0x22FFFFFF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: SubtitleSheetTab.values.map((tab) {
                    final isTabActive = _activeTab == tab;
                    return Expanded(
                      child: TvFocusable(
                        borderRadius: BorderRadius.circular(8),
                        onPressed: () {
                          setState(() => _activeTab = tab);
                        },
                        builder: (context, isFocused, child) {
                          return Container(
                            height: 34,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: isTabActive
                                  ? const Color(0xFFFF334B)
                                  : (isFocused ? const Color(0x33FF334B) : Colors.transparent),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isFocused && !isTabActive
                                    ? const Color(0xFFFF334B)
                                    : Colors.transparent,
                                width: isFocused ? 2.0 : 1.0,
                              ),
                            ),
                            child: Text(
                              tab.label,
                              style: TextStyle(
                                color: isTabActive ? Colors.white : Colors.white70,
                                fontSize: 13,
                                fontWeight: isTabActive || isFocused
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),

            const Divider(color: Color(0x1FFFFFFF), height: 1),

            // Active Tab Content
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.45,
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: switch (_activeTab) {
                    SubtitleSheetTab.tracks => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (int idx = 0; idx < displayTracks.length; idx++) ...[
                            () {
                              final track = displayTracks[idx];
                              final isSelected = widget.currentTrack.id == track.id;
                              final isAutofocus = isSelected || (!hasMatch && idx == 0);

                              return TvFocusable(
                                autofocus: isAutofocus,
                                borderRadius: BorderRadius.circular(10),
                                onPressed: () {
                                  widget.onTrackSelected(track);
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
                                        color: isFocused
                                            ? const Color(0xFFFF334B)
                                            : Colors.transparent,
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
                                          child: Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  _formatTrackTitle(track),
                                                  style: TextStyle(
                                                    color: isSelected
                                                        ? const Color(0xFFFF334B)
                                                        : Colors.white,
                                                    fontSize: 15,
                                                    fontWeight: isSelected || isFocused
                                                        ? FontWeight.bold
                                                        : FontWeight.w500,
                                                  ),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                              if (track.isExternal) ...[
                                                const SizedBox(width: 8),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(
                                                      horizontal: 6, vertical: 2),
                                                  decoration: BoxDecoration(
                                                    color: Colors.white12,
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                  child: const Text(
                                                    'Local',
                                                    style: TextStyle(
                                                      color: Colors.white70,
                                                      fontSize: 10,
                                                      fontWeight: FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
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
                            }(),
                          ],
                        ],
                      ),

                    SubtitleSheetTab.size => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: SubtitleFontSize.values.map((size) {
                          final isSelected = subSettings.fontSize == size;
                          return TvFocusable(
                            autofocus: isSelected,
                            borderRadius: BorderRadius.circular(10),
                            onPressed: () {
                              ref.read(subtitleSettingsProvider.notifier).setFontSize(size);
                            },
                            builder: (context, isFocused, child) {
                              return Container(
                                height: 50,
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
                                child: Row(
                                  children: [
                                    Text(
                                      size.label,
                                      style: TextStyle(
                                        color: isSelected ? const Color(0xFFFF334B) : Colors.white,
                                        fontSize: 15,
                                        fontWeight: isSelected || isFocused
                                            ? FontWeight.bold
                                            : FontWeight.w500,
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
                        }).toList(),
                      ),

                    SubtitleSheetTab.position => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: SubtitleVerticalPosition.values.map((pos) {
                          final isSelected = subSettings.verticalPosition == pos;
                          return TvFocusable(
                            autofocus: isSelected,
                            borderRadius: BorderRadius.circular(10),
                            onPressed: () {
                              ref.read(subtitleSettingsProvider.notifier).setVerticalPosition(pos);
                            },
                            builder: (context, isFocused, child) {
                              return Container(
                                height: 50,
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
                                child: Row(
                                  children: [
                                    Text(
                                      pos.label,
                                      style: TextStyle(
                                        color: isSelected ? const Color(0xFFFF334B) : Colors.white,
                                        fontSize: 15,
                                        fontWeight: isSelected || isFocused
                                            ? FontWeight.bold
                                            : FontWeight.w500,
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
                        }).toList(),
                      ),
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
