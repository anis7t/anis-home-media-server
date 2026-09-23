import 'dart:async';

/// Playback state of the player engine.
enum PlayerPlaybackState {
  idle,
  opening,
  playing,
  paused,
  completed,
  error,
}

/// Generic subtitle track model.
class PlayerSubtitleTrack {
  final String id;
  final String title;
  final String? language;
  final bool isExternal;

  const PlayerSubtitleTrack({
    required this.id,
    required this.title,
    this.language,
    this.isExternal = false,
  });

  static const auto = PlayerSubtitleTrack(id: 'auto', title: 'Auto');
  static const no = PlayerSubtitleTrack(id: 'no', title: 'Off');
}

/// Generic track container.
class PlayerTrackInfo {
  final List<PlayerSubtitleTrack> subtitleTracks;
  final PlayerSubtitleTrack currentSubtitleTrack;

  const PlayerTrackInfo({
    this.subtitleTracks = const [],
    this.currentSubtitleTrack = PlayerSubtitleTrack.no,
  });
}

/// Generic video resolution information.
class VideoDimensions {
  final int width;
  final int height;

  const VideoDimensions(this.width, this.height);

  static const zero = VideoDimensions(0, 0);
}

/// Abstract contract decoupling the presentation/test harness from candidate player engines.
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

  /// Current volume (0.0 to 100.0 or 0.0 to 1.0).
  double get volume;

  /// Opens a media resource.
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Duration? startPosition,
    String? externalSubtitleUrl,
  });

  /// Plays playback.
  Future<void> play();

  /// Pauses playback.
  Future<void> pause();

  /// Seeks to [position].
  Future<void> seek(Duration position);

  /// Sets playback rate.
  Future<void> setRate(double rate);

  /// Sets volume.
  Future<void> setVolume(double volume);

  /// Sets subtitle track.
  Future<void> setSubtitleTrack(PlayerSubtitleTrack track);

  /// Stops playback.
  Future<void> stop();

  /// Disposes resources.
  Future<void> dispose();
}
