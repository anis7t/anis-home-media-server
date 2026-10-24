import 'dart:async';

import 'package:media_server_client/features/player/domain/player_controller_interface.dart';

/// Minimal [PlayerControllerInterface] test double that records the URL the
/// player was actually opened with.
///
/// Used by the playback-mode regression tests: the authoritative-mode fix has
/// to be provable from *what the controller was handed* as well as from the
/// label the UI renders.
class RecordingPlayerController implements PlayerControllerInterface {
  /// URL passed to [open] - null until the player opens a stream.
  String? openedUrl;
  Map<String, String>? openedHeaders;
  Duration? openedStartPosition;
  String? openedExternalSubtitleUrl;
  int openCount = 0;

  Duration _position = Duration.zero;
  Duration _duration = const Duration(minutes: 90);
  PlayerPlaybackState _state = PlayerPlaybackState.idle;
  final bool _isBuffering = false;
  double _rate = 1.0;
  double _volume = 80.0;
  PlayerTrackInfo _trackInfo = const PlayerTrackInfo();

  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _stateController = StreamController<PlayerPlaybackState>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  final _tracksController = StreamController<PlayerTrackInfo>.broadcast();
  final _dimensionsController = StreamController<VideoDimensions>.broadcast();

  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  PlayerPlaybackState get state => _state;
  @override
  bool get isBuffering => _isBuffering;
  @override
  double get rate => _rate;
  @override
  double get volume => _volume;
  @override
  VideoDimensions get dimensions => const VideoDimensions(1920, 1080);
  @override
  PlayerTrackInfo get trackInfo => _trackInfo;

  @override
  Stream<Duration> get positionStream => _positionController.stream;
  @override
  Stream<Duration> get durationStream => _durationController.stream;
  @override
  Stream<PlayerPlaybackState> get stateStream => _stateController.stream;
  @override
  Stream<bool> get bufferingStream => _bufferingController.stream;
  @override
  Stream<PlayerTrackInfo> get tracksStream => _tracksController.stream;
  @override
  Stream<VideoDimensions> get dimensionsStream => _dimensionsController.stream;

  void emitState(PlayerPlaybackState s) {
    _state = s;
    _stateController.add(s);
  }

  void emitPosition(Duration p) {
    _position = p;
    _positionController.add(p);
  }

  void emitDuration(Duration d) {
    _duration = d;
    _durationController.add(d);
  }

  @override
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Duration? startPosition,
    String? externalSubtitleUrl,
  }) async {
    openCount++;
    openedUrl = url;
    openedHeaders = headers;
    openedStartPosition = startPosition;
    openedExternalSubtitleUrl = externalSubtitleUrl;
    _state = PlayerPlaybackState.opening;
    _stateController.add(_state);
  }

  @override
  Future<void> play() async {
    _state = PlayerPlaybackState.playing;
    _stateController.add(_state);
  }

  @override
  Future<void> pause() async {
    _state = PlayerPlaybackState.paused;
    _stateController.add(_state);
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    _positionController.add(_position);
  }

  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
  }

  @override
  Future<void> setSubtitleTrack(PlayerSubtitleTrack track) async {
    _trackInfo = PlayerTrackInfo(
      subtitleTracks: _trackInfo.subtitleTracks,
      currentSubtitleTrack: track,
      audioTracks: _trackInfo.audioTracks,
      currentAudioTrack: _trackInfo.currentAudioTrack,
    );
    _tracksController.add(_trackInfo);
  }

  @override
  Future<void> setAudioTrack(PlayerAudioTrack track) async {
    _trackInfo = PlayerTrackInfo(
      subtitleTracks: _trackInfo.subtitleTracks,
      currentSubtitleTrack: _trackInfo.currentSubtitleTrack,
      audioTracks: _trackInfo.audioTracks,
      currentAudioTrack: track,
    );
    _tracksController.add(_trackInfo);
  }

  @override
  Future<void> stop() async {
    _state = PlayerPlaybackState.idle;
    _stateController.add(_state);
  }

  @override
  Future<void> dispose() async {
    await _positionController.close();
    await _durationController.close();
    await _stateController.close();
    await _bufferingController.close();
    await _tracksController.close();
    await _dimensionsController.close();
  }
}
