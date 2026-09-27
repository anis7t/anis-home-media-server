/// Authoritative playback mode for the stream the player is about to open.
///
/// The mode is resolved exclusively from the server's own
/// `/api/media-info/<filename>` response (`direct_play`). It must never be
/// inferred from the URL shape, the filename, the container/codec name, a
/// display subtitle or any other string heuristic.
enum PlaybackMode {
  /// Server advertises the file as directly playable (`direct_play == true`):
  /// the player streams it over `/media/<filename>` with RFC 7233 byte ranges.
  directPlay,

  /// Server advertises the file as requiring the HLS pipeline
  /// (`direct_play == false`): the player opens
  /// `/hls/<filename>/playlist.m3u8`.
  hls,

  /// The authoritative value has not been received - the probe failed, or no
  /// server contract applies (injected test/POC controller). The UI must not
  /// claim either mode in this state.
  unknown;

  /// Maps the server's `direct_play` flag onto the enum.
  ///
  /// Anything that is not a bool (missing field, failed request, `null`) means
  /// "not received" and stays [unknown] rather than defaulting to a guess.
  static PlaybackMode fromDirectPlay(Object? directPlay) {
    if (directPlay is! bool) return PlaybackMode.unknown;
    return directPlay ? PlaybackMode.directPlay : PlaybackMode.hls;
  }

  /// Short badge label for the player's quality chip.
  String get badgeLabel => switch (this) {
        PlaybackMode.directPlay => 'DIRECT PLAY',
        PlaybackMode.hls => 'HLS STREAM',
        PlaybackMode.unknown => 'STREAM',
      };

  /// Longer description for the stream-specification table.
  String get specLabel => switch (this) {
        PlaybackMode.directPlay => 'Direct Stream (RFC 7233)',
        PlaybackMode.hls => 'HLS Segmented',
        PlaybackMode.unknown => 'Unknown (server mode unavailable)',
      };
}
