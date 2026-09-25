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
class PlayerControlsOverlay extends StatefulWidget {
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
  final VoidCallback? onToggleRotate;
  final VoidCallback? onToggleAspectRatio;
  final VoidCallback? onSurfaceTap;
  final VoidCallback? onDoubleTapRewind;
  final VoidCallback? onDoubleTapForward;
  final double playbackRate;
  final bool hasActiveSubtitles;
  final bool isDoubleTapSeeking;
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
    this.onToggleRotate,
    this.onToggleAspectRatio,
    this.onSurfaceTap,
    this.onDoubleTapRewind,
    this.onDoubleTapForward,
    this.playbackRate = 1.0,
    this.hasActiveSubtitles = false,
    this.isDoubleTapSeeking = false,
    this.hudMessage,
    this.hudIcon,
    this.isHudVisible = false,
  });

  @override
  State<PlayerControlsOverlay> createState() => _PlayerControlsOverlayState();
}

class _PlayerControlsOverlayState extends State<PlayerControlsOverlay> {
  bool _showRemainingTime = false;

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
    final remainingSeconds = (widget.duration - widget.position).inSeconds;
    final remaining = remainingSeconds > 0
        ? Duration(seconds: remainingSeconds)
        : Duration.zero;

    return AnimatedOpacity(
      opacity: widget.isVisible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 240),
      child: IgnorePointer(
        ignoring: !widget.isVisible,
        child: Stack(
          children: [
            // Background touch area to toggle/hide controls or double-tap to seek when controls are visible
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onSurfaceTap,
                onDoubleTapDown: (details) {
                  final totalWidth = MediaQuery.of(context).size.width;
                  if (totalWidth <= 0) return;
                  final xRatio = details.localPosition.dx / totalWidth;
                  if (xRatio < 0.4) {
                    widget.onDoubleTapRewind?.call();
                  } else if (xRatio > 0.6) {
                    widget.onDoubleTapForward?.call();
                  }
                },
                onDoubleTap: () {},
              ),
            ),

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
                        onPressed: widget.onBack,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (widget.subtitle != null && widget.subtitle!.isNotEmpty)
                              Text(
                                widget.subtitle!,
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
                      if (widget.onToggleAspectRatio != null)
                        IconButton(
                          tooltip: 'Aspect Ratio',
                          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                          icon: const Icon(
                            Icons.aspect_ratio_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                          onPressed: widget.onToggleAspectRatio,
                        ),
                      if (widget.onToggleRotate != null)
                        IconButton(
                          tooltip: 'Rotate Screen',
                          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                          icon: const Icon(
                            Icons.screen_rotation_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                          onPressed: widget.onToggleRotate,
                        ),
                    ],
                  ),
                ),
              ),
            ),

            // In-Player Action Feedback HUD Toast
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: const Alignment(0.0, -0.35),
                  child: PlayerHudToast(
                    message: widget.hudMessage,
                    icon: widget.hudIcon,
                    isVisible: widget.isHudVisible,
                  ),
                ),
              ),
            ),

            // Center play/pause indicator (prominent circle when paused or playing with controls visible)
            // Suppressed during active double-tap seeking gestures and positioned slightly above center
            // to completely prevent vertical collision with the timeline scrubber bar.
            if (!widget.isBuffering && !widget.isDoubleTapSeeking)
              LayoutBuilder(
                builder: (context, constraints) {
                  final isCompact = constraints.maxWidth < 620;
                  return Align(
                    alignment: const Alignment(0.0, -0.22),
                    child: GestureDetector(
                      onTap: widget.onTogglePlay,
                      child: Container(
                        padding: EdgeInsets.all(isCompact ? 12 : 18),
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
                        child: Icon(
                          widget.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: isCompact ? 36 : 48,
                        ),
                      ),
                    ),
                  );
                },
              ),

            // Bottom gradient & controls
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: MediaQuery.of(context).size.width < 620 ? 8 : 16,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.50),
                      Colors.black.withValues(alpha: 0.15),
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
                      // 1. Time Display Row situated directly above the seekbar:
                      // Left: Time elapsed
                      // Right: Total time / Time remaining (toggle on tap)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              _formatDuration(widget.position),
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.95),
                                fontSize: MediaQuery.of(context).size.width < 620 ? 11.5 : 12.5,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.2,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                widget.onUserInteraction();
                                setState(() {
                                  _showRemainingTime = !_showRemainingTime;
                                });
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 4.0),
                                child: Text(
                                  _showRemainingTime
                                      ? '-${_formatDuration(remaining)}'
                                      : _formatDuration(widget.duration),
                                  style: TextStyle(
                                    color: _showRemainingTime
                                        ? const Color(0xFFFF334B)
                                        : Colors.white.withValues(alpha: 0.95),
                                    fontSize: MediaQuery.of(context).size.width < 620 ? 11.5 : 12.5,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.2,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // 2. Interactive Video Timeline Scrubber Bar:
                      // Vertically centered within compact touch target so spacing to time row
                      // above and control buttons below is completely symmetrical and lowered snug.
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2.0),
                        child: VideoTimelineBar(
                          position: widget.position,
                          duration: widget.duration,
                          buffered: widget.buffered,
                          onSeek: widget.onSeek,
                          onScrubbingChanged: widget.onScrubbingChanged,
                          seekPreviewController: widget.seekPreviewController,
                          previewMeta: widget.previewMeta,
                          previewStateOverride: widget.previewStateOverride,
                          touchTargetHeight: MediaQuery.of(context).size.width < 620 ? 16.0 : 22.0,
                        ),
                      ),

                      // Control buttons row with responsive layout
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final isCompact = constraints.maxWidth < 620;

                          final btnConstraints = BoxConstraints(
                            minWidth: isCompact ? 32 : 42,
                            minHeight: isCompact ? 32 : 42,
                          );

                          return Row(
                            children: [
                              // Replay / Restart from beginning (first button matching reference screenshot)
                              if (widget.onRestart != null)
                                IconButton(
                                  tooltip: 'Replay (Home / 0)',
                                  constraints: btnConstraints,
                                  padding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    Icons.replay_rounded,
                                    color: Colors.white,
                                    size: isCompact ? 19 : 22,
                                  ),
                                  onPressed: widget.onRestart,
                                ),

                              // Play / Pause button
                              IconButton(
                                tooltip: widget.isPlaying ? 'Pause (Space / k)' : 'Play (Space / k)',
                                constraints: btnConstraints,
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                                icon: Icon(
                                  widget.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                  color: Colors.white,
                                  size: isCompact ? 22 : 26,
                                ),
                                onPressed: widget.onTogglePlay,
                              ),

                              if (!isCompact) const SizedBox(width: 2),

                              // Mute / Unmute
                              IconButton(
                                tooltip: widget.volume == 0 ? 'Unmute (m)' : 'Mute (m)',
                                constraints: btnConstraints,
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                                icon: Icon(
                                  widget.volume == 0
                                      ? Icons.volume_off_rounded
                                      : widget.volume < 50
                                          ? Icons.volume_down_rounded
                                          : Icons.volume_up_rounded,
                                  color: Colors.white,
                                  size: isCompact ? 19 : 22,
                                ),
                                onPressed: widget.onToggleMute,
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
                                      value: widget.volume.clamp(0.0, 100.0),
                                      min: 0.0,
                                      max: 100.0,
                                      onChanged: widget.onVolumeChanged,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],

                              const Spacer(),

                              // Playback Speed pill button
                              if (widget.onOpenSpeedSheet != null)
                                InkWell(
                                  onTap: widget.onOpenSpeedSheet,
                                  borderRadius: BorderRadius.circular(14),
                                  child: Container(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: isCompact ? 5 : 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white12,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: widget.playbackRate != 1.0
                                            ? const Color(0xFFFF334B)
                                            : Colors.white24,
                                        width: 1,
                                      ),
                                    ),
                                    child: Text(
                                      '${widget.playbackRate.toStringAsFixed(widget.playbackRate.truncateToDouble() == widget.playbackRate ? 0 : 2)}×',
                                      style: TextStyle(
                                        color: widget.playbackRate != 1.0
                                            ? const Color(0xFFFF334B)
                                            : Colors.white,
                                        fontSize: isCompact ? 10 : 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),

                              // Audio Stream selector button
                              if (widget.onOpenAudioSheet != null)
                                IconButton(
                                  tooltip: 'Audio Tracks',
                                  constraints: btnConstraints,
                                  padding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    Icons.audiotrack_rounded,
                                    color: Colors.white,
                                    size: isCompact ? 18 : 20,
                                  ),
                                  onPressed: widget.onOpenAudioSheet,
                                ),

                              // Subtitle selector button
                              if (widget.onOpenSubtitleSheet != null)
                                IconButton(
                                  tooltip: 'Subtitles (c)',
                                  constraints: btnConstraints,
                                  padding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    Icons.subtitles_rounded,
                                    color: widget.hasActiveSubtitles
                                        ? const Color(0xFFFF334B)
                                        : Colors.white,
                                    size: isCompact ? 18 : 20,
                                  ),
                                  onPressed: widget.onOpenSubtitleSheet,
                                ),

                              // Fullscreen toggle
                              IconButton(
                                tooltip: widget.isFullscreen ? 'Exit Fullscreen (f)' : 'Fullscreen (f)',
                                constraints: btnConstraints,
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                                icon: Icon(
                                  widget.isFullscreen
                                      ? Icons.fullscreen_exit_rounded
                                      : Icons.fullscreen_rounded,
                                  color: Colors.white,
                                  size: isCompact ? 20 : 24,
                                ),
                                onPressed: widget.onToggleFullscreen,
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

