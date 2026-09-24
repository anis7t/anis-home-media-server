import 'package:flutter/material.dart';

/// Basic controls overlay for Phase 3A.
///
/// Features top title/back bar, center play/pause tap target, and bottom
/// control rail with play/pause, volume slider, mute toggle, time, and fullscreen.
class PlayerControlsOverlay extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool isVisible;
  final bool isPlaying;
  final bool isBuffering;
  final Duration position;
  final Duration duration;
  final double volume;
  final bool isFullscreen;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onBack;
  final VoidCallback onUserInteraction;

  const PlayerControlsOverlay({
    super.key,
    required this.title,
    this.subtitle,
    required this.isVisible,
    required this.isPlaying,
    required this.isBuffering,
    required this.position,
    required this.duration,
    required this.volume,
    required this.isFullscreen,
    required this.onTogglePlay,
    required this.onVolumeChanged,
    required this.onToggleMute,
    required this.onToggleFullscreen,
    required this.onBack,
    required this.onUserInteraction,
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
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back',
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
                        tooltip: isFullscreen ? 'Exit Fullscreen' : 'Fullscreen',
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                  child: Row(
                    children: [
                      // Play / Pause button
                      IconButton(
                        tooltip: isPlaying ? 'Pause (Space / k)' : 'Play (Space / k)',
                        icon: Icon(
                          isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 26,
                        ),
                        onPressed: onTogglePlay,
                      ),
                      const SizedBox(width: 4),

                      // Mute / Unmute
                      IconButton(
                        tooltip: volume == 0 ? 'Unmute' : 'Mute',
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

                      // Volume Slider (constrained width)
                      SizedBox(
                        width: 100,
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
                      const SizedBox(width: 8),

                      // Time Display
                      Text(
                        '${_formatDuration(position)} / ${_formatDuration(duration)}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),

                      const Spacer(),

                      // Fullscreen toggle
                      IconButton(
                        tooltip: isFullscreen ? 'Exit Fullscreen (f)' : 'Fullscreen (f)',
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
