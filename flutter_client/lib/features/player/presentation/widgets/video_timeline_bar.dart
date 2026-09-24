import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../domain/seek_preview_controller.dart';

/// Interactive video timeline scrubber with touch drag, mouse hover,
/// frame preview thumbnails, and 48dp minimum touch target bounding box.
class VideoTimelineBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<bool>? onScrubbingChanged;
  final SeekPreviewController? seekPreviewController;
  final Map<String, dynamic>? previewMeta;
  final SeekPreviewState? previewStateOverride;

  const VideoTimelineBar({
    super.key,
    required this.position,
    required this.duration,
    this.buffered = Duration.zero,
    required this.onSeek,
    this.onScrubbingChanged,
    this.seekPreviewController,
    this.previewMeta,
    this.previewStateOverride,
  });

  @override
  State<VideoTimelineBar> createState() => _VideoTimelineBarState();
}

class _VideoTimelineBarState extends State<VideoTimelineBar> {
  bool _isDragging = false;
  bool _isHovering = false;
  double _dragFraction = 0.0;
  double _hoverFraction = 0.0;

  int? _computeFrameIndex(Duration target) {
    if (widget.previewMeta == null) return null;
    final interval = (widget.previewMeta!['interval'] as num?)?.toDouble() ?? 0.0;
    final count = (widget.previewMeta!['count'] as num?)?.toInt() ?? 0;
    if (interval <= 0 || count <= 0) return null;

    final targetSeconds = target.inMilliseconds / 1000.0;
    return (targetSeconds / interval).floor().clamp(0, count - 1);
  }

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

  void _onDragDown(DragDownDetails details, double trackWidth) {
    if (trackWidth <= 0 || widget.duration.inMilliseconds <= 0) return;
    _isDragging = true;
    widget.onScrubbingChanged?.call(true);
    _updateDrag(details.localPosition.dx, trackWidth);
  }

  void _onDragStart(DragStartDetails details, double trackWidth) {
    if (trackWidth <= 0 || widget.duration.inMilliseconds <= 0) return;
    _isDragging = true;
    widget.onScrubbingChanged?.call(true);
    _updateDrag(details.localPosition.dx, trackWidth);
  }

  void _updateDrag(double dx, double trackWidth) {
    if (trackWidth <= 0 || widget.duration.inMilliseconds <= 0) return;
    final fraction = (dx / trackWidth).clamp(0.0, 1.0);
    final targetMs = (fraction * widget.duration.inMilliseconds).round();
    final targetDuration = Duration(milliseconds: targetMs);

    setState(() {
      _dragFraction = fraction;
    });

    final frameIndex = _computeFrameIndex(targetDuration);
    if (frameIndex != null) {
      widget.seekPreviewController?.requestFrame(frameIndex);
    }
  }

  void _onDragEnd(DragEndDetails details, double trackWidth) {
    if (!_isDragging) return;
    _isDragging = false;
    final targetMs = (_dragFraction * widget.duration.inMilliseconds).round();
    final targetDuration = Duration(milliseconds: targetMs);

    widget.onSeek(targetDuration);
    widget.onScrubbingChanged?.call(false);
    widget.seekPreviewController?.cancelPending();
    setState(() {});
  }

  void _onDragCancel() {
    if (!_isDragging) return;
    _isDragging = false;
    widget.onScrubbingChanged?.call(false);
    widget.seekPreviewController?.cancelPending();
    setState(() {});
  }

  void _onHover(PointerHoverEvent event, double trackWidth) {
    if (_isDragging || trackWidth <= 0 || widget.duration.inMilliseconds <= 0) return;
    final dx = event.localPosition.dx;
    final fraction = (dx / trackWidth).clamp(0.0, 1.0);
    final targetMs = (fraction * widget.duration.inMilliseconds).round();
    final targetDuration = Duration(milliseconds: targetMs);

    setState(() {
      _isHovering = true;
      _hoverFraction = fraction;
    });

    final frameIndex = _computeFrameIndex(targetDuration);
    if (frameIndex != null) {
      widget.seekPreviewController?.requestFrame(frameIndex);
    }
  }

  void _onHoverExit() {
    if (!_isHovering) return;
    setState(() {
      _isHovering = false;
    });
  }

