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
  final bool isDefault;

  const PlayerSubtitleTrack({
    required this.id,
    required this.title,
    this.language,
    this.isExternal = false,
    this.isDefault = false,
  });

  static const auto = PlayerSubtitleTrack(id: 'auto', title: 'Auto');
  static const no = PlayerSubtitleTrack(id: 'no', title: 'Off');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlayerSubtitleTrack &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Generic audio track model.
class PlayerAudioTrack {
  final String id;
  final String title;
  final String? language;
  final String? channels;
  final String? codec;

  const PlayerAudioTrack({
    required this.id,
    required this.title,
    this.language,
    this.channels,
    this.codec,
  });

  static const auto = PlayerAudioTrack(id: 'auto', title: 'Auto');
  static const no = PlayerAudioTrack(id: 'no', title: 'Off');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlayerAudioTrack &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Generic track container.
class PlayerTrackInfo {
  final List<PlayerSubtitleTrack> subtitleTracks;
  final PlayerSubtitleTrack currentSubtitleTrack;
  final List<PlayerAudioTrack> audioTracks;
  final PlayerAudioTrack currentAudioTrack;

  const PlayerTrackInfo({
    this.subtitleTracks = const [],
    this.currentSubtitleTrack = PlayerSubtitleTrack.no,
    this.audioTracks = const [],
    this.currentAudioTrack = PlayerAudioTrack.auto,
  });

  PlayerTrackInfo copyWith({
    List<PlayerSubtitleTrack>? subtitleTracks,
    PlayerSubtitleTrack? currentSubtitleTrack,
    List<PlayerAudioTrack>? audioTracks,
    PlayerAudioTrack? currentAudioTrack,
  }) {
    return PlayerTrackInfo(
      subtitleTracks: subtitleTracks ?? this.subtitleTracks,
      currentSubtitleTrack: currentSubtitleTrack ?? this.currentSubtitleTrack,
      audioTracks: audioTracks ?? this.audioTracks,
      currentAudioTrack: currentAudioTrack ?? this.currentAudioTrack,
    );
  }
}

/// Generic video resolution information.
class VideoDimensions {
  final int width;
  final int height;

  const VideoDimensions(this.width, this.height);

  static const zero = VideoDimensions(0, 0);

  double get aspectRatio => (width > 0 && height > 0) ? width / height : 16 / 9;
}

/// User-presentable player error.
class PlayerError {
  final String message;
  final String? code;
  final dynamic originalError;

  const PlayerError({
    required this.message,
    this.code,
    this.originalError,
  });

  @override
  String toString() => 'PlayerError($message, code: $code)';
}
