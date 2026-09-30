import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/intro/presentation/controllers/intro_controller.dart';

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

    test('replay sets isPlaying to true', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(introControllerProvider.notifier);
      notifier.replay();

      final state = container.read(introControllerProvider);
      expect(state.isPlaying, isTrue);
    });

    test('markFinished sets hasSeenIntro true and isPlaying false', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(introControllerProvider.notifier);
      notifier.replay();
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
