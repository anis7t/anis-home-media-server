import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player/application/playback_progress_reporter.dart';

/// Regression tests for resume-position persistence.
///
/// The app used to *read* the resume point (via `/api/media-info` + the movie
/// list) but never *write* it, so the position only moved when a browser played
/// the file. These tests pin the cadence the reporter now mirrors from the web
/// player: autosave on a playback delta, save on pause, one write per seek,
/// 0 on completion, and a flush when the player is left (the back path).
void main() {
  late List<String> saves;
  late PlaybackProgressReporter reporter;

  PlaybackProgressReporter build({
    Duration saveEvery = const Duration(seconds: 10),
    Duration seekDebounce = const Duration(seconds: 2),
    Duration minimumPosition = const Duration(seconds: 1),
    bool failSaves = false,
  }) =>
      PlaybackProgressReporter(
        saveEvery: saveEvery,
        seekDebounce: seekDebounce,
        minimumPosition: minimumPosition,
        save: (position, duration) async {
          if (failSaves) throw StateError('network down');
          saves.add('${position.inSeconds}s/${duration.inSeconds}s');
        },
      );

  setUp(() {
    saves = [];
    reporter = build();
  });

  group('autosave', () {
    test('writes only after the playback delta, never the first sample', () {
      reporter.onPosition(const Duration(seconds: 600), const Duration(minutes: 90));
      expect(saves, isEmpty, reason: 'opening at the saved resume point is not progress');

      reporter.onPosition(const Duration(seconds: 605), const Duration(minutes: 90));
      expect(saves, isEmpty, reason: '5s of playback is below the 10s delta');

      reporter.onPosition(const Duration(seconds: 611), const Duration(minutes: 90));
      expect(saves, equals(['611s/5400s']));

      reporter.onPosition(const Duration(seconds: 615), const Duration(minutes: 90));
      expect(saves, hasLength(1), reason: 'the delta restarts from the last write');

      reporter.onPosition(const Duration(seconds: 622), const Duration(minutes: 90));
      expect(saves, equals(['611s/5400s', '622s/5400s']));
    });

    test('tracks backwards seeks so a rewind is not saved as a delta', () {
      reporter.onPosition(const Duration(seconds: 600), const Duration(minutes: 90));
      reporter.onPosition(const Duration(seconds: 400), const Duration(minutes: 90));
      expect(saves, equals(['400s/5400s']));
    });
  });

  group('pause', () {
    test('flushes the current position immediately', () {
      reporter.onPosition(const Duration(seconds: 600), const Duration(minutes: 90));
      reporter.onPosition(const Duration(seconds: 604), const Duration(minutes: 90));
      expect(saves, isEmpty);

      reporter.onPause();
      expect(saves, equals(['604s/5400s']));
    });

    test('does not persist a title that was only previewed', () {
      reporter.onPosition(const Duration(milliseconds: 500), const Duration(minutes: 90));
      reporter.onPause();
      reporter.flush();
      reporter.dispose();
      expect(saves, isEmpty, reason: 'below the minimum position there is nothing to resume');
    });
  });

  group('seek', () {
    test('debounces a scrub into a single write of the final target', () {
      fakeAsync((async) {
        reporter.onPosition(const Duration(seconds: 600), const Duration(minutes: 90));

        for (final target in [700, 740, 780, 820, 900]) {
          reporter.onSeek(Duration(seconds: target));
          async.elapse(const Duration(milliseconds: 200));
        }
        expect(saves, isEmpty, reason: 'nothing is written while the scrub is still moving');

        async.elapse(const Duration(seconds: 2));
        expect(saves, equals(['900s/5400s']));
      });
    });

    test('a seek target below the minimum is dropped', () {
      fakeAsync((async) {
        reporter.onSeek(const Duration(seconds: 30));
        async.elapse(const Duration(seconds: 3));
        expect(saves, equals(['30s/0s']));

        reporter.onSeek(const Duration(milliseconds: 400));
        async.elapse(const Duration(seconds: 3));
        expect(saves, hasLength(1), reason: 'seeking to the very start is not a resume point');
      });
    });
  });

  group('completion', () {
    test('writes 0 only when the position really is at the end', () {
      reporter.onPosition(const Duration(seconds: 5395), const Duration(minutes: 90));
      reporter.onEnded();
      expect(saves, equals(['0s/5400s']));

      reporter.onPosition(const Duration(seconds: 5399), const Duration(minutes: 90));
      reporter.onPause();
      reporter.flush();
      expect(saves, hasLength(1), reason: 'a watched title stays quiet afterwards');
    });

    test('a mid-file completion (stream torn down) keeps the resume point', () {
      // Observed on device: media_kit reports `completed` when the player is
      // stopped or a byte range ends. Writing 0 there wiped the resume point.
      reporter.onPosition(const Duration(seconds: 3000), const Duration(minutes: 90));
      reporter.onEnded();
      expect(saves, equals(['3000s/5400s']), reason: 'must flush, not mark watched');

      reporter.onPosition(const Duration(seconds: 3010), const Duration(minutes: 90));
      expect(saves, hasLength(2));
    });
  });

  group('teardown', () {
    test('dispose never writes - the exit save belongs to the back path', () {
      reporter.onPosition(const Duration(seconds: 600), const Duration(minutes: 90));
      reporter.onPosition(const Duration(seconds: 630), const Duration(minutes: 90));
      // 30 s of playback: the autosave persisted it before any teardown.
      expect(saves, equals(['630s/5400s']));

      reporter.dispose();
      expect(saves, hasLength(1),
          reason: 'dispose must not post: Dio schedules a timer that outlives the widget');

      reporter.onPosition(const Duration(seconds: 700), const Duration(minutes: 90));
      reporter.onSeek(const Duration(seconds: 800));
      reporter.flush();
      reporter.dispose();
      expect(saves, hasLength(1), reason: 'nothing may be written after teardown');
    });

    test('a sealed reporter ignores the 0 that stop() reports', () {
      reporter.onPosition(const Duration(seconds: 1600), const Duration(minutes: 78));
      reporter.flush(); // the exit save, on the player's back path
      reporter.dispose(); // sealed: stop() then resets the player to 0
      reporter.onPosition(Duration.zero, const Duration(minutes: 78));
      expect(saves, equals(['1600s/4680s']),
          reason: 'the reset must not overwrite the watched position');
    });

    test('a failing save never disturbs playback', () {
      final failing = build(failSaves: true);
      failing.onPosition(const Duration(seconds: 600), const Duration(minutes: 90));
      failing.onPosition(const Duration(seconds: 700), const Duration(minutes: 90));
      failing.onPause();
      failing.dispose();
      expect(saves, isEmpty);
    });
  });
}
