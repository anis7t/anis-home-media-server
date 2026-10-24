import 'dart:async';
import 'package:flutter/material.dart';

/// Wraps the player surface to detect double-tap seeking gestures:
/// - Left 40%: Rewind 10 seconds with animated ripple feedback
/// - Right 40%: Fast-forward 10 seconds with animated ripple feedback
/// - Center 20%: Ignored for seeking; passes single-tap to toggle controls
///
/// Optionally also reports vertical drags: the left half of the surface and
/// the right half are told apart so the caller can drive brightness and
/// volume. A drag never satisfies the tap or double-tap recognizers, so the
/// gestures cannot shadow each other.
class DoubleTapSeekDetector extends StatefulWidget {
  final Widget child;
  final VoidCallback onDoubleTapRewind;
  final VoidCallback onDoubleTapForward;
  final VoidCallback? onDoubleTapCenter;
  final VoidCallback? onTap;
  final bool enabled;

  /// Drag distance as a fraction of the surface height (positive = swipe up),
  /// plus whether the gesture began on the left half. Null disables the
  /// gesture (no drag recognizers are installed).
  final void Function(double fraction, bool fromLeftHalf)? onVerticalDragDelta;
  final void Function(bool fromLeftHalf)? onVerticalDragBegin;
  final VoidCallback? onVerticalDragEnd;

  const DoubleTapSeekDetector({
    super.key,
    required this.child,
    required this.onDoubleTapRewind,
    required this.onDoubleTapForward,
    this.onDoubleTapCenter,
    this.onTap,
    this.enabled = true,
    this.onVerticalDragDelta,
    this.onVerticalDragBegin,
    this.onVerticalDragEnd,
  });

  @override
  State<DoubleTapSeekDetector> createState() => _DoubleTapSeekDetectorState();
}

class _DoubleTapSeekDetectorState extends State<DoubleTapSeekDetector>
    with TickerProviderStateMixin {
  bool _showLeftRipple = false;
  bool _showRightRipple = false;
  int _accumulatedRewind = 0;
  int _accumulatedForward = 0;

  Timer? _leftTimer;
  Timer? _rightTimer;

  bool _dragging = false;
  /// Y where the drag began, in surface coordinates. The fraction reported to
  /// callers is measured from here, so it is the whole drag distance rather than
  /// one frame of it (and it includes the touch-slop distance).
  double _dragStartY = 0;
  bool _dragFromLeft = true;

  void _onDragStart(DragStartDetails details, double width) {
    _dragStartY = details.localPosition.dy;
    if (!widget.enabled || widget.onVerticalDragDelta == null) return;
    _dragging = true;
    _dragFromLeft = width <= 0 || details.localPosition.dx < width / 2;
    widget.onVerticalDragBegin?.call(_dragFromLeft);
  }

  void _onDragUpdate(DragUpdateDetails details, double height) {
    if (!widget.enabled || !_dragging || height <= 0) return;
    // Up is positive: a full-height swipe covers the whole 0-100 range.
    final fraction = (_dragStartY - details.localPosition.dy) / height;
    widget.onVerticalDragDelta?.call(fraction, _dragFromLeft);
  }

  void _onDragEnd() {
    if (!_dragging) return;
    _dragging = false;
    widget.onVerticalDragEnd?.call();
  }

  void _triggerRewind() {
    if (!widget.enabled) return;
    widget.onDoubleTapRewind();

    setState(() {
      _showLeftRipple = true;
      _accumulatedRewind += 10;
    });

    _leftTimer?.cancel();
    _leftTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) {
        setState(() {
          _showLeftRipple = false;
          _accumulatedRewind = 0;
        });
      }
    });
  }

  void _triggerForward() {
    if (!widget.enabled) return;
    widget.onDoubleTapForward();

    setState(() {
      _showRightRipple = true;
      _accumulatedForward += 10;
    });

    _rightTimer?.cancel();
    _rightTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) {
        setState(() {
          _showRightRipple = false;
          _accumulatedForward = 0;
        });
      }
    });
  }

  @override
  void dispose() {
    _leftTimer?.cancel();
    _rightTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;

        return Stack(
          fit: StackFit.expand,
          children: [
            // Underlying content with double-tap & single-tap detector
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              onVerticalDragStart: widget.onVerticalDragDelta == null
                  ? null
                  : (d) => _onDragStart(d, totalWidth),
              onVerticalDragUpdate: widget.onVerticalDragDelta == null
                  ? null
                  : (d) => _onDragUpdate(d, constraints.maxHeight),
              onVerticalDragEnd: widget.onVerticalDragDelta == null
                  ? null
                  : (_) => _onDragEnd(),
              onVerticalDragCancel:
                  widget.onVerticalDragDelta == null ? null : _onDragEnd,
              onDoubleTapDown: (details) {
                if (totalWidth <= 0) return;
                final xRatio = details.localPosition.dx / totalWidth;
                if (xRatio < 0.4) {
                  _triggerRewind();
                } else if (xRatio > 0.6) {
                  _triggerForward();
                } else {
                  if (widget.onDoubleTapCenter != null) {
                    widget.onDoubleTapCenter!();
                  } else {
                    widget.onTap?.call();
                  }
                }
              },
              onDoubleTap: () {},
              child: widget.child,
            ),

            // Left Ripple Overlay (Rewind)
            if (_showLeftRipple)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: totalWidth * 0.45,
                child: IgnorePointer(
                  child: _buildRippleIndicator(
                    isLeft: true,
                    seconds: _accumulatedRewind,
                  ),
                ),
              ),

            // Right Ripple Overlay (Fast-Forward)
            if (_showRightRipple)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: totalWidth * 0.45,
                child: IgnorePointer(
                  child: _buildRippleIndicator(
                    isLeft: false,
                    seconds: _accumulatedForward,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildRippleIndicator({required bool isLeft, required int seconds}) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: isLeft ? Alignment.centerLeft : Alignment.centerRight,
          end: isLeft ? Alignment.centerRight : Alignment.centerLeft,
          colors: [
            Colors.white.withValues(alpha: 0.18),
            Colors.white.withValues(alpha: 0.08),
            Colors.transparent,
          ],
        ),
        borderRadius: BorderRadius.horizontal(
          right: isLeft ? const Radius.elliptical(120, 200) : Radius.zero,
          left: !isLeft ? const Radius.elliptical(120, 200) : Radius.zero,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isLeft ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
                color: Colors.white,
                size: 32.0,
              ),
            ),
            const SizedBox(height: 8.0),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 4.0),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12.0),
              ),
              child: Text(
                '$seconds seconds',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13.0,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
