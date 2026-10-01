import 'package:flutter/material.dart';

/// Represents the mutually exclusive visual state of the player's central overlay.
enum PlaybackOverlayType {
  none,
  opening,
  buffering,
  seeking,
  toast,
}

/// Immutable status value describing the active central playback overlay.
class PlaybackOverlayStatus {
  final PlaybackOverlayType type;
  final String? message;
  final String? subMessage;
  final IconData? icon;

  const PlaybackOverlayStatus({
    required this.type,
    this.message,
    this.subMessage,
    this.icon,
  });

  static const PlaybackOverlayStatus none = PlaybackOverlayStatus(
    type: PlaybackOverlayType.none,
  );

  bool get isNone => type == PlaybackOverlayType.none;
  bool get isOpening => type == PlaybackOverlayType.opening;
  bool get isBuffering => type == PlaybackOverlayType.buffering;
  bool get isSeeking => type == PlaybackOverlayType.seeking;
  bool get isToast => type == PlaybackOverlayType.toast;
  bool get isVisible => type != PlaybackOverlayType.none;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackOverlayStatus &&
          runtimeType == other.runtimeType &&
          type == other.type &&
          message == other.message &&
          subMessage == other.subMessage &&
          icon == other.icon;

  @override
  int get hashCode => Object.hash(type, message, subMessage, icon);

  @override
  String toString() =>
      'PlaybackOverlayStatus(type: $type, message: $message, icon: $icon)';
}
