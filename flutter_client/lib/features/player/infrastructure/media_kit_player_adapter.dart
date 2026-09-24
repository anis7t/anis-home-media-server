import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../domain/player_controller_interface.dart';

/// Concrete adapter wrapping [Player] and [VideoController] behind [PlayerControllerInterface].
class MediaKitPlayerAdapter implements PlayerControllerInterface {
  final Player player;
  VideoController? _videoController;

  VideoController get videoController =>
      _videoController ??= VideoController(player);

  final _stateController = StreamController<PlayerPlaybackState>.broadcast();
  final _dimensionsController = StreamController<VideoDimensions>.broadcast();
  final _tracksController = StreamController<PlayerTrackInfo>.broadcast();

  final List<StreamSubscription> _subscriptions = [];

  PlayerPlaybackState _state = PlayerPlaybackState.idle;
  VideoDimensions _dimensions = VideoDimensions.zero;
  PlayerTrackInfo _trackInfo = const PlayerTrackInfo();

  MediaKitPlayerAdapter({Player? player, VideoController? videoController})
      : player = player ?? Player() {
    _videoController = videoController;
    _initStreams();
  }

  void _initStreams() {
    _subscriptions.add(player.stream.playing.listen((isPlaying) {
      if (player.state.buffering) {
        // preserve buffering state
      } else if (isPlaying) {
        _updateState(PlayerPlaybackState.playing);
      } else {
        _updateState(PlayerPlaybackState.paused);
      }
    }));

    _subscriptions.add(player.stream.buffering.listen((isBuffering) {
      if (isBuffering) {
        // buffering does not necessarily change playback state to idle
      } else if (player.state.playing) {
        _updateState(PlayerPlaybackState.playing);
      } else {
        _updateState(PlayerPlaybackState.paused);
      }
    }));

    _subscriptions.add(player.stream.completed.listen((isCompleted) {
      if (isCompleted) {
        _updateState(PlayerPlaybackState.completed);
      }
    }));

    _subscriptions.add(player.stream.error.listen((errorMsg) {
      debugPrint('[MediaKitPlayerAdapter] Engine Error: $errorMsg');
      _updateState(PlayerPlaybackState.error);
    }));

    _subscriptions.add(player.stream.width.listen((_) => _updateDimensions()));
    _subscriptions.add(player.stream.height.listen((_) => _updateDimensions()));

    _subscriptions.add(player.stream.tracks.listen((_) => _updateTracks()));
    _subscriptions.add(player.stream.track.listen((_) => _updateTracks()));
  }