  void _onTapDown(TapDownDetails details, double trackWidth) {
    if (trackWidth <= 0 || widget.duration.inMilliseconds <= 0) return;
    final fraction = (details.localPosition.dx / trackWidth).clamp(0.0, 1.0);
    final targetMs = (fraction * widget.duration.inMilliseconds).round();
    final targetDuration = Duration(milliseconds: targetMs);
    widget.onSeek(targetDuration);
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = widget.duration.inMilliseconds;
    final playedMs = widget.position.inMilliseconds;
    final bufferedMs = widget.buffered.inMilliseconds;

    final playedFraction = totalMs > 0 ? (playedMs / totalMs).clamp(0.0, 1.0) : 0.0;
    final bufferedFraction = totalMs > 0 ? (bufferedMs / totalMs).clamp(0.0, 1.0) : 0.0;

    final isActive = _isDragging || _isHovering;
    final currentFraction = _isDragging ? _dragFraction : playedFraction;

    return LayoutBuilder(
      builder: (context, constraints) {
        final trackWidth = constraints.maxWidth;
        final previewFraction = _isDragging
            ? _dragFraction
            : (_isHovering ? _hoverFraction : playedFraction);
        final previewDuration = Duration(
          milliseconds: (previewFraction * totalMs).round(),
        );

        final previewState = widget.previewStateOverride ?? widget.seekPreviewController?.state;
        final hasMetadata = widget.previewMeta != null &&
            (widget.previewMeta!['count'] as num? ?? 0) > 0;
        final displayedImageUrl = previewState?.displayedImageUrl;

        final showPreview = isActive && totalMs > 0;
        final showImage = hasMetadata && (displayedImageUrl != null || (previewState?.isPendingDebounce ?? false));

        final cardWidth = showImage ? 160.0 : 76.0;
        final targetX = previewFraction * trackWidth;
        final clampedCardLeft = (targetX - (cardWidth / 2)).clamp(
          4.0,
          (trackWidth - cardWidth - 4.0).clamp(4.0, double.infinity),
        );

        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            // 1. Floating Seek Preview Card
            if (showPreview)
              Positioned(
                bottom: 46.0,
                left: clampedCardLeft,
                child: _buildPreviewCard(
                  duration: previewDuration,
                  imageUrl: displayedImageUrl,
                  isPending: previewState?.isPendingDebounce ?? false,
                  showImage: showImage,
                  width: cardWidth,
                ),
              ),

            // 2. Interactive Timeline Bar (minimum 48dp touch hit target)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              onHover: (e) => _onHover(e, trackWidth),
              onExit: (_) => _onHoverExit(),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => _onTapDown(d, trackWidth),
                onHorizontalDragDown: (d) => _onDragDown(d, trackWidth),
                onHorizontalDragStart: (d) => _onDragStart(d, trackWidth),
                onHorizontalDragUpdate: (d) => _updateDrag(d.localPosition.dx, trackWidth),
                onHorizontalDragEnd: (d) => _onDragEnd(d, trackWidth),
                onHorizontalDragCancel: _onDragCancel,
                child: Container(
                  height: 48.0, // Android minimum touch target
                  alignment: Alignment.center,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    clipBehavior: Clip.none,
                    children: [
                      // Background Track
                      Container(
                        height: isActive ? 6.0 : 4.0,
                        width: trackWidth,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(3.0),
                        ),
                      ),

                      // Buffered Track
                      if (bufferedFraction > 0.0)
                        Container(
                          height: isActive ? 6.0 : 4.0,
                          width: trackWidth * bufferedFraction,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.38),
                            borderRadius: BorderRadius.circular(3.0),
                          ),
                        ),

                      // Played Track
                      Container(
                        height: isActive ? 6.0 : 4.0,
                        width: trackWidth * currentFraction,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF334B), // Brand red
                          borderRadius: BorderRadius.circular(3.0),
                        ),
                      ),

                      // Scrubber Thumb
                      Positioned(
                        left: (trackWidth * currentFraction) - (isActive ? 9.0 : 7.0),
                        child: Container(
                          width: isActive ? 18.0 : 14.0,
                          height: isActive ? 18.0 : 14.0,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: const Color(0xFFFF334B),
                              width: isActive ? 3.0 : 2.0,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.6),
                                blurRadius: 4.0,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPreviewCard({
    required Duration duration,
    required String? imageUrl,
    required bool isPending,
    required bool showImage,
    required double width,
  }) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: const Color(0xF010141E),
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.18),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.65),
            blurRadius: 14.0,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Thumbnail Image (if metadata available)
            if (showImage)
              SizedBox(
                height: 90.0,
                width: width,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: const Color(0xFF0A0D14)),
                    if (imageUrl != null)
                      Image.network(
                        imageUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return const Center(
                            child: Icon(
                              Icons.broken_image_rounded,
                              color: Colors.white38,
                              size: 28,
                            ),
                          );
                        },
                      ),
                    if (isPending)
                      Container(
                        color: Colors.black38,
                        child: const Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.0,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Color(0xFFFF334B),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

            // Timestamp pill
            Container(
              padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
              color: Colors.black.withValues(alpha: 0.5),
              alignment: Alignment.center,
              child: Text(
                _formatDuration(duration),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.0,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
