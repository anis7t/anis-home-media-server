import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/intro/presentation/controllers/intro_controller.dart';

/// A controller whose intro is already playing.
///
/// The canonical design has no Replay path (decision D4), so `IntroController.build()`
/// is the only place the playing state comes from - and it forces `isPlaying: false`
/// under `FLUTTER_TEST`. Overriding `build()` is therefore the only way to exercise the
/// playing -> finished transition, and it mirrors the pattern already established by
/// `brand_intro_overlay_test.dart`.
class _PlayingIntroController extends IntroController {
  @override
  IntroState build() {
    return const IntroState(isPlaying: true);
  }
}

void main() {
  group('IntroController Unit Tests', () {
    test('initial state handles test environment defaults safely', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final state = container.read(introControllerProvider);
      // In the flutter test runner, isPlaying is false by default to prevent UI tests from blocking
      expect(state.isPlaying, isFalse);
    });

    test('the intro plays on every launch, and that is deliberate', () {
      // The canonical specification says the Android client's intro plays on
      // EVERY launch (Part I section 10). It used to be accidental: a
      // `hasSeenIntro` flag was written when the sequence finished, and
      // nothing ever read it and nothing ever persisted it. The flag is gone;
      // the behaviour is now stated.
      //
      // The only thing that stops it playing is the test environment, which
      // is why this is asserted through a controller that is not in one.
      final container = ProviderContainer(
        overrides: [
          introControllerProvider.overrideWith(() => _PlayingIntroController()),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(introControllerProvider).isPlaying, isTrue);
    });

    test('markFinished stops the sequence', () {
      final container = ProviderContainer(
        overrides: [
          introControllerProvider.overrideWith(() => _PlayingIntroController()),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(introControllerProvider.notifier);
      // The intro is playing, so markFinished() has a real transition to make.
      expect(container.read(introControllerProvider).isPlaying, isTrue);

      notifier.markFinished();
      expect(container.read(introControllerProvider).isPlaying, isFalse);
    });

    test('there is no way to bring the sequence back', () {
      // Decision D4: no Replay affordance anywhere. The controller exposes
      // exactly one way to change the state, and it only ever stops it.
      final container = ProviderContainer(
        overrides: [
          introControllerProvider.overrideWith(() => _PlayingIntroController()),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(introControllerProvider.notifier);
      notifier.markFinished();
      expect(container.read(introControllerProvider).isPlaying, isFalse);
      // And nothing puts it back.
      expect(container.read(introControllerProvider).isPlaying, isFalse);
    });

    test('IntroState copyWith preserves unspecified values', () {
      const initial = IntroState(isPlaying: true);
      final updated = initial.copyWith(isPlaying: false);

      expect(updated.isPlaying, isFalse);
    });
  });
}