  void _updateState(PlayerPlaybackState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(_state);
    }
  }

  void _updateDimensions() {
    final w = player.state.width ?? 0;
    final h = player.state.height ?? 0;
    _dimensions = VideoDimensions(w, h);
    _dimensionsController.add(_dimensions);
  }

  void _updateTracks() {
    final nativeSubs = player.state.tracks.subtitle;
    final activeSub = player.state.track.subtitle;

    final subTracks = <PlayerSubtitleTrack>[
      PlayerSubtitleTrack.no,
      PlayerSubtitleTrack.auto,
    ];

    for (final s in nativeSubs) {
      if (s.id == 'no' || s.id == 'auto') continue;
      subTracks.add(PlayerSubtitleTrack(
        id: s.id,
        title: s.title ?? s.language ?? 'Track ${s.id}',
        language: s.language,
        isExternal: s.uri,
      ));
    }

    final currentSub = PlayerSubtitleTrack(
      id: activeSub.id,
      title: activeSub.title ?? activeSub.language ?? activeSub.id,
      language: activeSub.language,
      isExternal: activeSub.uri,
    );

    final nativeAudios = player.state.tracks.audio;
    final activeAudio = player.state.track.audio;

    final audioTracks = <PlayerAudioTrack>[
      PlayerAudioTrack.auto,
      PlayerAudioTrack.no,
    ];

    for (final a in nativeAudios) {
      if (a.id == 'no' || a.id == 'auto') continue;
      audioTracks.add(PlayerAudioTrack(
        id: a.id,
        title: a.title ?? a.language ?? 'Audio ${a.id}',
        language: a.language,
        channels: a.channels,
      ));
    }

    final currentAudio = PlayerAudioTrack(
      id: activeAudio.id,
      title: activeAudio.title ?? activeAudio.language ?? activeAudio.id,
      language: activeAudio.language,
      channels: activeAudio.channels,
    );

    _trackInfo = PlayerTrackInfo(
      subtitleTracks: subTracks,
      currentSubtitleTrack: currentSub,
      audioTracks: audioTracks,
      currentAudioTrack: currentAudio,
    );
    _tracksController.add(_trackInfo);
  }

  @override
  Stream<Duration> get positionStream => player.stream.position;

  @override
  Stream<Duration> get durationStream => player.stream.duration;

  @override
  Stream<PlayerPlaybackState> get stateStream => _stateController.stream;

  @override
  Stream<bool> get bufferingStream => player.stream.buffering;

  @override
  Stream<PlayerTrackInfo> get tracksStream => _tracksController.stream;

  @override
  Stream<VideoDimensions> get dimensionsStream => _dimensionsController.stream;

  @override
  Duration get position => player.state.position;

  @override
  Duration get duration => player.state.duration;

  @override
  PlayerPlaybackState get state => _state;

  @override
  bool get isBuffering => player.state.buffering;

  @override
  double get rate => player.state.rate;

  @override
  double get volume => player.state.volume;

  @override
  VideoDimensions get dimensions => _dimensions;

  @override
  PlayerTrackInfo get trackInfo => _trackInfo;

  @override
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Duration? startPosition,
    String? externalSubtitleUrl,
  }) async {
    _updateState(PlayerPlaybackState.opening);
    final media = Media(
      url,
      httpHeaders: headers,
      start: (startPosition != null && startPosition > Duration.zero)
          ? startPosition
          : null,
    );

    await player.open(media, play: false);

    if (externalSubtitleUrl != null && externalSubtitleUrl.isNotEmpty) {
      try {
        await player.setSubtitleTrack(
          SubtitleTrack.uri(externalSubtitleUrl, title: 'External Subtitle'),
        );
      } catch (e) {
        debugPrint('[MediaKitPlayerAdapter] Failed to set external subtitle: $e');
      }
    }

    await player.play();
  }

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> setRate(double rate) => player.setRate(rate);

  @override
  Future<void> setVolume(double volume) => player.setVolume(volume);

  @override
  Future<void> setSubtitleTrack(PlayerSubtitleTrack track) async {
    if (track.id == 'no') {
      await player.setSubtitleTrack(SubtitleTrack.no());
    } else if (track.id == 'auto') {
      await player.setSubtitleTrack(SubtitleTrack.auto());
    } else if (track.isExternal) {
      await player.setSubtitleTrack(SubtitleTrack.uri(track.id, title: track.title));
    } else {
      final nativeSub = player.state.tracks.subtitle.firstWhere(
        (s) => s.id == track.id,
        orElse: () => SubtitleTrack.auto(),
      );
      await player.setSubtitleTrack(nativeSub);
    }
    _updateTracks();
  }

  @override
  Future<void> setAudioTrack(PlayerAudioTrack track) async {
    if (track.id == 'no') {
      await player.setAudioTrack(AudioTrack.no());
    } else if (track.id == 'auto') {
      await player.setAudioTrack(AudioTrack.auto());
    } else {
      final nativeAudio = player.state.tracks.audio.firstWhere(
        (a) => a.id == track.id,
        orElse: () => AudioTrack.auto(),
      );
      await player.setAudioTrack(nativeAudio);
    }
    _updateTracks();
  }

  @override
  Future<void> stop() async {
    await player.stop();
    _updateState(PlayerPlaybackState.idle);
  }

  @override
  Future<void> dispose() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    await _stateController.close();
    await _dimensionsController.close();
    await _tracksController.close();
    await player.dispose();
  }
}
