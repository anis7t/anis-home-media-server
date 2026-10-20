import '../../domain/intro_score.dart';

/// The score's lifecycle, alongside the sequence.
///
/// This is the Flutter client's version of the web's audio contract
/// (`docs/OPENING_SEQUENCE.md` Part I section 7), and the two rules that
/// matter are the same ones:
///
///  * **The animation never waits for the audio.** The score is prepared in
///    the background, and the sequence runs regardless. `start()` is not
///    awaited by anything that draws.
///  * **The score is anchored, not orphaned.** It starts at the point the
///    sequence has reached *when it actually starts* - so a platform that
///    needed eighty milliseconds to prepare does not put the score behind the
///    picture - and it is **dropped** if the sequence is over by then, because
///    a sound out of nowhere is worse than no sound.
///
/// The one thing the two do **not** share is the unlocking gesture: the web's
/// score waits for a user gesture, because a browser will not play audio
/// without one. Android has no such policy, so the Flutter client's score
/// starts on its own. That is a divergence, and it is recorded as **L18**.
class IntroScoreController {
  IntroScoreController({
    required this.score,
    required this.elapsedAt,
    required this.duration,
  });

  /// The score itself.
  final IntroScore score;

  /// How far the sequence has played. It is asked **again**, when the score
  /// is actually ready, so that the anchor is the picture's position at that
  /// moment and not at the moment the sequence started.
  final Duration Function() elapsedAt;

  /// The sequence's length. A score that would start after it is dropped.
  final Duration duration;

  /// The sequence has started.
  ///
  /// Nothing awaits this: the sequence is already running, and the score
  /// catches up when it can.
  Future<void> start() async {
    await score.ready;
    final elapsed = elapsedAt();
    if (elapsed >= duration) {
      // The sequence is over. The score is dropped rather than orphaned.
      return;
    }
    await score.playFrom(elapsed);
  }

  /// The sequence has finished, or been dismissed.
  Future<void> stop() => score.stop();
}
