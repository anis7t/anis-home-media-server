import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_endpoints.dart';
import '../../../core/device/infrastructure/device_capability_service.dart';
import '../../../core/storage/device_identity_service.dart';
import '../../../core/storage/settings_service.dart';
import '../../cast/presentation/controllers/cast_controller.dart';
import '../../cast/presentation/widgets/cast_device_sheet.dart';
import '../../connection/controllers/connection_controller.dart';
import '../application/playback_progress_reporter.dart';
import '../domain/playback_mode.dart';
import '../domain/player_controller_interface.dart';
import '../domain/player_overlay_status.dart';
import '../domain/seek_preview_controller.dart';
import '../domain/tv_player_focus.dart';
import '../infrastructure/media_kit_player_adapter.dart';
import '../infrastructure/media_volume_service.dart';
import '../infrastructure/player_media_resolver.dart';
import '../infrastructure/screen_brightness_service.dart';
import 'widgets/double_tap_seek_detector.dart';
import 'widgets/playback_speed_sheet.dart';
import 'widgets/player_cast_bar.dart';
import 'widgets/player_controls_overlay.dart';
import 'widgets/player_details_panel.dart';
import 'widgets/player_error_card.dart';
import 'widgets/player_hud_toast.dart';
import 'widgets/player_key_dispatcher.dart';
import 'widgets/player_loading_indicator.dart';
import 'widgets/player_surface.dart';
import 'widgets/track_selector_sheet.dart';

