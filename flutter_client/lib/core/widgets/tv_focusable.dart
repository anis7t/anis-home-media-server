import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_colors.dart';

/// Reusable focusable container for 10-foot TV (Fire TV & Android TV) interfaces.
///
/// Provides prominent, room-visible focus indicators including:
/// - 2.5px brand red border with smooth animation
/// - Ambient red glow shadow
/// - Subtle 1.04x scale transform
/// - Elevated obsidian surface shift
/// - Automatic [Scrollable.ensureVisible] on focus gain
/// - D-pad Select / Enter key invocation
class TvFocusable extends StatefulWidget {
  final Widget? child;
  final Widget Function(BuildContext context, bool isFocused, Widget? child)? builder;
  final FocusNode? focusNode;
  final bool autofocus;
  final VoidCallback? onPressed;
  final ValueChanged<bool>? onFocusChange;
  final BorderRadius? borderRadius;
  final bool autoScroll;
  final double? autoScrollAlignment;
  final bool scaleOnFocus;
  final bool glowOnFocus;
  final double borderWidth;
  final Color? normalBorderColor;
  final Color? focusedBorderColor;
  final Color? normalBackgroundColor;
  final Color? focusedBackgroundColor;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final KeyEventResult Function(FocusNode node, KeyEvent event)? onKeyEvent;

  const TvFocusable({
    super.key,
    this.child,
    this.builder,
    this.focusNode,
    this.autofocus = false,
    this.onPressed,
    this.onFocusChange,
    this.borderRadius,
    this.autoScroll = true,
    this.autoScrollAlignment,
    this.scaleOnFocus = true,
    this.glowOnFocus = true,
    this.borderWidth = 2.5,
    this.normalBorderColor,
    this.focusedBorderColor,
    this.normalBackgroundColor,
    this.focusedBackgroundColor,
    this.padding,
    this.margin,
    this.onKeyEvent,
  }) : assert(child != null || builder != null, 'Either child or builder must be provided.');

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  late FocusNode _focusNode;
  bool _ownsFocusNode = false;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode != null) {
      _focusNode = widget.focusNode!;
    } else {
      _focusNode = FocusNode();
      _ownsFocusNode = true;
    }
  }

  @override
  void didUpdateWidget(TvFocusable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      if (_ownsFocusNode) {
        _focusNode.dispose();
      }
      if (widget.focusNode != null) {
        _focusNode = widget.focusNode!;
        _ownsFocusNode = false;
      } else {
        _focusNode = FocusNode();
        _ownsFocusNode = true;
      }
    }
  }

  @override
  void dispose() {
    if (_ownsFocusNode) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _handleFocusChange(bool hasFocus) {
    if (_isFocused != hasFocus) {
      setState(() {
        _isFocused = hasFocus;
      });
      widget.onFocusChange?.call(hasFocus);

      if (hasFocus && widget.autoScroll && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            if (widget.autoScrollAlignment != null) {
              Scrollable.ensureVisible(
                context,
                alignment: widget.autoScrollAlignment!,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
              );
            } else {
              Scrollable.ensureVisible(
                context,
                alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
              );
            }
          }
        });
      }
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (widget.onKeyEvent != null) {
      final customResult = widget.onKeyEvent!(node, event);
      if (customResult != KeyEventResult.ignored) {
        return customResult;
      }
    }

    if (event is KeyDownEvent) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.gameButtonA) {
        if (widget.onPressed != null) {
          widget.onPressed!();
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final effectiveRadius = widget.borderRadius ?? BorderRadius.circular(12);
    final isFocused = _isFocused;

    Widget content;
    if (widget.builder != null) {
      content = widget.builder!(context, isFocused, widget.child);
    } else {
      content = AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        padding: widget.padding,
        decoration: BoxDecoration(
          color: isFocused
              ? (widget.focusedBackgroundColor ??
                  AppColors.brandRed.withValues(alpha: 0.16))
              : (widget.normalBackgroundColor ?? Colors.transparent),
          borderRadius: effectiveRadius,
          border: Border.all(
            color: isFocused
                ? (widget.focusedBorderColor ?? AppColors.brandRed)
                : (widget.normalBorderColor ?? Colors.transparent),
            width: isFocused ? widget.borderWidth : 1.0,
          ),
          boxShadow: isFocused && widget.glowOnFocus
              ? [
                  BoxShadow(
                    color: AppColors.brandRedGlow.withValues(alpha: 0.65),
                    blurRadius: 18,
                    spreadRadius: 2,
                  ),
                ]
              : null,
        ),
        child: widget.child,
      );
    }

    if (widget.scaleOnFocus) {
      content = AnimatedScale(
        scale: isFocused ? 1.04 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        child: content,
      );
    }

    if (widget.margin != null) {
      content = Padding(padding: widget.margin!, child: content);
    }

    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onFocusChange: _handleFocusChange,
      onKeyEvent: _handleKeyEvent,
      child: GestureDetector(
        onTap: widget.onPressed,
        behavior: HitTestBehavior.opaque,
        child: content,
      ),
    );
  }
}
