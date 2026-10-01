import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../app/routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_endpoints.dart';
import '../../../core/device/infrastructure/device_capability_service.dart';
import '../../../core/storage/device_identity_service.dart';
import '../application/playback_progress_reporter.dart';
import '../../cast/presentation/controllers/cast_controller.dart';
import '../../cast/presentation/widgets/cast_device_sheet.dart';
import '../domain/playback_mode.dart';
import '../../../core/storage/settings_service.dart';
import '../../connection/controllers/connection_controller.dart';
import '../domain/player_controller_interface.dart';
import '../domain/seek_preview_controller.dart';
import '../infrastructure/media_kit_player_adapter.dart';
import '../infrastructure/screen_brightness_service.dart';
import '../infrastructure/media_volume_service.dart';
import 'widgets/double_tap_seek_detector.dart';
import 'widgets/playback_speed_sheet.dart';
import 'widgets/player_controls_overlay.dart';
import 'widgets/player_error_card.dart';
import 'widgets/player_hud_toast.dart';
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

/// 10-foot TV player focus zone hierarchy
enum TvPlayerFocusZone {
  none,
  timeline,
  controls,
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

  // In-player HUD toast feedback
  String? _hudMessage;
  IconData? _hudIcon;
  bool _isHudVisible = false;
  Timer? _hudTimer;

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