export '../domain/player_overlay_status.dart';
export '../domain/tv_player_focus.dart';

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
  final ScreenBrightnessService? customBrightness;
  final MediaVolumeService? customMediaVolume;

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
    this.customBrightness,
    this.customMediaVolume,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> with WidgetsBindingObserver {
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

  // Vertical-swipe gestures: the left half of the surface drives brightness,
  // the right half volume. Values are captured at drag start so the mapping
  // stays absolute no matter how many updates arrive.
  late final ScreenBrightnessService _brightnessService =
      widget.customBrightness ?? ScreenBrightnessService();
  late final MediaVolumeService _mediaVolume =
      widget.customMediaVolume ?? MediaVolumeService();
  /// Mirror of the system media volume (0-100) - the level the user hears.
  double _systemVolume = 50.0;
  double _brightness = 0.5;
  double _dragStartVolume = 100.0;
  double _dragStartBrightness = 0.5;
  bool _isFullscreen = false;
  double _rate = 1.0;

  // Track state
  PlayerTrackInfo _trackInfo = const PlayerTrackInfo();
  List<PlayerSubtitleTrack> _sidecarSubtitles = [];

  // In-player coordinated overlay status
  PlaybackOverlayType _overlayType = PlaybackOverlayType.none;
  String? _hudMessage;
  IconData? _hudIcon;
  Timer? _hudTimer;
  Timer? _seekSettleTimer;
  int _accumulatedSeekSeconds = 0;

  PlaybackOverlayStatus get _currentOverlayStatus {
    if (_overlayType == PlaybackOverlayType.seeking) {
      final sign = _accumulatedSeekSeconds >= 0
          ? '+$_accumulatedSeekSeconds'
          : '$_accumulatedSeekSeconds';
      return PlaybackOverlayStatus(
        type: PlaybackOverlayType.seeking,
        message: '$sign sec',
        icon: _accumulatedSeekSeconds >= 0
            ? Icons.fast_forward_rounded
            : Icons.fast_rewind_rounded,
      );
    }
    if (_overlayType == PlaybackOverlayType.toast && _hudMessage != null) {
      return PlaybackOverlayStatus(
        type: PlaybackOverlayType.toast,
        message: _hudMessage,
        icon: _hudIcon,
      );
    }
    final isOpening = _state == PlayerPlaybackState.opening ||
        (_state == PlayerPlaybackState.idle && _errorMessage == null);
    if (isOpening) {
      return const PlaybackOverlayStatus(
        type: PlaybackOverlayType.opening,
        message: 'Loading Media',
        subMessage: 'Initializing player & stream...',
      );
    }
    if (_isBuffering && !_isScrubbing && !_isDoubleTapSeeking) {
      return const PlaybackOverlayStatus(
        type: PlaybackOverlayType.buffering,
        message: 'Buffering Stream',
        subMessage: 'Filling playback buffer...',
      );
    }
    return PlaybackOverlayStatus.none;
  }

  bool _controlsVisible = true;
  Timer? _autoHideTimer;
  // Casting: the server owns discovery and control, this only polls the state.
  Timer? _castPollTimer;
  String? _errorMessage;

  // Double-tap seek state
  bool _isDoubleTapSeeking = false;
  Timer? _doubleTapSeekTimer;

  // Aspect ratio state
  BoxFit _videoFit = BoxFit.contain;

  // TMDb & media metadata
  Map<String, dynamic>? _movieMeta;
  CancelToken? _metaCancelToken;

  /// Writes the resume point back to the server (`POST /api/progress`).
  PlaybackProgressReporter? _progress;

  /// Authoritative playback mode reported by the server's `/api/media-info`
  /// (`direct_play`). Never derived from the URL, filename, codec or subtitle.
  PlaybackMode _playbackMode = PlaybackMode.unknown;

  // Seek preview & scrubbing state
  late final SeekPreviewController _seekPreviewController;
  PreviewUrlResolver? _previewUrlResolver;
  Map<String, dynamic>? _previewMeta;
  CancelToken? _previewCancelToken;
  CancelToken? _subtitlesCancelToken;
  bool _isScrubbing = false;

  // D-pad hold-seek state (TV)
  int _dpadHoldCount = 0;
  int _dpadHoldDirection = 0; // -1 = left, 1 = right, 0 = none
  Timer? _dpadHoldResetTimer;

  final FocusNode _keyboardFocusNode = FocusNode();

  // 10-foot TV navigation state
  TvPlayerFocusZone _tvFocusZone = TvPlayerFocusZone.timeline;
  int _tvFocusedControlIndex = 1; // Default to Play/Pause
  static const int _tvControlCount = 7;

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

    WidgetsBinding.instance.addObserver(this);

    // Captured now: the reporter's flush also runs from dispose(), where `ref`
    // is no longer usable.
    final identity = ref.read(deviceIdentityServiceProvider);
    // Resolved in the background so no save ever waits on it: the device id only
    // feeds watch history, and a test's platform channel never answers - awaiting
    // it there would stall the POST entirely.
    String? deviceId;
    identity.getOrCreateDeviceId().then(
      (id) => deviceId = id,
      onError: (_) {},
    );

    // The web player has always persisted progress; the app only read it, so a
    // resume point never moved when the app was the one playing.
    _progress = PlaybackProgressReporter(
      save: (position, duration) async {
        final filename = _resolveFilename();
        final origin = _apiServerOrigin();
        if (filename == null || filename.isEmpty || origin == null) return;
        // Fire-and-forget from the player's teardown paths: no Dio timeout
        // timers may outlive the widget ("A Timer is still pending even after
        // the widget tree was disposed"), and the shared client's connect
        // timeout cannot be overridden per request. Tests inject customDio.
        final owned = widget.customDio == null;
        final client = widget.customDio ??
            Dio(
              BaseOptions(
                connectTimeout: null,
                receiveTimeout: null,
                sendTimeout: null,
              ),
            );
        try {
          await client.post(
            '$origin${ApiEndpoints.progress}',
            data: {
              'filename': filename,
              'position': position.inMilliseconds / 1000,
              'duration': duration.inMilliseconds / 1000,
            },
            options: Options(
              headers: deviceId == null ? null : {'X-Device-Id': deviceId},
              validateStatus: (status) => status != null && status < 500,
            ),
          );
        } catch (_) {
          // progress is best-effort: a failed save must never disturb playback
        } finally {
          if (owned) client.close();
        }
      },
    );

    _listenToStreams();
    _bootstrap();

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
          _progress?.onPause();
        } else if (s == PlayerPlaybackState.completed) {
          _progress?.onEnded();
        }
      });
    }));

    _subscriptions.add(_controller.positionStream.listen((p) {
      if (!mounted) return;
      _progress?.onPosition(p, _duration);
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

  String? _effectiveMediaUrl;
  String? _effectiveServerOrigin;

  /// Origin resolved for API calls / HLS URLs once the saved server is known.
  String? _resolvedApiOrigin;

  String? _resolveFilename() =>
      PlayerMediaResolver.resolveFilename(_effectiveMediaUrl ?? widget.mediaUrl, widget.mediaFilename);

  Future<String> _resolveEffectiveMediaUrl() async {
    if (widget.customController != null) {
      return widget.mediaUrl;
    }
    String? activeUrl;
    try {
      activeUrl = ref.read(connectionControllerProvider).serverUrl;
    } catch (_) {}
    String? savedUrl;
    try {
      savedUrl = await ref.read(settingsServiceProvider).getServerBaseUrl();
    } catch (_) {}
    return PlayerMediaResolver.resolveEffectiveMediaUrl(
      rawMediaUrl: widget.mediaUrl,
      hasCustomController: false,
      activeConnectionServerUrl: activeUrl,
      savedSettingsServerUrl: savedUrl,
    );
  }

  String? _resolveServerOrigin() {
    String? activeUrl;
    try {
      activeUrl = ref.read(connectionControllerProvider).serverUrl;
    } catch (_) {}
    return PlayerMediaResolver.resolveServerOrigin(
      effectiveServerOrigin: _effectiveServerOrigin,
      effectiveMediaUrl: _effectiveMediaUrl,
      rawMediaUrl: widget.mediaUrl,
      activeConnectionServerUrl: activeUrl,
    );
  }

  Future<void> _loadPreviewMeta() async {
    setState(() => _previewMeta = null);
    if (widget.customController != null && widget.customDio == null) return;
    try {
      final filename = _resolveFilename();
      final serverOrigin = _apiServerOrigin();
      if (filename == null || serverOrigin == null) return;

      _previewCancelToken?.cancel();
      _previewCancelToken = CancelToken();

      final data = await PlayerMediaResolver.loadPreviewMeta(
        dio: _apiDio(),
        serverOrigin: serverOrigin,
        filename: filename,
        cancelToken: _previewCancelToken,
      );
      if (!mounted) return;
      if (data != null) {
        setState(() {
          _previewMeta = data;
          final template = data['url_template'] as String?;
          if (template != null) {
            _previewUrlResolver = (frameIndex, sequenceId) async {
              return '$serverOrigin${template.replaceAll('{frame}', frameIndex.toString()).replaceAll('{seq}', sequenceId.toString())}';
            };
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _fetchSidecarSubtitles() async {
    if (widget.customController != null && widget.customDio == null) return;
    try {
      final filename = _resolveFilename();
      final serverOrigin = _apiServerOrigin();
      if (filename == null || serverOrigin == null) return;

      _subtitlesCancelToken?.cancel();
      _subtitlesCancelToken = CancelToken();

      final sidecars = await PlayerMediaResolver.fetchSidecarSubtitles(
        dio: _apiDio(),
        serverOrigin: serverOrigin,
        filename: filename,
        cancelToken: _subtitlesCancelToken,
      );
      if (!mounted) return;
      setState(() => _sidecarSubtitles = sidecars);
    } catch (_) {}
  }

  Future<void> _loadMovieMeta() async {
    if (widget.customController != null && widget.customDio == null) return;
    try {
      final filename = _resolveFilename();
      final serverOrigin = _apiServerOrigin();
      if (filename == null || serverOrigin == null) return;

      _metaCancelToken?.cancel();
      _metaCancelToken = CancelToken();

      final meta = await PlayerMediaResolver.loadMovieMeta(
        dio: _apiDio(),
        serverOrigin: serverOrigin,
        filename: filename,
        cancelToken: _metaCancelToken,
        onModeResolved: (mode) {
          if (mounted) setState(() => _playbackMode = mode);
        },
        onOverviewResolved: (meta) {
          if (mounted) setState(() => _movieMeta = meta);
        },
      );

      debugPrint(
        '[Player] media-info probe: http=200 direct_play=${meta['direct_play']} ($serverOrigin/api/media-info/$filename)',
      );

      if (mounted) {
        setState(() {
          _playbackMode = PlaybackMode.fromDirectPlay(meta['direct_play']);
          if (meta.isNotEmpty) {
            _movieMeta = meta;
          }
        });
      }
    } catch (e) {
      debugPrint(
        '[Player] media-info probe failed for ${_resolveFilename()} @ ${_apiServerOrigin()}: $e',
      );
    }
  }

  Future<void> _bootstrap() async {
    await _resolveAndSyncApiOrigin();
    if (!mounted) return;
    try {
      await _loadMovieMeta().timeout(const Duration(seconds: 5));
    } catch (_) {}
    if (!mounted) return;
    await _openMedia();
  }

  Future<String?> _resolveApiOrigin() async {
    final candidate = _resolveServerOrigin();
    final isLoopback = candidate == null ||
        candidate.contains('127.0.0.1') ||
        candidate.contains('localhost');
    if (!isLoopback) return candidate;
    if (widget.customController != null) return candidate;

    try {
      final active = ref.read(connectionControllerProvider).serverUrl;
      final activeUri = Uri.tryParse(active);
      if (active.isNotEmpty &&
          !active.contains('127.0.0.1') &&
          !active.contains('localhost') &&
          activeUri != null &&
          activeUri.hasScheme &&
          activeUri.hasAuthority) {
        return activeUri.origin;
      }
    } catch (_) {}

    try {
      final saved = await ref.read(settingsServiceProvider).getServerBaseUrl();
      final savedUri = Uri.tryParse(saved);
      if (saved.isNotEmpty &&
          !saved.contains('127.0.0.1') &&
          !saved.contains('localhost') &&
          savedUri != null &&
          savedUri.hasScheme &&
          savedUri.hasAuthority) {
        return savedUri.origin;
      }
    } catch (_) {}

    return candidate;
  }

  Future<void> _resolveAndSyncApiOrigin() async {
    final origin = await _resolveApiOrigin();
    if (origin == null || origin.isEmpty || !mounted) return;
    _resolvedApiOrigin = origin;
    try {
      final dio = _apiDio();
      if (dio.options.baseUrl != origin) {
        dio.options.baseUrl = origin;
      }
    } catch (_) {}
  }

  String? _apiServerOrigin() => _resolvedApiOrigin ?? _resolveServerOrigin();

  Dio _apiDio() => widget.customDio ?? ref.read(apiClientProvider).dio;

  String _applyAuthoritativeMode(String url) {
    if (_playbackMode != PlaybackMode.hls) return url;
    final filename = _resolveFilename();
    if (filename == null || filename.isEmpty) return url;
    final origin = _apiServerOrigin();
    if (origin == null || origin.isEmpty) return url;
    return '$origin/hls/${Uri.encodeComponent(filename)}/playlist.m3u8';
  }

  Future<void> _openMedia() async {
    setState(() {
      _errorMessage = null;
      _state = PlayerPlaybackState.opening;
    });

    final resolvedUrl = await _resolveEffectiveMediaUrl();
    final effectiveUrl = _applyAuthoritativeMode(resolvedUrl);
    _effectiveMediaUrl = effectiveUrl;
    final effUri = Uri.tryParse(effectiveUrl);
    if (effUri != null && effUri.hasScheme && effUri.hasAuthority) {
      _effectiveServerOrigin = effUri.origin;
    }

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
        effectiveUrl,
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

  void _onSurfaceTap() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
      if (_state == PlayerPlaybackState.playing && !_isScrubbing) {
        _resetAutoHideTimer();
      }
    } else {
      _togglePlayPause();
    }
  }

  void _resetAutoHideTimer() {
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(const Duration(milliseconds: 4000), () {
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
    _seekSettleTimer?.cancel();
    _accumulatedSeekSeconds = 0;
    setState(() {
      _hudMessage = message;
      _hudIcon = icon;
      _overlayType = PlaybackOverlayType.toast;
    });
    _hudTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) {
        setState(() {
          if (_overlayType == PlaybackOverlayType.toast) {
            _overlayType = PlaybackOverlayType.none;
          }
        });
      }
    });
  }

  bool get _casting => ref.read(castControllerProvider).isCasting;

  Duration get _transportPosition =>
      _casting ? ref.read(castControllerProvider).position : _position;

  Duration get _transportDuration {
    if (!_casting) return _duration;
    final castDuration = ref.read(castControllerProvider).duration;
    return castDuration > Duration.zero ? castDuration : _duration;
  }

  void _sendCastSeek(Duration target) {
    _progress?.onSeek(target);
    unawaited(
      ref.read(castControllerProvider.notifier)
          .sendControl('seek', value: target.inMilliseconds / 1000),
    );
    if (mounted) setState(() => _position = target);
  }

  Future<void> _restart() async {
    _onUserInteraction();
    if (_casting) {
      _sendCastSeek(Duration.zero);
      _showHudToast('Restarted on ${_castName()}', icon: Icons.replay_rounded);
      return;
    }
    await _controller.seek(Duration.zero);
    _showHudToast('Restarted', icon: Icons.replay_rounded);
  }

  String _castName() => ref.read(castControllerProvider).activeDevice?.name ?? 'the device';

  void _openCastSheet() {
    _onUserInteraction();
    CastDeviceSheet.show(
      context: context,
      filename: _resolveFilename(),
      position: _position > Duration.zero ? _position : null,
      onStarted: (deviceName) {
        unawaited(_controller.pause());
        _showHudToast('Casting to $deviceName', icon: Icons.cast_connected_rounded);
        _startCastPolling();
      },
    );
  }

  void _startCastPolling() {
    _castPollTimer?.cancel();
    _castPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      final cast = ref.read(castControllerProvider);
      if (!cast.isCasting) {
        _castPollTimer?.cancel();
        return;
      }
      ref.read(castControllerProvider.notifier).pollStatus();
    });
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
    if (_casting) {
      final cast = ref.read(castControllerProvider);
      final playing = cast.playbackState == 'playing';
      await ref.read(castControllerProvider.notifier).sendControl(playing ? 'pause' : 'play');
      _showHudToast(
        playing ? 'Paused on ${_castName()}' : 'Playing on ${_castName()}',
        icon: Icons.cast_connected_rounded,
      );
      return;
    }
    if (_state == PlayerPlaybackState.playing) {
      await _controller.pause();
      _cancelAutoHideTimer();
      setState(() => _controlsVisible = true);
    } else {
      await _controller.play();
      _resetAutoHideTimer();
    }
  }

  void _cycleAspectRatio() {
    _onUserInteraction();
    setState(() {
      if (_videoFit == BoxFit.contain) {
        _videoFit = BoxFit.cover;
      } else if (_videoFit == BoxFit.cover) {
        _videoFit = BoxFit.fill;
      } else {
        _videoFit = BoxFit.contain;
      }
    });
    final label = _videoFit == BoxFit.contain
        ? 'Aspect: Fit (Original)'
        : (_videoFit == BoxFit.cover ? 'Aspect: Crop to Fill' : 'Aspect: Stretch');
    _showHudToast(label, icon: Icons.aspect_ratio_rounded);
  }

  Future<void> _seekRelative(int seconds, {bool fromDoubleTap = false}) async {
    _onUserInteraction();
    _hudTimer?.cancel();
    _seekSettleTimer?.cancel();

    if (fromDoubleTap) {
      _doubleTapSeekTimer?.cancel();
      setState(() {
        _isDoubleTapSeeking = true;
        _accumulatedSeekSeconds = 0;
        if (_overlayType == PlaybackOverlayType.seeking) {
          _overlayType = PlaybackOverlayType.none;
        }
      });
      _doubleTapSeekTimer = Timer(const Duration(milliseconds: 1000), () {
        if (mounted) setState(() => _isDoubleTapSeeking = false);
      });
    } else {
      if (_overlayType == PlaybackOverlayType.seeking) {
        if ((_accumulatedSeekSeconds >= 0 && seconds >= 0) ||
            (_accumulatedSeekSeconds <= 0 && seconds <= 0)) {
          _accumulatedSeekSeconds += seconds;
        } else {
          _accumulatedSeekSeconds = seconds;
        }
      } else {
        _accumulatedSeekSeconds = seconds;
      }
      setState(() {
        _overlayType = PlaybackOverlayType.seeking;
      });
    }

    final cur = _transportPosition.inSeconds;
    final maxSec = _transportDuration.inSeconds;
    final targetSec = maxSec > 0
        ? (cur + seconds).clamp(0, maxSec)
        : ((cur + seconds) < 0 ? 0 : (cur + seconds));
    final target = Duration(seconds: targetSec);

    if (_casting) {
      _sendCastSeek(target);
    } else {
      await _controller.seek(target);
      _progress?.onSeek(target);
      if (mounted) {
        setState(() => _position = target);
      }
    }

    if (!fromDoubleTap) {
      _seekSettleTimer = Timer(const Duration(milliseconds: 1000), () {
        if (mounted) {
          setState(() {
            _accumulatedSeekSeconds = 0;
            if (_overlayType == PlaybackOverlayType.seeking) {
              _overlayType = PlaybackOverlayType.none;
            }
          });
        }
      });
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

  void _onVerticalDragBegin(bool fromLeftHalf) {
    _dragStartVolume = _systemVolume;
    _dragStartBrightness = _brightness;
    if (!fromLeftHalf) {
      _mediaVolume.getVolume().then((value) {
        if (value != null) {
          _dragStartVolume = value.toDouble();
          _systemVolume = value.toDouble();
        }
      });
    }
  }

  void _onVerticalDragDelta(double fraction, bool fromLeftHalf) {
    if (fromLeftHalf) {
      _setBrightness(_dragStartBrightness + fraction);
    } else {
      _setVolumeFromGesture(_dragStartVolume + fraction * 100.0);
    }
  }

  void _setBrightness(double value) {
    final next = value.clamp(0.01, 1.0);
    setState(() => _brightness = next);
    _brightnessService.setBrightness(next);
    _showHudToast(
      '${(next * 100).round()}% Brightness',
      icon: Icons.brightness_6_rounded,
    );
  }

  void _setVolumeFromGesture(double value) {
    final next = value.clamp(0.0, 100.0);
    final percent = next.round();
    _systemVolume = percent.toDouble();
    _mediaVolume.setVolume(percent);
    _showHudToast(
      '$percent% Volume',
      icon: percent <= 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
    );
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
    if (_casting) {
      _sendCastSeek(target);
      return;
    }
    _controller.seek(target);
    _progress?.onSeek(target);
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

  void _triggerTvControlAction(int index) {
    switch (index) {
      case 0:
        _restart();
        break;
      case 1:
        _togglePlayPause();
        break;
      case 2:
        _toggleMute();
        break;
      case 3:
        _openPlaybackSpeedSheet();
        break;
      case 4:
        _openAudioTrackSheet();
        break;
      case 5:
        _openSubtitleTrackSheet();
        break;
      case 6:
        _cycleAspectRatio();
        break;
    }
  }

  /// Computes the preview frame index for [target] using loaded preview metadata.
  /// Returns null when no metadata is available.
  int? _computeFrameIndex(Duration target) {
    final meta = _previewMeta;
    if (meta == null) return null;
    final interval = (meta['interval'] as num?)?.toDouble() ?? 0.0;
    final count = (meta['count'] as num?)?.toInt() ?? 0;
    if (interval <= 0 || count <= 0) return null;
    final seconds = target.inMilliseconds / 1000.0;
    return (seconds / interval).floor().clamp(0, count - 1);
  }

  /// Called by [PlayerKeyDispatcher] after every D-pad timeline seek.
  /// Requests a preview frame for the current (post-seek) position.
  void _onDpadSeekPreviewRequest(Duration _) {
    // Use the latest known transport position (already updated by _seekRelative)
    final frameIndex = _computeFrameIndex(_position);
    if (frameIndex != null) {
      _seekPreviewController.requestFrame(frameIndex);
    }
  }

  bool _handleKeyEvent(KeyEvent event) {
    final isTv = ref.read(isTvModeProvider);
    // Track consecutive D-pad hold repeats for step acceleration
    final key = event.logicalKey;
    final isLeftKey = key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyJ;
    final isRightKey = key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyL;
    if (isLeftKey || isRightKey) {
      final dir = isLeftKey ? -1 : 1;
      if (event is KeyRepeatEvent && _dpadHoldDirection == dir) {
        _dpadHoldCount++;
      } else {
        // Fresh key-down or direction changed — reset count
        _dpadHoldCount = 0;
        _dpadHoldDirection = dir;
      }
      // Auto-reset after 500ms of no key events
      _dpadHoldResetTimer?.cancel();
      _dpadHoldResetTimer = Timer(const Duration(milliseconds: 500), () {
        _dpadHoldCount = 0;
        _dpadHoldDirection = 0;
      });
    } else if (event is KeyDownEvent) {
      // Non-directional key: clear hold state
      _dpadHoldCount = 0;
      _dpadHoldDirection = 0;
      _dpadHoldResetTimer?.cancel();
    }

    return PlayerKeyDispatcher.handleKeyEvent(
      event: event,
      context: context,
      isTv: isTv,
      controlsVisible: _controlsVisible,
      isFullscreen: _isFullscreen,
      state: _state,
      volume: _volume,
      tvFocusZone: _tvFocusZone,
      tvFocusedControlIndex: _tvFocusedControlIndex,
      tvControlCount: _tvControlCount,
      onTogglePlayPause: _togglePlayPause,
      onSeekRelative: (s) => _seekRelative(s),
      onUserInteraction: _onUserInteraction,
      onSetTvFocusZone: (zone) => setState(() => _tvFocusZone = zone),
      onSetTvFocusedControlIndex: (idx) => setState(() => _tvFocusedControlIndex = idx),
      onTriggerTvControlAction: _triggerTvControlAction,
      onOpenSubtitleTrackSheet: _openSubtitleTrackSheet,
      onOpenAudioTrackSheet: _openAudioTrackSheet,
      onToggleMute: _toggleMute,
      onRestart: _restart,
      onHandleBack: ({required bool forceExit}) => _handleBack(forceExit: forceExit),
      onHideControls: () => setState(() => _controlsVisible = false),
      onVolumeChanged: _onVolumeChanged,
      onShowHudToast: (msg, {icon}) => _showHudToast(msg, icon: icon),
      onToggleFullscreen: _toggleFullscreen,
      dpadHoldCount: _dpadHoldCount,
      onRequestSeekPreview: _previewMeta != null ? _onDpadSeekPreviewRequest : null,
    );
  }

  Future<void> _handleBack({bool forceExit = false}) async {
    final isTv = ref.read(isTvModeProvider);
    if (!forceExit) {
      if (!_controlsVisible) {
        _onUserInteraction();
        if (isTv) {
          setState(() => _tvFocusZone = TvPlayerFocusZone.timeline);
        }
        return;
      }
      if (!isTv && _isFullscreen) {
        await _toggleFullscreen();
        return;
      }
    }

    _cancelAutoHideTimer();
    _castPollTimer?.cancel();
    _hudTimer?.cancel();
    _seekSettleTimer?.cancel();
    _doubleTapSeekTimer?.cancel();

    _progress?.flush();
    _progress?.dispose();

    try {
      await _controller.stop();
    } catch (_) {}

    if (mounted) {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      } else {
        try {
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/library');
          }
        } catch (_) {}
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _controller.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subscriptions) {
      s.cancel();
    }
    _cancelAutoHideTimer();
    _castPollTimer?.cancel();
    _hudTimer?.cancel();
    _seekSettleTimer?.cancel();
    _doubleTapSeekTimer?.cancel();
    _dpadHoldResetTimer?.cancel();
    _metaCancelToken?.cancel();
    _previewCancelToken?.cancel();
    _subtitlesCancelToken?.cancel();
    _seekPreviewController.dispose();
    _keyboardFocusNode.dispose();
    _progress?.dispose();
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  Widget _buildPlayerStack({
    required bool isOpening,
    required bool hasError,
    required bool hasSubtitles,
  }) {
    final castState = ref.watch(castControllerProvider);
    final isTv = ref.watch(isTvModeProvider);
    final overlayStatus = _currentOverlayStatus;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. Isolated video surface with DoubleTapSeekDetector
        Positioned.fill(
          child: DoubleTapSeekDetector(
            onDoubleTapRewind: () => _seekRelative(-10, fromDoubleTap: true),
            onDoubleTapForward: () => _seekRelative(10, fromDoubleTap: true),
            onTap: _onSurfaceTap,
            onVerticalDragBegin: _onVerticalDragBegin,
            onVerticalDragDelta: _onVerticalDragDelta,
            child: _videoController != null
                ? PlayerSurface(controller: _videoController!, fit: _videoFit)
                : Container(color: Colors.black),
          ),
        ),

        // 2. Loading / Buffering indicator (rendered exclusively when status is opening or buffering)
        if (overlayStatus.isOpening || overlayStatus.isBuffering)
          IgnorePointer(
            child: PlayerLoadingIndicator(
              title: overlayStatus.message ??
                  (overlayStatus.isOpening ? 'Loading Media' : 'Buffering Stream'),
              message: overlayStatus.subMessage ??
                  (overlayStatus.isOpening
                      ? 'Initializing player & stream...'
                      : 'Filling playback buffer...'),
            ),
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
            isPlaying: castState.isCasting
                ? castState.playbackState == 'playing'
                : _state == PlayerPlaybackState.playing,
            isBuffering: castState.isCasting
                ? castState.playbackState == 'buffering'
                : overlayStatus.isBuffering,
            position: _transportPosition,
            duration: _transportDuration,
            volume: _volume,
            isFullscreen: isTv || _isFullscreen,
            onTogglePlay: _togglePlayPause,
            onVolumeChanged: _onVolumeChanged,
            onToggleMute: _toggleMute,
            onToggleFullscreen: isTv ? null : () => _toggleFullscreen(),
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
            onToggleAspectRatio: _cycleAspectRatio,
            onSurfaceTap: _onSurfaceTap,
            onDoubleTapRewind: () => _seekRelative(-10, fromDoubleTap: true),
            onDoubleTapForward: () => _seekRelative(10, fromDoubleTap: true),
            playbackRate: _rate,
            hasActiveSubtitles: hasSubtitles,
            isDoubleTapSeeking: _isDoubleTapSeeking,
            isOverlayActive: overlayStatus.isVisible,
            onOpenCastSheet: isTv || _resolveFilename() == null ? null : _openCastSheet,
            isCasting: castState.isCasting,
            isTv: isTv,
            isTimelineFocused: isTv && _tvFocusZone == TvPlayerFocusZone.timeline,
            tvFocusedControlIndex: (isTv && _tvFocusZone == TvPlayerFocusZone.controls)
                ? _tvFocusedControlIndex
                : -1,
          ),

        // 5. Action-feedback HUD / Seek feedback (rendered exclusively when status is seeking or toast)
        Positioned.fill(
          child: Align(
            alignment: const Alignment(0.0, -0.35),
            child: PlayerHudToast(
              message: (overlayStatus.isSeeking || overlayStatus.isToast)
                  ? overlayStatus.message
                  : null,
              icon: (overlayStatus.isSeeking || overlayStatus.isToast)
                  ? overlayStatus.icon
                  : null,
              isVisible: overlayStatus.isSeeking || overlayStatus.isToast,
            ),
          ),
        ),

        // 6. Cast Bar overlay
        if (castState.isCasting)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(top: 68),
                child: Center(child: PlayerCastBar(cast: castState)),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTv = ref.watch(isTvModeProvider);
    final showFullscreen = isTv || _isFullscreen;

    final isOpening = _state == PlayerPlaybackState.opening ||
        (_state == PlayerPlaybackState.idle && _errorMessage == null);
    final hasError = _state == PlayerPlaybackState.error || _errorMessage != null;

    final hasSubtitles = _trackInfo.currentSubtitleTrack.id != 'no' &&
        _trackInfo.currentSubtitleTrack.id.isNotEmpty;

    final playerStack = _buildPlayerStack(
      isOpening: isOpening,
      hasError: hasError,
      hasSubtitles: hasSubtitles,
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleBack();
      },
      child: Scaffold(
        backgroundColor: showFullscreen ? Colors.black : AppColors.background,
        body: showFullscreen
            ? Focus(
                focusNode: _keyboardFocusNode,
                autofocus: true,
                onKeyEvent: (node, event) {
                  final handled = _handleKeyEvent(event);
                  return handled ? KeyEventResult.handled : KeyEventResult.ignored;
                },
                child: MouseRegion(
                  onHover: (_) => _onUserInteraction(),
                  child: playerStack,
                ),
              )
            : SafeArea(
                bottom: false,
                child: Focus(
                  focusNode: _keyboardFocusNode,
                  autofocus: true,
                  onKeyEvent: (node, event) {
                    final handled = _handleKeyEvent(event);
                    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
                  },
                  child: MouseRegion(
                    onHover: (_) => _onUserInteraction(),
                    child: Column(
                      children: [
                        const PlayerBrandHeader(),
                        const SizedBox(height: 8),
                        AspectRatio(
                          aspectRatio: 16 / 10.5,
                          child: Container(
                            color: Colors.black,
                            child: playerStack,
                          ),
                        ),
                        Expanded(
                          child: PlayerDetailsPanel(
                            title: widget.title,
                            subtitle: widget.subtitle,
                            serverOrigin: _apiServerOrigin() ?? 'http://127.0.0.1:8000',
                            filename: _resolveFilename() ?? 'Media Stream',
                            playbackMode: _playbackMode,
                            movieMeta: _movieMeta,
                            position: _position,
                            duration: _duration,
                            onBack: _handleBack,
                            onServerUrlChanged: (newUrl) async {
                              await SettingsService().setServerBaseUrl(newUrl);
                              if (mounted) {
                                _showHudToast(
                                  'Server Saved: $newUrl',
                                  icon: Icons.check_circle_rounded,
                                );
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
