import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/storage/device_identity_service.dart';
import '../../connection/controllers/connection_controller.dart';
import '../domain/player_controller_interface.dart';
import '../domain/seek_preview_controller.dart';
import '../infrastructure/media_kit_player_adapter.dart';
import 'widgets/double_tap_seek_detector.dart';
import 'widgets/playback_speed_sheet.dart';
import 'widgets/player_controls_overlay.dart';
import 'widgets/player_error_card.dart';
import 'widgets/player_loading_indicator.dart';
import 'widgets/player_surface.dart';
import 'widgets/track_selector_sheet.dart';

/// Production player screen for Phase 3.
///
/// Features video rendering, responsive Android/touch controls, seek-bar timeline
/// with debounced seek-preview thumbnails, double-tap ±10s seeking, playback speed selection,
/// audio and subtitle stream selectors, Android system back handling, and fullscreen.
class PlayerScreen extends ConsumerStatefulWidget {
  final String mediaUrl;
  final String title;
  final String? subtitle;
  final Duration? startPosition;
  final String? externalSubtitleUrl;
  final String? deviceId;
  final String? mediaFilename;
  final PlayerControllerInterface? customController;
  final Dio? customDio;

  const PlayerScreen({
    super.key,
    required this.mediaUrl,
    required this.title,
    this.subtitle,
    this.startPosition,
    this.externalSubtitleUrl,
    this.deviceId,
    this.mediaFilename,
    this.customController,
    this.customDio,
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
  double _rate = 1.0;

  // Track state
  PlayerTrackInfo _trackInfo = const PlayerTrackInfo();
  List<PlayerSubtitleTrack> _sidecarSubtitles = [];

  // In-player HUD toast feedback
  String? _hudMessage;
  IconData? _hudIcon;
  bool _isHudVisible = false;
  Timer? _hudTimer;

  bool _controlsVisible = true;
  Timer? _autoHideTimer;
  String? _errorMessage;

  // Seek preview & scrubbing state
  late final SeekPreviewController _seekPreviewController;
  PreviewUrlResolver? _previewUrlResolver;
  Map<String, dynamic>? _previewMeta;
  CancelToken? _previewCancelToken;
  CancelToken? _subtitlesCancelToken;
  bool _isScrubbing = false;

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
    _rate = _controller.rate > 0 ? _controller.rate : 1.0;
    _trackInfo = _controller.trackInfo;

    // Initialize canonical SeekPreviewController
    _seekPreviewController = SeekPreviewController(
      debounceDuration: const Duration(milliseconds: 80),
      urlResolver: (int frameIndex, int sequenceId) async {
        if (_previewUrlResolver != null) {
          return await _previewUrlResolver!(frameIndex, sequenceId);
        }
        return '';
      },
      onStateChanged: (state) {
        if (mounted) setState(() {});
      },
    );

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
          if (!_isScrubbing) {
            _resetAutoHideTimer();
          }
        } else if (s == PlayerPlaybackState.paused) {
          _cancelAutoHideTimer();
          _controlsVisible = true;
        }
      });
    }));

    _subscriptions.add(_controller.positionStream.listen((p) {
      if (!mounted) return;
      // Do not snap back during user scrubbing gestures
      if (!_isScrubbing) {
        setState(() => _position = p);
      }
    }));

    _subscriptions.add(_controller.durationStream.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
    }));

    _subscriptions.add(_controller.bufferingStream.listen((b) {
      if (!mounted) return;
      setState(() => _isBuffering = b);
    }));

    _subscriptions.add(_controller.tracksStream.listen((t) {
      if (!mounted) return;
      setState(() => _trackInfo = t);
    }));
  }

  String? _resolveFilename() {
    if (widget.mediaFilename != null && widget.mediaFilename!.isNotEmpty) {
      return widget.mediaFilename;
    }
    final uri = Uri.tryParse(widget.mediaUrl);
    if (uri == null) return null;

    final path = uri.path;
    if (path.startsWith('/media/')) {
      return Uri.decodeComponent(path.substring('/media/'.length));
    } else if (path.startsWith('/hls/')) {
      const prefix = '/hls/';
      var rest = path.substring(prefix.length);
      if (rest.endsWith('/playlist.m3u8')) {
        rest = rest.substring(0, rest.length - '/playlist.m3u8'.length);
      }
      return Uri.decodeComponent(rest);
    }
    return null;
  }

  String? _resolveServerOrigin() {
    final uri = Uri.tryParse(widget.mediaUrl);
    if (uri != null && uri.hasScheme && uri.hasAuthority) {
      return uri.origin;
    }
    try {
      final connState = ref.read(connectionControllerProvider);
      final active = connState.serverUrl;
      if (active.isNotEmpty) {
        final activeUri = Uri.tryParse(active);
        if (activeUri != null && activeUri.hasScheme && activeUri.hasAuthority) {
          return activeUri.origin;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _loadPreviewMeta() async {
    setState(() {
      _previewMeta = null;
    });

    if (widget.customController != null && widget.customDio == null) {
      return;
    }

    try {
      final filename = _resolveFilename();
      final serverOrigin = _resolveServerOrigin();
      if (filename == null || serverOrigin == null) {
        return;
      }

      final encoded = Uri.encodeComponent(filename);
      final url = '$serverOrigin/api/seek-preview-meta/$encoded';

      _previewCancelToken?.cancel();
      _previewCancelToken = CancelToken();

      final dio = widget.customDio ?? Dio();
      final res = await dio.get(
        url,
        cancelToken: _previewCancelToken,
        options: Options(
          responseType: ResponseType.json,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      if (!mounted) return;

      if (res.statusCode == 200 && res.data != null) {
        final data = res.data is Map<String, dynamic>
            ? res.data as Map<String, dynamic>
            : (res.data as Map).cast<String, dynamic>();

        setState(() {
          _previewMeta = data;
        });

        _previewUrlResolver = (int frameIndex, int sequenceId) async {
          final thumbStr = frameIndex.toString().padLeft(5, '0');
          return '$serverOrigin/seek-preview/$encoded/thumb_$thumbStr.jpg?req=$sequenceId';
        };
      } else {
        setState(() {
          _previewMeta = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _previewMeta = null;
        });
      }
    }
  }

  Future<void> _fetchSidecarSubtitles() async {
    if (widget.customController != null && widget.customDio == null) {
      return;
    }
    try {
      final filename = _resolveFilename();
      final serverOrigin = _resolveServerOrigin();
      if (filename == null || serverOrigin == null) return;

      final encoded = Uri.encodeComponent(filename);
      final url = '$serverOrigin/api/subtitles/$encoded';

      _subtitlesCancelToken?.cancel();
      _subtitlesCancelToken = CancelToken();

      final dio = widget.customDio ?? Dio();
      final res = await dio.get(
        url,
        cancelToken: _subtitlesCancelToken,
        options: Options(
          responseType: ResponseType.json,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      if (!mounted) return;

      if (res.statusCode == 200 && res.data != null && res.data['tracks'] is List) {
        final rawTracks = res.data['tracks'] as List;
        final sidecars = <PlayerSubtitleTrack>[];
        for (final item in rawTracks) {
          if (item is Map) {
            final src = item['src'] as String? ?? '';
            final label = item['label'] as String? ?? item['name'] as String? ?? 'Subtitle';
            final lang = item['lang'] as String?;
            final isDefault = item['default'] == true;
            final fullUrl = src.startsWith('http') ? src : '$serverOrigin$src';
            sidecars.add(PlayerSubtitleTrack(
              id: fullUrl,
              title: label,
              language: lang,
              isExternal: true,
              isDefault: isDefault,
            ));
          }
        }
        setState(() {
          _sidecarSubtitles = sidecars;
        });
      }
    } catch (_) {
      // Subtitle discovery is non-fatal
    }
  }

  Future<void> _openMedia() async {
    setState(() {
      _errorMessage = null;
      _state = PlayerPlaybackState.opening;
    });

    _loadPreviewMeta();
    _fetchSidecarSubtitles();

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
    if (_state == PlayerPlaybackState.playing && !_isScrubbing) {
      _resetAutoHideTimer();
    }
  }

  void _toggleControlsVisibility() {
    _onUserInteraction();
    setState(() {
      _controlsVisible = !_controlsVisible;
    });
    if (_controlsVisible && _state == PlayerPlaybackState.playing && !_isScrubbing) {
      _resetAutoHideTimer();
    }
  }

  void _resetAutoHideTimer() {
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(const Duration(milliseconds: 2800), () {
      if (!mounted) return;
      if (_state == PlayerPlaybackState.playing && !_isScrubbing) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _cancelAutoHideTimer() {
    _autoHideTimer?.cancel();
  }

  void _showHudToast(String message, {IconData? icon}) {
    _hudTimer?.cancel();
    setState(() {
      _hudMessage = message;
      _hudIcon = icon;
      _isHudVisible = true;
    });
    _hudTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) {
        setState(() => _isHudVisible = false);
      }
    });
  }

  Future<void> _restart() async {
    _onUserInteraction();
    await _controller.seek(Duration.zero);
    _showHudToast('Restarted', icon: Icons.replay_rounded);
  }

  void _openPlaybackSpeedSheet() {
    _onUserInteraction();
    PlaybackSpeedSheet.show(
      context: context,
      currentRate: _rate,
      onRateSelected: (rate) async {
        await _controller.setRate(rate);
        if (mounted) {
          setState(() => _rate = rate);
          final rateStr = rate.toStringAsFixed(rate.truncateToDouble() == rate ? 0 : 2);
          _showHudToast('$rateStr× Speed', icon: Icons.speed_rounded);
        }
      },
    );
  }

  void _openAudioTrackSheet() {
    _onUserInteraction();
    AudioTrackSheet.show(
      context: context,
      tracks: _trackInfo.audioTracks,
      currentTrack: _trackInfo.currentAudioTrack,
      onTrackSelected: (track) async {
        await _controller.setAudioTrack(track);
        if (mounted) {
          final label = track.title.isNotEmpty ? track.title : 'Audio ${track.id}';
          _showHudToast(label, icon: Icons.audiotrack_rounded);
        }
      },
    );
  }

  void _openSubtitleTrackSheet() {
    _onUserInteraction();
    final combined = <PlayerSubtitleTrack>[];
    final seen = <String>{};
    for (final t in _trackInfo.subtitleTracks) {
      if (seen.add(t.id)) combined.add(t);
    }
    for (final s in _sidecarSubtitles) {
      if (seen.add(s.id)) combined.add(s);
    }

    SubtitleTrackSheet.show(
      context: context,
      tracks: combined,
      currentTrack: _trackInfo.currentSubtitleTrack,
      onTrackSelected: (track) async {
        await _controller.setSubtitleTrack(track);
        if (mounted) {
          final label = track.id == 'no' ? 'Subtitles Off' : track.title;
          _showHudToast(label, icon: Icons.subtitles_rounded);
        }
      },
    );
  }

  Future<void> _togglePlayPause() async {
    _onUserInteraction();
    if (_state == PlayerPlaybackState.playing) {
      await _controller.pause();
    } else {
      await _controller.play();
    }
  }

  Future<void> _seekRelative(int seconds) async {
    _onUserInteraction();
    final cur = _position.inSeconds;
    final maxSec = _duration.inSeconds;
    final targetSec = (cur + seconds).clamp(0, maxSec > 0 ? maxSec : 0);
    final target = Duration(seconds: targetSec);
    await _controller.seek(target);
    if (mounted) {
      setState(() => _position = target);
      final sign = seconds >= 0 ? '+$seconds' : '$seconds';
      _showHudToast('$sign sec', icon: seconds >= 0 ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded);
    }
  }

  void _onVolumeChanged(double val) {
    _onUserInteraction();
    setState(() => _volume = val);
    if (val > 0) {
      _lastPreMuteVolume = val;
    }
    _controller.setVolume(val);
  }

  void _toggleMute() {
    _onUserInteraction();
    if (_volume > 0) {
      _lastPreMuteVolume = _volume;
      _onVolumeChanged(0);
      _showHudToast('Muted', icon: Icons.volume_off_rounded);
    } else {
      final restore = _lastPreMuteVolume > 0 ? _lastPreMuteVolume : 100.0;
      _onVolumeChanged(restore);
      _showHudToast('${restore.round()}% Volume', icon: Icons.volume_up_rounded);
    }
  }

  Future<void> _toggleFullscreen() async {
    _onUserInteraction();
    setState(() {
      _isFullscreen = !_isFullscreen;
    });
    if (_isFullscreen) {
      await defaultEnterNativeFullscreen();
    } else {
      await defaultExitNativeFullscreen();
    }
  }

  void _onSeek(Duration target) {
    _onUserInteraction();
    _controller.seek(target);
    setState(() => _position = target);
  }

  void _onScrubbingChanged(bool isScrubbing) {
    setState(() => _isScrubbing = isScrubbing);
    if (isScrubbing) {
      _cancelAutoHideTimer();
      _controlsVisible = true;
    } else {
      if (_state == PlayerPlaybackState.playing) {
        _resetAutoHideTimer();
      }
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
    } else if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyJ) {
      _seekRelative(-10);
    } else if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyL) {
      _seekRelative(10);
    } else if (key == LogicalKeyboardKey.home || key == LogicalKeyboardKey.digit0) {
      _restart();
    } else if (key == LogicalKeyboardKey.keyC) {
      _openSubtitleTrackSheet();
    } else if (key == LogicalKeyboardKey.arrowUp) {
      final next = (_volume + 5.0).clamp(0.0, 100.0);
      _onVolumeChanged(next);
      _showHudToast('${next.round()}% Volume', icon: Icons.volume_up_rounded);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      final next = (_volume - 5.0).clamp(0.0, 100.0);
      _onVolumeChanged(next);
      _showHudToast('${next.round()}% Volume', icon: Icons.volume_down_rounded);
    } else if (key == LogicalKeyboardKey.escape) {
      if (_isFullscreen) {
        _toggleFullscreen();
      }
    }
  }

  Future<void> _handleBack() async {
    _cancelAutoHideTimer();
    _hudTimer?.cancel();
    if (_isFullscreen) {
      await defaultExitNativeFullscreen();
    }
    await _controller.stop();
    if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    if (_isFullscreen) {
      defaultExitNativeFullscreen();
    }
    _autoHideTimer?.cancel();
    _hudTimer?.cancel();
    _previewCancelToken?.cancel();
    _subtitlesCancelToken?.cancel();
    _seekPreviewController.dispose();
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

    final hasSubtitles = _trackInfo.currentSubtitleTrack.id != 'no' &&
        _trackInfo.currentSubtitleTrack.id.isNotEmpty;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _keyboardFocusNode,
          autofocus: true,
          onKeyEvent: (node, event) {
            _handleKeyEvent(event);
            return KeyEventResult.ignored;
          },
          child: MouseRegion(
            onHover: (_) => _onUserInteraction(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. Isolated video surface with DoubleTapSeekDetector
                Positioned.fill(
                  child: DoubleTapSeekDetector(
                    onDoubleTapRewind: () => _seekRelative(-10),
                    onDoubleTapForward: () => _seekRelative(10),
                    onTap: _toggleControlsVisibility,
                    child: _videoController != null
                        ? PlayerSurface(controller: _videoController!)
                        : Container(color: Colors.black),
                  ),
                ),

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
                    onBack: _handleBack,
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
                    onBack: _handleBack,
                    onUserInteraction: _onUserInteraction,
                    onSeek: _onSeek,
                    onScrubbingChanged: _onScrubbingChanged,
                    seekPreviewController: _seekPreviewController,
                    previewMeta: _previewMeta,
                    onRestart: _restart,
                    onOpenSpeedSheet: _openPlaybackSpeedSheet,
                    onOpenAudioSheet: _openAudioTrackSheet,
                    onOpenSubtitleSheet: _openSubtitleTrackSheet,
                    playbackRate: _rate,
                    hasActiveSubtitles: hasSubtitles,
                    hudMessage: _hudMessage,
                    hudIcon: _hudIcon,
                    isHudVisible: _isHudVisible,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
