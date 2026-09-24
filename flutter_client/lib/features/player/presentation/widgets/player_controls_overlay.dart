import 'package:flutter/material.dart';

import '../../domain/seek_preview_controller.dart';
import 'player_hud_toast.dart';
import 'video_timeline_bar.dart';

/// Full-featured controls overlay for Phase 3.
///
/// Features top title/back bar, center play/pause tap target, interactive
/// touch/mouse timeline scrubber with seek preview thumbnails, HUD action toast,
/// and bottom control rail with play/pause, replay, volume/mute, time display,
/// speed selector, audio selector, subtitle selector, and fullscreen toggle.
class PlayerControlsOverlay extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool isVisible;
  final bool isPlaying;
  final bool isBuffering;
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final double volume;
  final bool isFullscreen;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onBack;
  final VoidCallback onUserInteraction;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<bool>? onScrubbingChanged;
  final SeekPreviewController? seekPreviewController;
  final Map<String, dynamic>? previewMeta;
  final SeekPreviewState? previewStateOverride;

  // Phase 3C enhancements
  final VoidCallback? onRestart;
  final VoidCallback? onOpenSpeedSheet;
  final VoidCallback? onOpenAudioSheet;
  final VoidCallback? onOpenSubtitleSheet;
  final double playbackRate;
  final bool hasActiveSubtitles;
  final String? hudMessage;
  final IconData? hudIcon;
  final bool isHudVisible;

  const PlayerControlsOverlay({
    super.key,
    required this.title,
    this.subtitle,
    required this.isVisible,
    required this.isPlaying,
    required this.isBuffering,
    required this.position,
    required this.duration,
    this.buffered = Duration.zero,
    required this.volume,
    required this.isFullscreen,
    required this.onTogglePlay,
    required this.onVolumeChanged,
    required this.onToggleMute,
    required this.onToggleFullscreen,
    required this.onBack,
    required this.onUserInteraction,
    required this.onSeek,
    this.onScrubbingChanged,
    this.seekPreviewController,
    this.previewMeta,
    this.previewStateOverride,
    this.onRestart,
    this.onOpenSpeedSheet,
    this.onOpenAudioSheet,
    this.onOpenSubtitleSheet,
    this.playbackRate = 1.0,
    this.hasActiveSubtitles = false,
    this.hudMessage,
    this.hudIcon,
    this.isHudVisible = false,
  });

  String _formatDuration(Duration d) {
    final s = d.inSeconds;
    final hours = s ~/ 3600;
    final minutes = (s % 3600) ~/ 60;
    final seconds = s % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: isVisible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 240),
      child: IgnorePointer(
        ignoring: !isVisible,
        child: Stack(
          children: [
            // Top gradient & header
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xCC0D111A),
                      Color(0x800D111A),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back',
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                        onPressed: onBack,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (subtitle != null && subtitle!.isNotEmpty)
                              Text(
                                subtitle!,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.65),
                                  fontSize: 12,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: isFullscreen ? 'Exit Fullscreen (f)' : 'Fullscreen (f)',
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        icon: Icon(
                          isFullscreen
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                          color: Colors.white,
                        ),
                        onPressed: onToggleFullscreen,
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // In-Player Action Feedback HUD Toast
            Positioned.fill(
              child: Align(
                alignment: const Alignment(0.0, -0.35),
                child: PlayerHudToast(
                  message: hudMessage,
                  icon: hudIcon,
                  isVisible: isHudVisible,
                ),
              ),
            ),

            // Center play/pause indicator (when paused or buffering)
            if (!isPlaying && !isBuffering)
              Center(
                child: GestureDetector(
                  onTap: onTogglePlay,
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xB3141822),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.2),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 16,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 48,
                    ),
                  ),
                ),
              ),

            // Bottom gradient & controls
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Color(0xEE0D111A),
                      Color(0x990D111A),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Interactive Video Timeline Scrubber Bar
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4.0),
                        child: VideoTimelineBar(
                          position: position,
                          duration: duration,
                          buffered: buffered,
                          onSeek: onSeek,
                          onScrubbingChanged: onScrubbingChanged,
                          seekPreviewController: seekPreviewController,
                          previewMeta: previewMeta,
                          previewStateOverride: previewStateOverride,
                        ),
                      ),

                      // Control buttons row with responsive layout
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final isCompact = constraints.maxWidth < 620;

                          return Row(
                            children: [
                              // Play / Pause button
                              IconButton(
                                tooltip: isPlaying ? 'Pause (Space / k)' : 'Play (Space / k)',
                                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                                icon: Icon(
                                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                  color: Colors.white,
                                  size: 26,
                                ),
                                onPressed: onTogglePlay,
                              ),

                              // Replay / Restart from beginning
                              if (onRestart != null)
                                IconButton(
                                  tooltip: 'Replay (Home / 0)',
                                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                                  icon: const Icon(
                                    Icons.replay_rounded,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                  onPressed: onRestart,
                                ),

                              const SizedBox(width: 2),

                              // Mute / Unmute
                              IconButton(
                                tooltip: volume == 0 ? 'Unmute (m)' : 'Mute (m)',
                                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                                icon: Icon(
                                  volume == 0
                                      ? Icons.volume_off_rounded
                                      : volume < 50
                                          ? Icons.volume_down_rounded
                                          : Icons.volume_up_rounded,
                                  color: Colors.white,
                                  size: 22,
                                ),
                                onPressed: onToggleMute,
                              ),

                              // Volume Slider (desktop / tablet only, hidden on compact mobile)
                              if (!isCompact) ...[
                                SizedBox(
                                  width: 80,
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 3,
                                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                                      activeTrackColor: const Color(0xFFFF334B),
                                      inactiveTrackColor: Colors.white24,
                                      thumbColor: Colors.white,
                                    ),
                                    child: Slider(
                                      value: volume.clamp(0.0, 100.0),
                                      min: 0.0,
                                      max: 100.0,
                                      onChanged: onVolumeChanged,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],

                              // Time Display
                              Text(
                                '${_formatDuration(position)} / ${_formatDuration(duration)}',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.85),
                                  fontSize: isCompact ? 12 : 13,
                                  fontWeight: FontWeight.w500,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),

                              const Spacer(),

                              // Playback Speed pill button
                              if (onOpenSpeedSheet != null)
                                InkWell(
                                  onTap: onOpenSpeedSheet,
                                  borderRadius: BorderRadius.circular(16),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.white12,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: playbackRate != 1.0
                                            ? const Color(0xFFFF334B)
                                            : Colors.white24,
                                        width: 1,
                                      ),
                                    ),
                                    child: Text(
                                      '${playbackRate.toStringAsFixed(playbackRate.truncateToDouble() == playbackRate ? 0 : 2)}×',
                                      style: TextStyle(
                                        color: playbackRate != 1.0
                                            ? const Color(0xFFFF334B)
                                            : Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),

                              // Audio Stream selector button
                              if (onOpenAudioSheet != null)
                                IconButton(
                                  tooltip: 'Audio Tracks',
                                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                                  icon: const Icon(
                                    Icons.audiotrack_rounded,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                  onPressed: onOpenAudioSheet,
                                ),

                              // Subtitle selector button
                              if (onOpenSubtitleSheet != null)
                                IconButton(
                                  tooltip: 'Subtitles (c)',
                                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                                  icon: Icon(
                                    Icons.subtitles_rounded,
                                    color: hasActiveSubtitles
                                        ? const Color(0xFFFF334B)
                                        : Colors.white,
                                    size: 20,
                                  ),
                                  onPressed: onOpenSubtitleSheet,
                                ),

                              // Fullscreen toggle
                              IconButton(
                                tooltip: isFullscreen ? 'Exit Fullscreen (f)' : 'Fullscreen (f)',
                                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                                icon: Icon(
                                  isFullscreen
                                      ? Icons.fullscreen_exit_rounded
                                      : Icons.fullscreen_rounded,
                                  color: Colors.white,
                                  size: 24,
                                ),
                                onPressed: onToggleFullscreen,
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

