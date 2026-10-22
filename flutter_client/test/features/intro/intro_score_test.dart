import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/intro/domain/intro_score.dart';
import 'package:media_server_client/features/intro/presentation/controllers/intro_score_controller.dart';

/// A score that records what it was asked to do.
class _FakeScore implements IntroScore {
  final List<String> calls = [];
  final List<Duration> playedFrom = [];
  final Completer<void> gate = Completer<void>();
  bool _prepared = false;

  @override
  Future<void> prepare() async {
    calls.add('prepare');
    _prepared = true;
  }

  @override
  Future<void> get ready async {
    await prepare();
    await gate.future;
  }

  @override
  Future<void> playFrom(Duration elapsed) async {
    calls.add('playFrom');
    playedFrom.add(elapsed);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
  }

  bool get isPrepared => _prepared;
}

void main() {
  group('the score\'s lifecycle', () {
    test('the score is prepared as early as possible', () async {
      final score = _FakeScore();
      await score.prepare();
      expect(score.isPrepared, isTrue);
      expect(score.calls, ['prepare']);
    });

    test('the score starts in step with the sequence', () async {
      final score = _FakeScore();
      score.gate.complete();
      final controller = IntroScoreController(
        score: score,
        elapsedAt: () => const Duration(milliseconds: 120),
        duration: const Duration(seconds: 3),
      );

      await controller.start();

      expect(score.playedFrom, [const Duration(milliseconds: 120)]);
    });

    test('the anchor is the sequence\'s position when the score is ready', () async {
      // The platform needed longer to prepare than the sequence had been
      // running, so the score must start from where the PICTURE is - not
      // from where it was when the sequence began.
      final score = _FakeScore();
      var elapsed = const Duration(milliseconds: 10);
      final controller = IntroScoreController(
        score: score,
        elapsedAt: () => elapsed,
        duration: const Duration(seconds: 3),
      );

      final started = controller.start();
      // The sequence carries on while the score is still preparing.
      elapsed = const Duration(milliseconds: 340);
      score.gate.complete();
      await started;

      expect(score.playedFrom, [const Duration(milliseconds: 340)]);
    });

    test('the score is dropped when the sequence is over', () async {
      // A sound out of nowhere is worse than no sound.
      final score = _FakeScore();
      score.gate.complete();
      final controller = IntroScoreController(
        score: score,
        elapsedAt: () => const Duration(seconds: 3),
        duration: const Duration(seconds: 3),
      );

      await controller.start();

      expect(score.calls, isNot(contains('playFrom')));
    });

    test('the score stops when the sequence finishes', () async {
      final score = _FakeScore();
      score.gate.complete();
      final controller = IntroScoreController(
        score: score,
        elapsedAt: () => Duration.zero,
        duration: const Duration(seconds: 3),
      );

      await controller.start();
      await controller.stop();

      expect(score.calls, contains('stop'));
    });
  });

  group('the silent score', () {
    test('does nothing, and does not throw', () async {
      const score = SilentIntroScore();
      await score.prepare();
      await score.ready;
      await score.playFrom(const Duration(milliseconds: 500));
      await score.stop();
      await score.dispose();
    });
  });
}
