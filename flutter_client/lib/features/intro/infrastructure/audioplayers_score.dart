import 'package:audioplayers/audioplayers.dart';

import '../domain/intro_score.dart';

/// The score, over `audioplayers`.
///
/// `audioplayers` is a pure-Dart wrapper over Android's `MediaPlayer`. It was
/// chosen over the alternatives for three reasons, and the choice is recorded
/// as **D17**:
///
///  * `just_audio` is built for streaming and long-form playback, and drags in
///    ExoPlayer's machinery for a three-second local asset.
///  * `soundpool` is for rapid-fire game sound effects.
///  * `media_kit` is already a dependency, but it is a **video** engine - and
///    its host backend is libmpv, which is the very thing that stops three of
///    the host's test files from running at all (Issue 11).
///
/// **Nothing here is allowed to throw.** A device with no audio, a platform
/// channel that is not registered, a player that fails to prepare - all of them
/// mean the same thing: the sequence plays, silently.
class AudioplayersIntroScore implements IntroScore {
  AudioplayersIntroScore({AudioPlayer? player})
      : _player = player ?? AudioPlayer();

  /// The asset's path, relative to the pubspec's `assets` root.
  static const String assetPath = 'audio/intro-theme.wav';

  final AudioPlayer _player;
  Future<void>? _preparing;

  @override
  Future<void> prepare() => _preparing ??= _prepare();

  Future<void> _prepare() async {
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setSource(AssetSource(assetPath));
    } catch (_) {
      // No audio on this device, or the platform channel is not there. The
      // sequence carries on without a score.
    }
  }

  @override
  Future<void> get ready => prepare();

  @override
  Future<void> playFrom(Duration elapsed) async {
    await ready;
    try {
      // The score is anchored to the sequence: if the platform needed longer
      // to prepare than the sequence had been running, the score starts from
      // where the picture is, not from the top.
      if (elapsed > Duration.zero) {
        await _player.seek(elapsed);
      }
      await _player.resume();
    } catch (_) {
      // The player refused. The sequence does not care.
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {
      // Already stopped, or never started.
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _player.dispose();
    } catch (_) {
      // Already gone.
    }
  }
}
