import 'dart:async';
import 'player_models.dart';

export 'player_models.dart';

/// Abstract contract decoupling presentation widgets from candidate player engines.
abstract class PlayerControllerInterface {
  /// Stream of current playback position.
  Stream<Duration> get positionStream;

  /// Stream of total media duration.
  Stream<Duration> get durationStream;

  /// Stream of player lifecycle states.
  Stream<PlayerPlaybackState> get stateStream;

  /// Stream of buffering status.
  Stream<bool> get bufferingStream;

  /// Stream of track changes (subtitles, audio).
  Stream<PlayerTrackInfo> get tracksStream;

  /// Stream of video dimensions.
  Stream<VideoDimensions> get dimensionsStream;

  /// Current position.
  Duration get position;

  /// Total duration.
  Duration get duration;

  /// Current playback state.
  PlayerPlaybackState get state;

  /// Whether player is currently buffering.
  bool get isBuffering;

  /// Current playback rate.
  double get rate;

  /// Current volume (0.0 to 100.0).
  double get volume;

  /// Current video dimensions.
  VideoDimensions get dimensions;

  /// Current track information.
  PlayerTrackInfo get trackInfo;

  /// Opens a media resource.
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Duration? startPosition,
    String? externalSubtitleUrl,
  });

  /// Starts or resumes playback.
  Future<void> play();

  /// Pauses playback.
  Future<void> pause();

  /// Seeks to [position].
  Future<void> seek(Duration position);

  /// Sets playback rate.
  Future<void> setRate(double rate);

  /// Sets volume (0.0 to 100.0).
  Future<void> setVolume(double volume);

  /// Sets subtitle track.
  Future<void> setSubtitleTrack(PlayerSubtitleTrack track);

  /// Sets audio track.
  Future<void> setAudioTrack(PlayerAudioTrack track);

  /// Stops playback.
  Future<void> stop();

  /// Disposes resources.
  Future<void> dispose();
}
