import 'package:flutter/material.dart';

import '../../domain/player_models.dart';

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
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: displayTracks.length,
                itemBuilder: (ctx, idx) {
                  final track = displayTracks[idx];
                  final isSelected = currentTrack.id == track.id;
                  final subtitle = _formatTrackSubtitle(track);

                  return InkWell(
                    onTap: () {
                      onTrackSelected(track);
                      Navigator.of(context).pop();
                    },
                    child: Container(
                      height: subtitle != null ? 58 : 52,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
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
                                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
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
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// Modal bottom sheet for choosing between available Subtitle Tracks.
class SubtitleTrackSheet extends StatelessWidget {
  final List<PlayerSubtitleTrack> tracks;
  final PlayerSubtitleTrack currentTrack;
  final ValueChanged<PlayerSubtitleTrack> onTrackSelected;

  const SubtitleTrackSheet({
    super.key,
    required this.tracks,
    required this.currentTrack,
    required this.onTrackSelected,
  });

  /// Displays the subtitle track selection sheet.
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

  String _formatTrackTitle(PlayerSubtitleTrack track) {
    if (track.id == 'no') return 'Off';
    if (track.id == 'auto') return 'Auto';
    return track.title.isNotEmpty ? track.title : 'Track ${track.id}';
  }

  @override
  Widget build(BuildContext context) {
    // Ensure 'Off' is first option
    final displayTracks = <PlayerSubtitleTrack>[];
    if (!tracks.any((t) => t.id == 'no')) {
      displayTracks.add(PlayerSubtitleTrack.no);
    }
    displayTracks.addAll(tracks);

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
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: displayTracks.length,
                itemBuilder: (ctx, idx) {
                  final track = displayTracks[idx];
                  final isSelected = currentTrack.id == track.id;

                  return InkWell(
                    onTap: () {
                      onTrackSelected(track);
                      Navigator.of(context).pop();
                    },
                    child: Container(
                      height: 52,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    _formatTrackTitle(track),
                                    style: TextStyle(
                                      color: isSelected ? const Color(0xFFFF334B) : Colors.white,
                                      fontSize: 15,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (track.isExternal) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
