import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/player_controller_interface.dart';
import '../../domain/tv_player_focus.dart';

/// Centralized keyboard, desktop shortcut, and 10-foot TV remote key event dispatcher.
class PlayerKeyDispatcher {
  static bool handleKeyEvent({
    required KeyEvent event,
    required BuildContext context,
    required bool isTv,
    required bool controlsVisible,
    required bool isFullscreen,
    required PlayerPlaybackState state,
    required double volume,
    required TvPlayerFocusZone tvFocusZone,
    required int tvFocusedControlIndex,
    required int tvControlCount,
    required VoidCallback onTogglePlayPause,
    required void Function(int seconds) onSeekRelative,
    required VoidCallback onUserInteraction,
    required void Function(TvPlayerFocusZone zone) onSetTvFocusZone,
    required void Function(int index) onSetTvFocusedControlIndex,
    required void Function(int index) onTriggerTvControlAction,
    required VoidCallback onOpenSubtitleTrackSheet,
    required VoidCallback onOpenAudioTrackSheet,
    required VoidCallback onToggleMute,
    required VoidCallback onRestart,
    required void Function({required bool forceExit}) onHandleBack,
    required VoidCallback onHideControls,
    required void Function(double volume) onVolumeChanged,
    required void Function(String message, {IconData? icon}) onShowHudToast,
    required VoidCallback onToggleFullscreen,
  }) {
    if (event is! KeyDownEvent) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;

    final key = event.logicalKey;

    // 1. Media keys (Universal across TV remote, media keys & keyboard)
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      onTogglePlayPause();
      return true;
    } else if (key == LogicalKeyboardKey.mediaPlay) {
      if (state != PlayerPlaybackState.playing) {
        onTogglePlayPause();
      }
      return true;
    } else if (key == LogicalKeyboardKey.mediaPause) {
      if (state == PlayerPlaybackState.playing) {
        onTogglePlayPause();
      }
      return true;
    } else if (key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      onSeekRelative(-15);
      return true;
    } else if (key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      onSeekRelative(15);
      return true;
    }

