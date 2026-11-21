export 'quality_option.dart';

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

/// Hardware/software decoding acceleration mode for media engine.
enum DecoderMode {
  /// Direct zero-copy Surface decoding (`mediacodec` on Android).
  ///
  /// Bypasses the CPU memory bus completely. Recommended for 4K / UHD playback,
  /// low-power devices, and streaming sticks (e.g. Fire TV Stick 4K).
  hardwareDirect,

  /// Hardware decoding with frame copy to CPU/RAM (`mediacodec-copy` on Android).
  ///
  /// Compatible with devices having non-standard Surface implementations,
  /// but consumes high memory bandwidth on 4K content.
  hardwareCopy,

  /// Software CPU decoding via libavcodec (`no`).
  ///
  /// Decodes entirely on CPU cores. Safe fallback for broken hardware decoders,
  /// but causes frame drops on 4K on low-power CPUs.
  software,

  /// Automatically select optimal hardware decoding mode for the platform.
  auto,
}

extension DecoderModeX on DecoderMode {
  String get label {
    switch (this) {
      case DecoderMode.hardwareDirect:
        return 'Hardware (Direct - Zero-Copy)';
      case DecoderMode.hardwareCopy:
        return 'Hardware (Compatible - Copy)';
      case DecoderMode.software:
        return 'Software (CPU)';
      case DecoderMode.auto:
        return 'Auto (Recommended)';
    }
  }

  String get badge {
    switch (this) {
      case DecoderMode.hardwareDirect:
        return 'HW-DIRECT';
      case DecoderMode.hardwareCopy:
        return 'HW-COPY';
      case DecoderMode.software:
        return 'SW-CPU';
      case DecoderMode.auto:
        return 'AUTO';
    }
  }

  String get description {
    switch (this) {
      case DecoderMode.hardwareDirect:
        return 'Direct Surface zero-copy. Recommended for 4K and Fire TV Stick.';
      case DecoderMode.hardwareCopy:
        return 'Hardware decode copied to RAM. Compatible, higher memory usage.';
      case DecoderMode.software:
        return 'Decodes via CPU cores. Safe fallback for broken hardware decoders.';
      case DecoderMode.auto:
        return 'Automatically selects direct hardware acceleration.';
    }
  }

  String toMpvHwdec() {
    switch (this) {
      case DecoderMode.hardwareDirect:
        return 'mediacodec';
      case DecoderMode.hardwareCopy:
        return 'mediacodec-copy';
      case DecoderMode.software:
        return 'no';
      case DecoderMode.auto:
        return 'mediacodec';
    }
  }
}