  String? _resolveFilename() {
    if (widget.mediaFilename != null && widget.mediaFilename!.isNotEmpty) {
      return widget.mediaFilename;
    }
    final uri = Uri.tryParse(_effectiveMediaUrl ?? widget.mediaUrl);
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

  Future<String> _resolveEffectiveMediaUrl() async {
    final raw = widget.mediaUrl;
    if (widget.customController != null) {
      return raw;
    }
    final parsed = Uri.tryParse(raw);
    final isLocalhost = parsed == null ||
        !parsed.hasScheme ||
        parsed.host == '127.0.0.1' ||
        parsed.host == 'localhost';

    if (isLocalhost) {
      try {
        final active = ref.read(connectionControllerProvider).serverUrl;
        if (active.isNotEmpty &&
            !active.contains('127.0.0.1') &&
            !active.contains('localhost')) {
          final server = active.endsWith('/')
              ? active.substring(0, active.length - 1)
              : active;
          final path = (parsed != null && parsed.hasScheme)
              ? (parsed.hasQuery ? '${parsed.path}?${parsed.query}' : parsed.path)
              : (raw.startsWith('/') ? raw : '/$raw');
          return '$server$path';
        }
      } catch (_) {}
      try {
        final settings = ref.read(settingsServiceProvider);
        final saved = await settings.getServerBaseUrl();
        if (saved.isNotEmpty &&
            !saved.contains('127.0.0.1') &&
            !saved.contains('localhost')) {
          final server = saved.endsWith('/')
              ? saved.substring(0, saved.length - 1)
              : saved;
          final path = (parsed != null && parsed.hasScheme)
              ? (parsed.hasQuery ? '${parsed.path}?${parsed.query}' : parsed.path)
              : (raw.startsWith('/') ? raw : '/$raw');
          return '$server$path';
        }
      } catch (_) {}
    }
    return raw;
  }

  String? _resolveServerOrigin() {
    if (_effectiveServerOrigin != null && _effectiveServerOrigin!.isNotEmpty) {
      return _effectiveServerOrigin;
    }
    final uri = Uri.tryParse(_effectiveMediaUrl ?? widget.mediaUrl);
    if (uri != null &&
        uri.hasScheme &&
        uri.hasAuthority &&
        uri.host != '127.0.0.1' &&
        uri.host != 'localhost') {
      return uri.origin;
    }
    try {
      final connState = ref.read(connectionControllerProvider);
      final active = connState.serverUrl;
      if (active.isNotEmpty &&
          !active.contains('127.0.0.1') &&
          !active.contains('localhost')) {
        final activeUri = Uri.tryParse(active);
        if (activeUri != null &&
            activeUri.hasScheme &&
            activeUri.hasAuthority) {
          return activeUri.origin;
        }
      }
    } catch (_) {}

    if (uri != null && uri.hasScheme && uri.hasAuthority) {
      return uri.origin;
    }
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
      final serverOrigin = _apiServerOrigin();
      if (filename == null || serverOrigin == null) {
        return;
      }

      final encoded = Uri.encodeComponent(filename);
      final url = '$serverOrigin/api/seek-preview-meta/$encoded';

      _previewCancelToken?.cancel();
      _previewCancelToken = CancelToken();

      final dio = _apiDio();
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
      final serverOrigin = _apiServerOrigin();
      if (filename == null || serverOrigin == null) return;

      final encoded = Uri.encodeComponent(filename);
      final url = '$serverOrigin/api/subtitles/$encoded';

      _subtitlesCancelToken?.cancel();
      _subtitlesCancelToken = CancelToken();

      final dio = _apiDio();
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

  Future<void> _loadMovieMeta() async {
    if (widget.customController != null && widget.customDio == null) {
      return;
    }
    try {
      final filename = _resolveFilename();
      final serverOrigin = _apiServerOrigin();
      if (filename == null || serverOrigin == null) return;

      final encoded = Uri.encodeComponent(filename);
      final url = '$serverOrigin/api/media-info/$encoded';

      _metaCancelToken?.cancel();
      _metaCancelToken = CancelToken();

      final dio = _apiDio();
      final res = await dio.get(
        url,
        cancelToken: _metaCancelToken,
        options: Options(
          responseType: ResponseType.json,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      Map<String, dynamic> meta = {};
      if (res.statusCode == 200 && res.data != null && res.data is Map) {
        meta = (res.data as Map).cast<String, dynamic>();
      }

      debugPrint(
        '[Player] media-info probe: http=${res.statusCode} '
        'direct_play=${meta['direct_play']} ($url)',
      );

      // Authoritative playback mode for this stream.
      if (mounted) {
        setState(() {
          _playbackMode = PlaybackMode.fromDirectPlay(meta['direct_play']);
        });
      }

      // Fallback: If overview is missing or empty, fetch from the /movie/$encoded HTML page
      if (meta['overview'] == null || meta['overview'].toString().trim().isEmpty) {
        try {
          final pageUrl = '$serverOrigin/movie/$encoded';
          final pageRes = await dio.get(
            pageUrl,
            cancelToken: _metaCancelToken,
            options: Options(
              responseType: ResponseType.plain,
              validateStatus: (status) => status != null && status < 500,
            ),
          );
          if (pageRes.statusCode == 200 && pageRes.data != null) {
            final html = pageRes.data.toString();
            final synMatch = RegExp(r'class="synopsis-text">\s*(.*?)\s*</p>', dotAll: true).firstMatch(html);
            if (synMatch != null && synMatch.group(1) != null) {
              var syn = synMatch.group(1)!.trim();
              syn = syn
                  .replaceAll('&amp;', '&')
                  .replaceAll('&quot;', '"')
                  .replaceAll('&#39;', "'")
                  .replaceAll('&lt;', '<')
                  .replaceAll('&gt;', '>');
              if (syn.isNotEmpty && !syn.toLowerCase().contains('no synopsis')) {
                meta['overview'] = syn;
              }
            }

            final titleMatch = RegExp(r'<h1 class="movie-title">\s*(.*?)\s*</h1>').firstMatch(html);
            if (titleMatch != null && titleMatch.group(1) != null && meta['title'] == null) {
              meta['title'] = titleMatch.group(1)!.trim();
            }

            final yearMatch = RegExp(r'<span class="meta-pill">(\d{4})</span>').firstMatch(html);
            if (yearMatch != null && yearMatch.group(1) != null && meta['year'] == null) {
              meta['year'] = yearMatch.group(1)!.trim();
            }

            final ratingMatch = RegExp(r'<span class="badge-score">★\s*([\d\.]+)').firstMatch(html);
            if (ratingMatch != null && ratingMatch.group(1) != null && meta['rating'] == null) {
              meta['rating'] = double.tryParse(ratingMatch.group(1)!.trim());
            }

            final genreBlock = RegExp(r'<div class="genre-chips">(.*?)</div>', dotAll: true).firstMatch(html)?.group(1);
            if (genreBlock != null && meta['genres'] == null) {
              final genres = RegExp(r'<span>([^<]+)</span>').allMatches(genreBlock).map((m) => m.group(1)!.trim()).toList();
              if (genres.isNotEmpty) {
                meta['genres'] = genres.join(', ');
              }
            }
          }
        } catch (_) {}
      }

      if (!mounted) return;
      if (meta.isNotEmpty) {
        setState(() {
          _movieMeta = meta;
        });
      }
    } catch (e) {
      // Non-fatal metadata fetch - but never silent: an unreachable server is
      // exactly what a "mode unavailable" badge means.
      debugPrint(
        '[Player] media-info probe failed for ${_resolveFilename()} '
        '@ ${_apiServerOrigin()}: $e',
      );
    }
  }

  /// Resolves the authoritative playback mode, then opens the stream the way
  /// the server says it must be served (direct byte-range vs HLS playlist).
  ///
  /// The probe is bounded on purpose: a slow or unreachable server must never
  /// hold playback hostage. On timeout the mode stays [PlaybackMode.unknown],
  /// the UI claims no mode, and the stream opens with the URL it was given.
  Future<void> _bootstrap() async {
    // Resolve the API origin and point the shared client at it before probing:
    // on a cold start (or a launch without an explicit server) the media URL is
    // the route's 127.0.0.1 default, so every API call - and the HLS URL - would
    // otherwise target the phone itself.
    await _resolveAndSyncApiOrigin();
    try {
      await _loadMovieMeta().timeout(const Duration(seconds: 5));
    } catch (_) {
      // Mode/metadata probe is best-effort - playback must still start.
    }
    if (!mounted) return;
    await _openMedia();
  }

  /// Origin the player's API calls and HLS URLs must use.
  ///
  /// The *saved* server is the app's active origin and wins whenever the origin
  /// derived from the media URL is loopback (the route's default when the player
  /// is opened without an explicit `server`). Mirrors `_resolveEffectiveMediaUrl`
  /// so injected-controller tests never touch the settings plugin.
  Future<String?> _resolveApiOrigin() async {
    final candidate = _resolveServerOrigin();
    final isLoopback = candidate == null ||
        candidate.contains('127.0.0.1') ||
        candidate.contains('localhost');
    if (!isLoopback) return candidate;
    if (widget.customController != null) return candidate;

    // 1. The connection controller's active server (no plugin call).
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

    // 2. The persisted server (unavailable in unit tests - non-fatal).
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

  /// Resolves [ _resolvedApiOrigin] and keeps the shared client in step with it.
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

  /// The origin to build API and HLS URLs from (see [ _resolveApiOrigin]).
  String? _apiServerOrigin() => _resolvedApiOrigin ?? _resolveServerOrigin();

  /// The HTTP client every API call in this screen goes through.
  ///
  /// The app's shared client - it carries the device id these routes expect, its
  /// timeouts, and the active origin. A bare `Dio()` here was the only place in
  /// the app that bypassed it.
  Dio _apiDio() => widget.customDio ?? ref.read(apiClientProvider).dio;

  /// Routes the stream exactly the way the server advertises it.
  ///
  /// The only input is the authoritative `direct_play` flag: media the server
  /// marks as HLS-only is opened as its HLS playlist, everything else keeps the
  /// direct byte-range URL. With no authoritative value the URL is untouched.
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

  /// While a TV owns playback the phone is a remote: transport actions go to the cast,
  /// never to the local player (which stays paused for the whole cast).
  bool get _casting => ref.read(castControllerProvider).isCasting;

  /// The position the controls act on: the TV's while casting, the local player's otherwise.
  Duration get _transportPosition =>
      _casting ? ref.read(castControllerProvider).position : _position;

  Duration get _transportDuration {
    if (!_casting) return _duration;
    final castDuration = ref.read(castControllerProvider).duration;
    return castDuration > Duration.zero ? castDuration : _duration;
  }

  /// Moves the TV to [target]. The cast controller shows it immediately and the status
  /// poll corrects any drift the receiver adds.
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

  /// Device picker. Casting hands the media to a TV, so the phone stops playing it.
  void _openCastSheet() {
    _onUserInteraction();
    CastDeviceSheet.show(
      context: context,
      // Deep links can arrive without a filename; _resolveFilename reads it out of
      // the media URL in that case, so casting works from every entry point.
      filename: _resolveFilename(),
      position: _position > Duration.zero ? _position : null,
      onStarted: (deviceName) {
        unawaited(_controller.pause());
        _showHudToast('Casting to $deviceName', icon: Icons.cast_connected_rounded);
        _startCastPolling();
      },
    );
  }

  /// Keeps the cast bar honest while a device is playing.
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


  /// Compact remote for the active cast session.
  Widget _buildCastBar(CastState cast) {
    final device = cast.activeDevice;
    if (device == null) return const SizedBox.shrink();
    final isPlaying = cast.playbackState == 'playing';
    // A refusal outranks the transport state only while nothing is playing: on a TV
    // that refuses seeks (UPnP 701) the error would otherwise replace the position
    // for the whole cast, which is the one thing a viewer wants to see.
    final activelyPlaying = cast.playbackState == 'playing' || cast.playbackState == 'paused';
    final label = switch (cast.error != null && !activelyPlaying ? cast.error : cast.playbackState) {
      'playing' => _formatDuration(cast.position),
      'paused' => 'Paused · ${_formatDuration(cast.position)}',
      'buffering' => 'Starting…',
      'stopped' => 'Stopped',
      final other => other,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xE6141822),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFFF334B).withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cast_connected_rounded, color: Color(0xFFFF334B), size: 18),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 170),
            child: Text(
              '${device.name} · $label',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 12),
          InkWell(
            onTap: () => ref
                .read(castControllerProvider.notifier)
                .sendControl(isPlaying ? 'pause' : 'play'),
            child: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          InkWell(
            onTap: () => ref.read(castControllerProvider.notifier).sendControl('stop'),
            child: const Icon(Icons.stop_rounded, color: Color(0xFFFF334B), size: 20),
          ),
        ],
      ),
    );
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
    if (fromDoubleTap) {
      _doubleTapSeekTimer?.cancel();
      setState(() => _isDoubleTapSeeking = true);
      _doubleTapSeekTimer = Timer(const Duration(milliseconds: 1000), () {
        if (mounted) setState(() => _isDoubleTapSeeking = false);
      });
    } else {
      _onUserInteraction();
    }
    final cur = _transportPosition.inSeconds;
    final maxSec = _transportDuration.inSeconds;
    final targetSec = maxSec > 0
        ? (cur + seconds).clamp(0, maxSec)
        : ((cur + seconds) < 0 ? 0 : (cur + seconds));
    final target = Duration(seconds: targetSec);
    if (_casting) {
      _sendCastSeek(target);
      if (!fromDoubleTap) {
        final sign = seconds >= 0 ? '+$seconds' : '$seconds';
        _showHudToast('$sign sec', icon: seconds >= 0 ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded);
      }
      return;
    }
    await _controller.seek(target);
    _progress?.onSeek(target);
    if (mounted) {
      setState(() => _position = target);
      if (!fromDoubleTap) {
        final sign = seconds >= 0 ? '+$seconds' : '$seconds';
        _showHudToast('$sign sec', icon: seconds >= 0 ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded);
      }
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

  /// A vertical drag started: remember what to adjust from.
  void _onVerticalDragBegin(bool fromLeftHalf) {
    _dragStartVolume = _systemVolume;
    _dragStartBrightness = _brightness;
    // The system volume can also be moved with the phone volume keys; re-read it
    // so the swipe continues from where the user actually is.
    if (!fromLeftHalf) {
      _mediaVolume.getVolume().then((value) {
        if (value != null) {
          _dragStartVolume = value.toDouble();
          _systemVolume = value.toDouble();
        }
      });
    }
  }

  /// [fraction] is the drag distance as a fraction of the surface height
  /// (positive = swipe up). Left half = brightness, right half = volume.
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

  /// Right-half swipe: the system media volume, which is the level the user hears.
  /// The app's own player volume stays at full so this is the single control, and
  /// the HUD therefore matches what is audible.
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

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;

    final key = event.logicalKey;
    final isTv = ref.read(isTvModeProvider);

    // 1. Media keys (Universal across TV remote, media keys & keyboard)
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlayPause();
      return true;
    } else if (key == LogicalKeyboardKey.mediaPlay) {
      if (_state != PlayerPlaybackState.playing) {
        _togglePlayPause();
      }
      return true;
    } else if (key == LogicalKeyboardKey.mediaPause) {
      if (_state == PlayerPlaybackState.playing) {
        _togglePlayPause();
      }
      return true;
    } else if (key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      _seekRelative(-15);
      return true;
    } else if (key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      _seekRelative(15);
      return true;
    }

    if (isTv) {
      // -------------------------------------------------------------
      // 10-FOOT TV D-PAD NAVIGATION MODEL
      // Dedicated volume buttons on remote manage TV audio volume.
      // D-pad Up/Down navigates between Timeline (Zone 1) & Controls (Zone 2).
      // -------------------------------------------------------------

      // If controls are hidden: any D-pad input reveals controls
      if (!_controlsVisible) {
        if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyJ) {
          _onUserInteraction();
          _seekRelative(-10);
          setState(() {
            _tvFocusZone = TvPlayerFocusZone.timeline;
          });
          return true;
        } else if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyL) {
          _onUserInteraction();
          _seekRelative(10);
          setState(() {
            _tvFocusZone = TvPlayerFocusZone.timeline;
          });
          return true;
        } else if (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.space ||
            key == LogicalKeyboardKey.keyK) {
          _onUserInteraction();
          setState(() {
            _tvFocusZone = TvPlayerFocusZone.controls;
            _tvFocusedControlIndex = 1; // Default to Play/Pause
          });
          return true;
        } else if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
          _onUserInteraction();
          setState(() {
            _tvFocusZone = TvPlayerFocusZone.timeline;
          });
          return true;
        } else if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
          _handleBack(forceExit: true);
          return true;
        }
        return false;
      }

      // Controls ARE currently visible:
      _onUserInteraction(); // Resets auto-hide timer

      // D-Pad UP: Move from controls into timeline
      if (key == LogicalKeyboardKey.arrowUp) {
        if (_tvFocusZone == TvPlayerFocusZone.controls) {
          setState(() {
            _tvFocusZone = TvPlayerFocusZone.timeline;
          });
          return true;
        }
        return true;
      }

      // D-Pad DOWN: Move from timeline into controls
      if (key == LogicalKeyboardKey.arrowDown) {
        if (_tvFocusZone == TvPlayerFocusZone.timeline) {
          setState(() {
            _tvFocusZone = TvPlayerFocusZone.controls;
          });
          return true;
        }
        return true;
      }

      // D-Pad LEFT
      if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyJ) {
        if (_tvFocusZone == TvPlayerFocusZone.timeline) {
          _seekRelative(-10);
          return true;
        } else {
          setState(() {
            if (_tvFocusedControlIndex > 0) {
              _tvFocusedControlIndex--;
            }
          });
          return true;
        }
      }

      // D-Pad RIGHT
      if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyL) {
        if (_tvFocusZone == TvPlayerFocusZone.timeline) {
          _seekRelative(10);
          return true;
        } else {
          setState(() {
            if (_tvFocusedControlIndex < _tvControlCount - 1) {
              _tvFocusedControlIndex++;
            }
          });
          return true;
        }
      }

      // CENTER / SELECT / ENTER / SPACE
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.keyK) {
        if (_tvFocusZone == TvPlayerFocusZone.timeline) {
          _togglePlayPause();
          return true;
        } else {
          _triggerTvControlAction(_tvFocusedControlIndex);
          return true;
        }
      }

      // Remote shortcut keys
      if (key == LogicalKeyboardKey.contextMenu ||
          key == LogicalKeyboardKey.info ||
          key == LogicalKeyboardKey.keyC) {
        _openSubtitleTrackSheet();
        return true;
      }
      if (key == LogicalKeyboardKey.keyA) {
        _openAudioTrackSheet();
        return true;
      }
      if (key == LogicalKeyboardKey.keyM) {
        _toggleMute();
        return true;
      }
      if (key == LogicalKeyboardKey.home || key == LogicalKeyboardKey.digit0) {
        _restart();
        return true;
      }

      // BACK KEY on TV (Unwind navigation state machine)
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
        if (_tvFocusZone == TvPlayerFocusZone.controls) {
          setState(() {
            _tvFocusZone = TvPlayerFocusZone.timeline;
          });
          return true;
        }
        if (_controlsVisible) {
          setState(() {
            _controlsVisible = false;
          });
          return true;
        }
        _handleBack(forceExit: true);
        return true;
      }

      return false;
    }

    // -------------------------------------------------------------
    // NON-TV (MOBILE / TABLET / DESKTOP) INTERACTION MODEL
    // -------------------------------------------------------------
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.keyK) {
      _togglePlayPause();
      return true;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (!_controlsVisible) {
        _onUserInteraction();
      } else {
        _togglePlayPause();
      }
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyJ) {
      _seekRelative(-10);
      return true;
    } else if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyL) {
      _seekRelative(10);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (!_controlsVisible) {
        _onUserInteraction();
      } else {
        final next = (_volume + 5.0).clamp(0.0, 100.0);
        _onVolumeChanged(next);
        _showHudToast('${next.round()}% Volume', icon: Icons.volume_up_rounded);
      }
      return true;
    } else if (key == LogicalKeyboardKey.arrowDown) {
      if (!_controlsVisible) {
        _onUserInteraction();
      } else {
        final next = (_volume - 5.0).clamp(0.0, 100.0);
        _onVolumeChanged(next);
        _showHudToast('${next.round()}% Volume', icon: Icons.volume_down_rounded);
      }
      return true;
    }
    if (key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.info ||
        key == LogicalKeyboardKey.keyC) {
      _openSubtitleTrackSheet();
      return true;
    }
    if (key == LogicalKeyboardKey.keyA) {
      _openAudioTrackSheet();
      return true;
    }
    if (key == LogicalKeyboardKey.keyM) {
      _toggleMute();
      return true;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return true;
    }
    if (key == LogicalKeyboardKey.home || key == LogicalKeyboardKey.digit0) {
      _restart();
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_isFullscreen) {
        _toggleFullscreen();
        return true;
      }
    } else if (key == LogicalKeyboardKey.goBack) {
      if (_controlsVisible) {
        setState(() => _controlsVisible = false);
        return true;
      }
      if (_isFullscreen) {
        _toggleFullscreen();
        return true;
      }
      _handleBack();
      return true;
    }

    return false;
  }

  Future<void> _handleBack({bool forceExit = false}) async {
    final isTv = ref.read(isTvModeProvider);
    if (isTv && _tvFocusZone == TvPlayerFocusZone.controls) {
      setState(() => _tvFocusZone = TvPlayerFocusZone.timeline);
      return;
    }
    if (isTv && _controlsVisible) {
      setState(() => _controlsVisible = false);
      return;
    }
    if (!isTv && !forceExit && _isFullscreen) {
      await _toggleFullscreen();
      return;
    }
    _cancelAutoHideTimer();
    _hudTimer?.cancel();
    // Save the live position BEFORE stopping the controller: stop() resets the
    // player to 0, and that sample must never be persisted as "watched". The
    // reporter is sealed right after, so no post-stop sample can overwrite the
    // real position (observed on device: back press wrote 0.0).
    _progress?.flush();
    _progress?.dispose();
    await _controller.stop();
    if (mounted) {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      } else {
        try {
          if (context.canPop()) {
            context.pop();
          } else {
            context.go(AppRoutes.home);
          }
        } catch (_) {}
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android can kill a backgrounded app with no further callback: persist the
    // position now, the way the web player does on `pagehide`.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _progress?.flush();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _progress?.dispose();
    unawaited(_brightnessService.restore());
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    if (_isFullscreen) {
      defaultExitNativeFullscreen();
    }
    _autoHideTimer?.cancel();
    _hudTimer?.cancel();
    _doubleTapSeekTimer?.cancel();
    _previewCancelToken?.cancel();
    _subtitlesCancelToken?.cancel();
    _metaCancelToken?.cancel();
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

  Widget _buildPlayerStack({
    required bool isOpening,
    required bool hasError,
    required bool hasSubtitles,
  }) {
    final castState = ref.watch(castControllerProvider);
    final isTv = ref.watch(isTvModeProvider);
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

        // 2. Loading indicator
        if (isOpening || _isBuffering)
          // Never let the loading/buffering overlay eat the swipe gestures.
          IgnorePointer(
            child: PlayerLoadingIndicator(
              title: isOpening ? 'Loading Media' : 'Buffering Stream',
              message: isOpening
                  ? 'Initializing player & stream...'
                  : 'Filling playback buffer...',
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
            // While a TV owns playback the controls _are_ the TV's: the bar shows the
            // cast's position/duration and the button its play state, so the phone reads
            // as a remote instead of echoing a deliberately paused local player.
            isPlaying: castState.isCasting
                ? castState.playbackState == 'playing'
                : _state == PlayerPlaybackState.playing,
            isBuffering: castState.isCasting
                ? castState.playbackState == 'buffering'
                : _isBuffering,
            position: _transportPosition,
            duration: _transportDuration,
            volume: _volume,
            isFullscreen: isTv || _isFullscreen,
            onTogglePlay: _togglePlayPause,
            onVolumeChanged: _onVolumeChanged,
            onToggleMute: _toggleMute,
            onToggleFullscreen: isTv ? null : () => _toggleFullscreen(),
            onBack: () => _handleBack(forceExit: isTv),
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
            onOpenCastSheet: isTv || _resolveFilename() == null ? null : _openCastSheet,
            isCasting: castState.isCasting,
            isTv: isTv,
            isTimelineFocused: isTv && _tvFocusZone == TvPlayerFocusZone.timeline,
            tvFocusedControlIndex: (isTv && _tvFocusZone == TvPlayerFocusZone.controls)
                ? _tvFocusedControlIndex
                : -1,
          ),

          // Action-feedback HUD (brightness/volume/speed changes). It lives here,
          // outside PlayerControlsOverlay, because that overlay fades to opacity 0
          // when the controls auto-hide - which used to hide the readout of a swipe
          // that had already changed the value. PlayerHudToast wraps itself in
          // IgnorePointer, so it never blocks the surface gestures.
          Positioned.fill(
            child: Align(
              alignment: const Alignment(0.0, -0.35),
              child: PlayerHudToast(
                message: _hudMessage,
                icon: _hudIcon,
                isVisible: _isHudVisible,
              ),
            ),
          ),
          // Cast bar: under the header so it never fights the timeline, and like
          // the HUD it stays put when the controls auto-hide.
          if (castState.isCasting)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.only(top: 68),
                  child: Center(child: _buildCastBar(castState)),
                ),
              ),
            ),
      ],
    );
  }

  void _showServerUrlBottomSheet(String currentOrigin) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (ctx) {
        final textCtrl = TextEditingController(text: currentOrigin);
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.dns_rounded, color: AppColors.brandRedLight, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Server Connection',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: AppColors.textMuted, size: 20),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: textCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  labelText: 'Active Server URL',
                  labelStyle: const TextStyle(color: AppColors.textSecondary),
                  prefixIcon: const Icon(Icons.link, color: AppColors.textMuted, size: 18),
                  filled: true,
                  fillColor: AppColors.surfaceElevated,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.borderSubtle),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Quick Presets:',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _buildPresetChip('LAN (192.168.1.16)', 'http://192.168.1.16:8000', textCtrl),
                  _buildPresetChip('WAN (Cloudflare)', 'https://media.anisparvez.in', textCtrl),
                  _buildPresetChip('Localhost', 'http://127.0.0.1:8000', textCtrl),
                ],
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () async {
                  final newUrl = textCtrl.text.trim();
                  if (newUrl.isNotEmpty) {
                    await SettingsService().setServerBaseUrl(newUrl);
                    if (mounted) {
                      _showHudToast('Server Saved: $newUrl', icon: Icons.check_circle_rounded);
                    }
                  }
                  if (ctx.mounted) Navigator.of(ctx).pop();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brandRed,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.save_rounded, size: 18),
                label: const Text('Save Active Server'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPresetChip(String label, String url, TextEditingController ctrl) {
    return ActionChip(
      backgroundColor: AppColors.surfaceElevated,
      side: const BorderSide(color: AppColors.borderSubtle),
      label: Text(label, style: const TextStyle(color: AppColors.textPrimary, fontSize: 12)),
      onPressed: () {
        ctrl.text = url;
      },
    );
  }

  Widget _buildBrandHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(
          bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF2E080E), Color(0xFF141822)],
              ),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: AppColors.brandRed.withValues(alpha: 0.5)),
            ),
            child: const Center(
              child: Icon(
                Icons.play_arrow_rounded,
                color: AppColors.brandRed,
                size: 17,
              ),
            ),
          ),
          const SizedBox(width: 8),
          RichText(
            text: const TextSpan(
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: -0.3,
              ),
              children: [
                TextSpan(text: "Anis' "),
                TextSpan(
                  text: "Home Media Server",
                  style: TextStyle(color: AppColors.brandRedLight),
                ),
              ],
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: const Text(
              'PLAY • ORGANIZE • ENJOY',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 8.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.7,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaDetailsSection() {
    final serverOrigin = _apiServerOrigin() ?? 'http://127.0.0.1:8000';
    final filename = _resolveFilename() ?? 'Media Stream';

    final displayTitle = _movieMeta?['title'] as String? ?? widget.title;
    final year = _movieMeta?['year'];
    final genres = _movieMeta?['genres'] as String?;
    final rating = _movieMeta?['rating'];
    final overview = _movieMeta?['overview'] as String?;

    return Container(
      color: AppColors.background,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            RichText(
              text: TextSpan(
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.2,
                ),
                children: [
                  TextSpan(text: displayTitle),
                ],
              ),
            ),
            const SizedBox(height: 6),

            // Metadata Badges & Server URL Chip
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // Server URL Chip (Interactive)
                InkWell(
                  onTap: () => _showServerUrlBottomSheet(serverOrigin),
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.brandRed.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: AppColors.statusSuccess,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          serverOrigin,
                          style: const TextStyle(
                            color: AppColors.brandRedLight,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.edit_outlined, size: 12, color: AppColors.textMuted),
                      ],
                    ),
                  ),
                ),

                // Quality Badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.borderSubtle),
                  ),
                  child: Text(
                    _playbackMode.badgeLabel,
                    style: const TextStyle(
                      color: AppColors.statusSuccess,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),

                // Year Badge
                if (year != null && year.toString().isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppColors.borderSubtle),
                    ),
                    child: Text(
                      year.toString(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),

                // Rating Badge
                if (rating != null && rating > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0x33FFB800),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0x66FFB800)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.star_rounded, color: Color(0xFFFFB800), size: 12),
                        const SizedBox(width: 3),
                        Text(
                          rating.toStringAsFixed(1),
                          style: const TextStyle(
                            color: Color(0xFFFFD54F),
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),

                // Genres Badge
                if (genres != null && genres.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppColors.borderSubtle),
                    ),
                    child: Text(
                      genres,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),

                // Subtitle details badge
                if (widget.subtitle != null && widget.subtitle!.isNotEmpty)
                  RichText(
                    text: TextSpan(
                      text: widget.subtitle!,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),

            // Synopsis Card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.info_outline_rounded, color: AppColors.brandRedLight, size: 16),
                      SizedBox(width: 6),
                      Text(
                        'Synopsis',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    (overview != null && overview.trim().isNotEmpty)
                        ? overview.trim()
                        : 'No synopsis available for this title in the local library.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.82),
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Technical Stream Specs Card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.analytics_outlined, color: AppColors.brandRedLight, size: 16),
                      SizedBox(width: 6),
                      Text(
                        'Stream Specifications',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _buildSpecRow('Source File', filename),
                  const SizedBox(height: 6),
                  _buildSpecRow('Playback Type', _playbackMode.specLabel),
                  const SizedBox(height: 6),
                  _buildSpecRow('Server Origin', serverOrigin),
                  const SizedBox(height: 6),
                  _buildSpecRow(
                    'Position',
                    '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Return to Library Button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _handleBack,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.borderMedium),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.arrow_back_rounded, size: 18, color: Colors.white),
                label: const Text('Back to Connection / Library', style: TextStyle(color: Colors.white)),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildSpecRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 105,
          child: RichText(
            text: TextSpan(
              text: label,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ),
        ),
        Expanded(
          child: RichText(
            text: TextSpan(
              text: value,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
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
        await _handleBack(forceExit: isTv);
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
                        _buildBrandHeader(),
                        const SizedBox(height: 8),
                        AspectRatio(
                          aspectRatio: 16 / 10.5,
                          child: Container(
                            color: Colors.black,
                            child: playerStack,
                          ),
                        ),
                        Expanded(
                          child: _buildMediaDetailsSection(),
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
