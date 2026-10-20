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
    return const IntroState(hasSeenIntro: false, isPlaying: true);
  }
}

void main() {
  group('IntroController Unit Tests', () {
    test('initial state handles test environment defaults safely', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final state = container.read(introControllerProvider);
      // In flutter test runner, isPlaying is false by default to prevent UI tests from blocking
      expect(state.isPlaying, isFalse);
      expect(state.hasSeenIntro, isTrue);
    });

    test('markFinished sets hasSeenIntro true and isPlaying false', () {
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
      final state = container.read(introControllerProvider);
      expect(state.isPlaying, isFalse);
      expect(state.hasSeenIntro, isTrue);
    });

    test('IntroState copyWith preserves unspecified values', () {
      const initial = IntroState(hasSeenIntro: false, isPlaying: true);
      final updated = initial.copyWith(isPlaying: false);

      expect(updated.hasSeenIntro, isFalse);
      expect(updated.isPlaying, isFalse);
    });
  });
}
