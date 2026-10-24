import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/device/infrastructure/device_capability_service.dart';
import '../../../../core/widgets/tv_focusable.dart';
import '../../data/models/movie_item.dart';
import '../../data/repositories/library_repository.dart';

/// Modal dialog presented when a movie requires 100% complete transcoding
/// before video streaming can commence.
class TranscodeGateDialog extends ConsumerStatefulWidget {
  final MovieItem movie;
  final VoidCallback onPlayReady;

  const TranscodeGateDialog({
    super.key,
    required this.movie,
    required this.onPlayReady,
  });

  /// Displays the transcode gate dialog.
  static Future<void> show(
    BuildContext context, {
    required MovieItem movie,
    required VoidCallback onPlayReady,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.8),
      builder: (ctx) => TranscodeGateDialog(
        movie: movie,
        onPlayReady: onPlayReady,
      ),
    );
  }

  @override
  ConsumerState<TranscodeGateDialog> createState() => _TranscodeGateDialogState();
}

class _TranscodeGateDialogState extends ConsumerState<TranscodeGateDialog> {
  Timer? _pollTimer;
  double _percent = 0.0;
  String _speed = '';
  String _eta = 'Calculating ETA...';
  String _timeStr = '0:00 / 0:00';
  bool _isReady = false;

  @override
  void initState() {
    super.initState();
    _startTranscodeAndPoll();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _startTranscodeAndPoll() async {
    final repo = ref.read(libraryRepositoryProvider);
    // Trigger transcode start
    await repo.startTranscode(widget.movie.filename);
    _pollStatus();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) => _pollStatus());
  }

  Future<void> _pollStatus() async {
    if (!mounted) return;
    final repo = ref.read(libraryRepositoryProvider);
    final data = await repo.getTranscodeStatus(widget.movie.filename);
    if (!mounted || data.isEmpty) return;

    final status = data['status']?.toString() ?? '';
    final pct = (data['percent'] is num) ? (data['percent'] as num).toDouble() : 0.0;
    final speedNum = (data['speed'] is num) ? (data['speed'] as num).toDouble() : 0.0;
    final remainingNum = (data['remaining'] is num) ? (data['remaining'] as num).toDouble() : null;
    final encodedNum = (data['encoded'] is num) ? (data['encoded'] as num).toDouble() : 0.0;
    final durNum = (data['duration'] is num) ? (data['duration'] as num).toDouble() : widget.movie.duration;

    String formatSecs(double s) {
      final total = s.toInt();
      final h = total ~/ 3600;
      final m = (total % 3600) ~/ 60;
      final sec = total % 60;
      if (h > 0) {
        return '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
      }
      return '$m:${sec.toString().padLeft(2, '0')}';
    }

    String formatEta(double? rem) {
      if (rem == null || rem.isInfinite || rem.isNaN) return 'Calculating ETA...';
      final total = rem.toInt();
      final h = total ~/ 3600;
      final m = (total % 3600) ~/ 60;
      final sec = total % 60;
      if (h > 0) {
        return '$h h $m m remaining';
      }
      return '$m m $sec s remaining';
    }

    setState(() {
      _percent = pct.clamp(0.0, 100.0);
      _speed = speedNum > 0 ? '${speedNum.toStringAsFixed(1)}×' : '';
      _eta = formatEta(remainingNum);
      _timeStr = '${formatSecs(encodedNum)} / ${formatSecs(durNum)}';

      if (status == 'ready' || _percent >= 100.0) {
        _isReady = true;
        _percent = 100.0;
        _eta = 'Ready to stream';
        _pollTimer?.cancel();
        _pollTimer = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isTv = ref.watch(isTvModeProvider);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 480,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderMedium, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.75),
              blurRadius: 32,
              spreadRadius: 4,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _isReady ? AppColors.statusSuccess : AppColors.brandRed,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _isReady ? '✓ Transcoding Complete' : 'Full Transcode Required',
                    style: AppTypography.titleMedium.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: AppColors.textMuted, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: 'Close',
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Description
            Text(
              _isReady
                  ? 'Dual-GPU conversion is complete! You can now start streaming with full seek support.'
                  : 'This title requires 100% complete transcoding before streaming begins. Dual-GPU conversion is running.',
              style: AppTypography.bodyMedium.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),

            // Telemetry Card
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _isReady ? '✓ Transcode Ready' : '⚡ Dual-GPU Transcoding',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        '${_percent.toStringAsFixed(1)}%',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: _isReady ? AppColors.statusSuccess : AppColors.brandRed,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Progress Bar
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _percent / 100.0,
                      minHeight: 7,
                      backgroundColor: Colors.white12,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _isReady ? AppColors.statusSuccess : AppColors.brandRed,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Telemetry meta
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _timeStr,
                        style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                      ),
                      if (_speed.isNotEmpty)
                        Text(
                          _speed,
                          style: const TextStyle(fontSize: 12, color: AppColors.brandRedLight),
                        ),
                      Text(
                        _eta,
                        style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),

            // Action Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TvFocusable(
                  borderRadius: BorderRadius.circular(8),
                  onPressed: () => Navigator.of(context).pop(),
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                      side: const BorderSide(color: AppColors.borderMedium),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                    child: const Text('Wait in Background'),
                  ),
                ),
                const SizedBox(width: 12),

                TvFocusable(
                  borderRadius: BorderRadius.circular(8),
                  autofocus: isTv && _isReady,
                  onPressed: _isReady
                      ? () {
                          Navigator.of(context).pop();
                          widget.onPlayReady();
                        }
                      : null,
                  child: ElevatedButton(
                    key: const ValueKey('transcode_gate_play_btn'),
                    onPressed: _isReady
                        ? () {
                            Navigator.of(context).pop();
                            widget.onPlayReady();
                          }
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isReady ? AppColors.brandRed : Colors.white12,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.white10,
                      disabledForegroundColor: Colors.white38,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    ),
                    child: Text(_isReady ? '▶ Play Now' : 'Waiting for 100%...'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
