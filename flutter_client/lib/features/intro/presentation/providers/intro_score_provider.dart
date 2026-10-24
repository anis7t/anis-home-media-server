import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/intro_score.dart';
import '../../infrastructure/audioplayers_score.dart';

/// The brand opening sequence's score.
///
/// The application's entry point **prepares** it as early as it can - the
/// platform's own preparation takes tens of milliseconds, and the score is
/// anchored to the sequence when it actually starts, so the sooner it is
/// ready the smaller the anchor.
///
/// The host tests override this with a fake, so they never touch a real
/// player.
final introScoreProvider = Provider<IntroScore>((ref) {
  final score = AudioplayersIntroScore();
  ref.onDispose(() {
    score.dispose();
  });
  return score;
});
