import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/storage/device_identity_service.dart';
import '../domain/player_controller_interface.dart';
import '../infrastructure/media_kit_player_adapter.dart';
import 'widgets/player_controls_overlay.dart';
import 'widgets/player_error_card.dart';
import 'widgets/player_loading_indicator.dart';
import 'widgets/player_surface.dart';

/// Production player screen for Phase 3A.
class PlayerScreen extends ConsumerStatefulWidget {
  final String mediaUrl;
  final String title;
  final String? subtitle;
  final Duration? startPosition;
  final String? externalSubtitleUrl;
  final String? deviceId;
  final PlayerControllerInterface? customController;

  const PlayerScreen({
    super.key,
    required this.mediaUrl,
    required this.title,
    this.subtitle,
    this.startPosition,
    this.externalSubtitleUrl,
    this.deviceId,
    this.customController,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late final PlayerControllerInterface _controller;
  late final bool _ownsController;
  VideoController? _videoController;

  final List<StreamSubscription> _subscriptions = [];

  PlayerPlaybackState _state = PlayerPlaybackState.idle;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isBuffering = false;
  double _volume = 100.0;
  double _lastPreMuteVolume = 100.0;
  bool _isFullscreen = false;

  bool _controlsVisible = true;
  Timer? _autoHideTimer;
  String? _errorMessage;

  final FocusNode _keyboardFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();

    if (widget.customController != null) {
      _controller = widget.customController!;
      _ownsController = false;
      if (_controller is MediaKitPlayerAdapter) {
        _videoController = _controller.videoController;
      }
    } else {
      final adapter = MediaKitPlayerAdapter();
      _controller = adapter;
      _videoController = adapter.videoController;
      _ownsController = true;
    }

    _volume = _controller.volume > 0 ? _controller.volume : 100.0;
    _lastPreMuteVolume = _volume;

    _listenToStreams();
    _openMedia();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _keyboardFocusNode.requestFocus();
      }
    });
  }

  void _listenToStreams() {
    _subscriptions.add(_controller.stateStream.listen((s) {
      if (!mounted) return;
      setState(() {
        _state = s;
        if (s == PlayerPlaybackState.error) {
          _errorMessage = 'Failed to load media or decode stream.';
        } else if (s == PlayerPlaybackState.playing) {
          _errorMessage = null;
          _resetAutoHideTimer();
        } else if (s == PlayerPlaybackState.paused) {
          _cancelAutoHideTimer();
          _controlsVisible = true;
        }
      });
    }));

    _subscriptions.add(_controller.positionStream.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
    }));

    _subscriptions.add(_controller.durationStream.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
    }));

    _subscriptions.add(_controller.bufferingStream.listen((b) {
      if (!mounted) return;
      setState(() => _isBuffering = b);
    }));
  }

  Future<void> _openMedia() async {
    setState(() {
      _errorMessage = null;
      _state = PlayerPlaybackState.opening;
    });

    try {
      String deviceId = widget.deviceId ?? 'dev_flutter_client';
      if (widget.deviceId == null) {
        try {
          deviceId = await DeviceIdentityService().getOrCreateDeviceId();
        } catch (_) {}
      }

      await _controller.open(
        widget.mediaUrl,
        headers: {'X-Device-Id': deviceId},
        startPosition: widget.startPosition,
        externalSubtitleUrl: widget.externalSubtitleUrl,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = PlayerPlaybackState.error;
        _errorMessage = e.toString();
      });
    }
  }

  void _onUserInteraction() {
    if (!_keyboardFocusNode.hasFocus) {
      _keyboardFocusNode.requestFocus();
    }
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    if (_state == PlayerPlaybackState.playing) {
      _resetAutoHideTimer();
    }
  }

  void _resetAutoHideTimer() {
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      if (_state == PlayerPlaybackState.playing) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _cancelAutoHideTimer() {
    _autoHideTimer?.cancel();
  }

  void _togglePlayPause() {
    _onUserInteraction();
    if (_state == PlayerPlaybackState.playing) {
      _controller.pause();
    } else {
      _controller.play();
    }
  }

  void _onVolumeChanged(double v) {
    _onUserInteraction();
    setState(() {
      _volume = v;
      if (v > 0) _lastPreMuteVolume = v;
    });
    _controller.setVolume(v);
  }

  void _toggleMute() {
    _onUserInteraction();
    if (_volume > 0) {
      _lastPreMuteVolume = _volume;
      _onVolumeChanged(0.0);
    } else {
      _onVolumeChanged(_lastPreMuteVolume > 0 ? _lastPreMuteVolume : 80.0);
    }
  }

  Future<void> _toggleFullscreen() async {
    _onUserInteraction();
    final target = !_isFullscreen;
    setState(() => _isFullscreen = target);
    try {
      if (target) {
        await defaultEnterNativeFullscreen();
      } else {
        await defaultExitNativeFullscreen();
      }
    } catch (e) {
      debugPrint('[PlayerScreen] Fullscreen error: $e');
    }
  }

  void _onBack() {
    if (_isFullscreen) {
      _toggleFullscreen();
    }
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
      _togglePlayPause();
    } else if (key == LogicalKeyboardKey.keyM) {
      _toggleMute();
    } else if (key == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
    } else if (key == LogicalKeyboardKey.escape) {
      if (_isFullscreen) {
        _toggleFullscreen();
      }
    }
  }

  @override
  void dispose() {
    if (_isFullscreen) {
      defaultExitNativeFullscreen();
    }
    _autoHideTimer?.cancel();
    _keyboardFocusNode.dispose();
    for (final s in _subscriptions) {
      s.cancel();
    }
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isOpening = _state == PlayerPlaybackState.opening ||
        (_state == PlayerPlaybackState.idle && _errorMessage == null);
    final hasError = _state == PlayerPlaybackState.error || _errorMessage != null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _keyboardFocusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          _handleKeyEvent(event);
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          onHover: (_) => _onUserInteraction(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onUserInteraction,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. Isolated video surface
                if (_videoController != null)
                  PlayerSurface(controller: _videoController!)
                else
                  Container(color: Colors.black),

                // 2. Loading indicator
                if (isOpening || _isBuffering)
                  PlayerLoadingIndicator(
                    title: isOpening ? 'Loading Media' : 'Buffering Stream',
                    message: isOpening
                        ? 'Initializing player & stream...'
                        : 'Filling playback buffer...',
                  ),

                // 3. Error display
                if (hasError)
                  PlayerErrorCard(
                    errorMessage: _errorMessage ?? 'Unknown error occurred.',
                    onRetry: _openMedia,
                    onBack: _onBack,
                  ),

                // 4. Controls Overlay
                if (!hasError)
                  PlayerControlsOverlay(
                    title: widget.title,
                    subtitle: widget.subtitle,
                    isVisible: _controlsVisible,
                    isPlaying: _state == PlayerPlaybackState.playing,
                    isBuffering: _isBuffering,
                    position: _position,
                    duration: _duration,
                    volume: _volume,
                    isFullscreen: _isFullscreen,
                    onTogglePlay: _togglePlayPause,
                    onVolumeChanged: _onVolumeChanged,
                    onToggleMute: _toggleMute,
                    onToggleFullscreen: _toggleFullscreen,
                    onBack: _onBack,
                    onUserInteraction: _onUserInteraction,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