    if (isTv) {
      // -------------------------------------------------------------
      // 10-FOOT TV D-PAD NAVIGATION MODEL
      // Dedicated volume buttons on remote manage TV audio volume.
      // D-pad Up/Down navigates between Timeline (Zone 1) & Controls (Zone 2).
      // -------------------------------------------------------------

      // If controls are hidden: any D-pad input reveals controls
      if (!controlsVisible) {
        if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyJ) {
          onUserInteraction();
          onSeekRelative(-10);
          onSetTvFocusZone(TvPlayerFocusZone.timeline);
          return true;
        } else if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyL) {
          onUserInteraction();
          onSeekRelative(10);
          onSetTvFocusZone(TvPlayerFocusZone.timeline);
          return true;
        } else if (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.space ||
            key == LogicalKeyboardKey.keyK) {
          onUserInteraction();
          onSetTvFocusZone(TvPlayerFocusZone.controls);
          onSetTvFocusedControlIndex(1); // Default to Play/Pause
          return true;
        } else if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
          onUserInteraction();
          onSetTvFocusZone(TvPlayerFocusZone.timeline);
          return true;
        } else if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
          onUserInteraction();
          onSetTvFocusZone(TvPlayerFocusZone.timeline);
          return true;
        }
        return false;
      }

      // Controls ARE currently visible:
      onUserInteraction(); // Resets auto-hide timer

      // D-Pad UP: Move from controls into timeline
      if (key == LogicalKeyboardKey.arrowUp) {
        if (tvFocusZone == TvPlayerFocusZone.controls) {
          onSetTvFocusZone(TvPlayerFocusZone.timeline);
          return true;
        }
        return true;
      }

      // D-Pad DOWN: Move from timeline into controls
      if (key == LogicalKeyboardKey.arrowDown) {
        if (tvFocusZone == TvPlayerFocusZone.timeline) {
          onSetTvFocusZone(TvPlayerFocusZone.controls);
          return true;
        }
        return true;
      }

      // D-Pad LEFT
      if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyJ) {
        if (tvFocusZone == TvPlayerFocusZone.timeline) {
          onSeekRelative(-10);
          return true;
        } else {
          if (tvFocusedControlIndex > 0) {
            onSetTvFocusedControlIndex(tvFocusedControlIndex - 1);
          }
          return true;
        }
      }

      // D-Pad RIGHT
      if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyL) {
        if (tvFocusZone == TvPlayerFocusZone.timeline) {
          onSeekRelative(10);
          return true;
        } else {
          if (tvFocusedControlIndex < tvControlCount - 1) {
            onSetTvFocusedControlIndex(tvFocusedControlIndex + 1);
          }
          return true;
        }
      }

      // CENTER / SELECT / ENTER / SPACE
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.keyK) {
        if (tvFocusZone == TvPlayerFocusZone.timeline) {
          onTogglePlayPause();
          return true;
        } else {
          onTriggerTvControlAction(tvFocusedControlIndex);
          return true;
        }
      }

      // Remote shortcut keys
      if (key == LogicalKeyboardKey.contextMenu ||
          key == LogicalKeyboardKey.info ||
          key == LogicalKeyboardKey.keyC) {
        onOpenSubtitleTrackSheet();
        return true;
      }
      if (key == LogicalKeyboardKey.keyA) {
        onOpenAudioTrackSheet();
        return true;
      }
      if (key == LogicalKeyboardKey.keyM) {
        onToggleMute();
        return true;
      }
      if (key == LogicalKeyboardKey.home || key == LogicalKeyboardKey.digit0) {
        onRestart();
        return true;
      }

      // BACK KEY on TV (Controls are visible: perform normal player exit)
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
        onHandleBack(forceExit: false);
        return true;
      }

      return false;
    }

    // -------------------------------------------------------------
    // NON-TV (MOBILE / TABLET / DESKTOP) INTERACTION MODEL
    // -------------------------------------------------------------
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
      onTogglePlayPause();
      return true;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (!controlsVisible) {
        onUserInteraction();
      } else {
        onTogglePlayPause();
      }
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyJ) {
      onSeekRelative(-10);
      return true;
    } else if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyL) {
      onSeekRelative(10);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (!controlsVisible) {
        onUserInteraction();
      } else {
        final next = (volume + 5.0).clamp(0.0, 100.0);
        onVolumeChanged(next);
        onShowHudToast('${next.round()}% Volume', icon: Icons.volume_up_rounded);
      }
      return true;
    } else if (key == LogicalKeyboardKey.arrowDown) {
      if (!controlsVisible) {
        onUserInteraction();
      } else {
        final next = (volume - 5.0).clamp(0.0, 100.0);
        onVolumeChanged(next);
        onShowHudToast('${next.round()}% Volume', icon: Icons.volume_down_rounded);
      }
      return true;
    }
    if (key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.info ||
        key == LogicalKeyboardKey.keyC) {
      onOpenSubtitleTrackSheet();
      return true;
    }
    if (key == LogicalKeyboardKey.keyA) {
      onOpenAudioTrackSheet();
      return true;
    }
    if (key == LogicalKeyboardKey.keyM) {
      onToggleMute();
      return true;
    }
    if (key == LogicalKeyboardKey.keyF) {
      onToggleFullscreen();
      return true;
    }
    if (key == LogicalKeyboardKey.home || key == LogicalKeyboardKey.digit0) {
      onRestart();
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (isFullscreen) {
        onToggleFullscreen();
        return true;
      }
    } else if (key == LogicalKeyboardKey.goBack) {
      if (!controlsVisible) {
        onUserInteraction();
        return true;
      }
      if (isFullscreen) {
        onToggleFullscreen();
        return true;
      }
      onHandleBack(forceExit: false);
      return true;
    }

    return false;
  }
}
