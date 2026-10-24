/// The brand opening sequence's score.
///
/// The web **synthesises** its own score (decision D8): the original's Web
/// Audio, ported. The phone and the TV **play** the canonical's offline
/// render instead, because Flutter has no Web Audio and the composition has to
/// be the same music either way.
///
/// This is the contract the sequence speaks to the score with. It is
/// deliberately narrow, and it is an interface so that the host tests can
/// substitute a fake - the Flutter suite must never touch a real audio
/// platform, and the client has no business knowing which player is behind
/// it.
library;

/// The score's contract.
abstract class IntroScore {
  /// Prepare the score so it can start at a moment's notice.
  ///
  /// Called as early as possible. The platform's own preparation takes tens
  /// of milliseconds, and the score is anchored to the sequence when it
  /// actually starts - so the sooner it is ready, the smaller the anchor.
  ///
  /// Preparing is **never** allowed to fail loudly: a device with no audio
  /// gets a sequence with no score, not a crash.
  Future<void> prepare();

  /// Completes when the score is ready to play.
  Future<void> get ready;

  /// Start the score, at [elapsed] into the sequence.
  ///
  /// [elapsed] is the point to start from, so a score that had to wait for
  /// the platform still lands in step with the picture.
  Future<void> playFrom(Duration elapsed);

  /// Stop the score.
  Future<void> stop();

  /// Release the player.
  Future<void> dispose();
}

/// A score that makes no sound.
///
/// For the host tests, and for any build where the platform has no audio.
class SilentIntroScore implements IntroScore {
  const SilentIntroScore();

  @override
  Future<void> prepare() async {}

  @override
  Future<void> get ready async {}

  @override
  Future<void> playFrom(Duration elapsed) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
