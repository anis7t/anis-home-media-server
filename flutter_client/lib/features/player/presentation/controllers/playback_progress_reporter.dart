import 'dart:async';

/// Persists playback position to the media server.
///
/// The web player has always saved progress (`POST /api/progress` in
/// `templates/player.html`) — on pause, every 10 s of playback, on `pagehide`
/// and when playback ends. The app never did: it *read* the resume point (via
/// `/api/media-info`) but never *wrote* it, so the position only ever moved
/// when a browser played the file.
///
/// This mirrors the web player's cadence: autosave on a playback delta, save
/// on pause, on seek (debounced so scrubbing writes once), when playback ends
/// (position 0 = watched) and on teardown/backgrounding.
class PlaybackProgressReporter {
  PlaybackProgressReporter({
    required this.save,
    this.saveEvery = const Duration(seconds: 10),
    this.seekDebounce = const Duration(seconds: 2),
    this.minimumPosition = const Duration(seconds: 1),
  });

  /// Uploads one sample. Fire-and-forget: must never throw, and a failed save
  /// must never disturb playback.
  final Future<void> Function(Duration position, Duration duration) save;

  /// Playback delta that triggers an autosave (the web player uses 10 s).
  final Duration saveEvery;

  /// How long a seek must settle before it is persisted (scrubbing emits many).
  final Duration seekDebounce;

  /// Positions below this count as "not started" and are never persisted, so a
  /// viewer who only previews a title does not leave a resume point behind.
  final Duration minimumPosition;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  /// First sample of this session. Opening a title at its saved resume point is
  /// not itself progress, so the autosave delta is measured from here until the
  /// first real write.
  Duration? _baseline;

  /// Position of the last *write*, null until one happens — so `flush()` can
  /// always persist a session that never crossed the autosave delta.
  Duration? _lastSaved;
  Timer? _seekTimer;
  bool _disposed = false;
  bool _ended = false;

  /// Latest position handed to the reporter (kept even while scrubbing).
  Duration get position => _position;

  /// Called for every position sample from the player's position stream.
  void onPosition(Duration position, Duration duration) {
    _position = position;
    if (duration > Duration.zero) _duration = duration;
    if (_disposed || _ended) return;

    final baseline = _baseline ??= position;
    if ((position - (_lastSaved ?? baseline)).abs() >= saveEvery) {
      _lastSaved = position;
      _emit(position);
    }
  }

  /// Called after the user seeks (scrub commit, skip, double-tap).
  void onSeek(Duration position) {
    _position = position;
    if (_disposed || _ended) return;
    _seekTimer?.cancel();
    _seekTimer = Timer(seekDebounce, () {
      _seekTimer = null;
      if (_disposed || _ended) return;
      if (position < minimumPosition) return;
      final last = _lastSaved;
      if (last != null && (last - position).abs() < const Duration(seconds: 1)) {
        return; // the position stream already persisted this target
      }
      _lastSaved = position;
      _emit(position);
    });
  }

  /// Playback paused: persist immediately, like the web player's `onpause`.
  void onPause() => flush();

  /// Playback reached the end: 0 means watched, and the server's resume filter
  /// ignores it (`position > 10`).
  ///
  /// media_kit reports `completed` for a torn-down stream or an exhausted byte
  /// range as well as for a real end — observed on device: leaving the player
  /// mid-file wrote 0 and wiped the resume point. So completion only counts as
  /// watched when the position really is at the end of the media.
  void onEnded() {
    if (_disposed) return;
    final duration = _duration;
    final atEnd = duration > Duration.zero &&
        _position >= duration - const Duration(seconds: 10);
    if (!atEnd) {
      flush(); // persist the real position instead of marking it watched
      return;
    }
    _ended = true;
    _seekTimer?.cancel();
    _seekTimer = null;
    _lastSaved = Duration.zero;
    _emit(Duration.zero);
  }

  /// Writes the current position now — leaving the player, app backgrounded,
  /// or any other point where Android may never call back again.
  void flush() {
    if (_disposed || _ended) return;
    _seekTimer?.cancel();
    _seekTimer = null;

    final position = _position;
    if (position < minimumPosition) return;
    final last = _lastSaved;
    if (last != null && (last - position).abs() < const Duration(seconds: 1)) {
      return; // already persisted this spot
    }
    _lastSaved = position;
    _emit(position);
  }

  /// Cancels pending work and refuses further writes.
  ///
  /// Deliberately does **not** flush: a save started here would post while the
  /// widget is already being torn down, and Dio's request-scheduling timer then
  /// outlives the widget test that owns it ("A Timer is still pending even after
  /// the widget tree was disposed"). The exit save belongs to the player's back
  /// path (`_handleBack`), and backgrounding is covered by the lifecycle hook.
  void dispose() {
    _disposed = true;
    _seekTimer?.cancel();
    _seekTimer = null;
  }

  void _emit(Duration position) {
    final duration = _duration;
    unawaited(Future.sync(() => save(position, duration)).catchError((_) {}));
  }
}
