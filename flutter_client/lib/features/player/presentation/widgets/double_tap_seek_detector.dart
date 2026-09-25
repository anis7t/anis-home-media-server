import 'dart:async';
import 'package:flutter/material.dart';

/// Wraps the player surface to detect double-tap seeking gestures:
/// - Left 40%: Rewind 10 seconds with animated ripple feedback
/// - Right 40%: Fast-forward 10 seconds with animated ripple feedback
/// - Center 20%: Ignored for seeking; passes single-tap to toggle controls
class DoubleTapSeekDetector extends StatefulWidget {
  final Widget child;
  final VoidCallback onDoubleTapRewind;
  final VoidCallback onDoubleTapForward;
  final VoidCallback? onDoubleTapCenter;
  final VoidCallback? onTap;
  final bool enabled;

  const DoubleTapSeekDetector({
    super.key,
    required this.child,
    required this.onDoubleTapRewind,
    required this.onDoubleTapForward,
    this.onDoubleTapCenter,
    this.onTap,
    this.enabled = true,
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
