import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../cast/presentation/controllers/cast_controller.dart';

/// Compact remote control pill for the active casting session.
class PlayerCastBar extends ConsumerWidget {
  final CastState cast;

  const PlayerCastBar({
    super.key,
    required this.cast,
  });

  static String formatDuration(Duration d) {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final device = cast.activeDevice;
    if (device == null) return const SizedBox.shrink();
    final isPlaying = cast.playbackState == 'playing';
    final activelyPlaying = cast.playbackState == 'playing' || cast.playbackState == 'paused';
    final label = switch (cast.error != null && !activelyPlaying ? cast.error : cast.playbackState) {
      'playing' => formatDuration(cast.position),
      'paused' => 'Paused · ${formatDuration(cast.position)}',
      'buffering' => 'Starting…',
      'stopped' => 'Stopped',
      final other => other,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xE6141822),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFFF334B).withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cast_connected_rounded, color: Color(0xFFFF334B), size: 18),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 170),
            child: Text(
              '${device.name} · $label',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 12),
          InkWell(
            onTap: () => ref
                .read(castControllerProvider.notifier)
                .sendControl(isPlaying ? 'pause' : 'play'),
            child: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          InkWell(
            onTap: () => ref.read(castControllerProvider.notifier).sendControl('stop'),
            child: const Icon(
              Icons.stop_rounded,
              color: Color(0xFFFF334B),
              size: 20,
            ),
          ),
        ],
      ),
    );
  }
}
