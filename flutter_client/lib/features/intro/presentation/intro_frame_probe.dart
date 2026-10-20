// TEMPORARY MEASUREMENT PROBE - not for commit.
//
// Counts the sequence's animation ticks and writes the result to the app's
// private files directory, so it can be read back over adb:
//
//   adb shell run-as in.anisparvez.media_server_client cat files/probe.txt
//
// The tick rate is the presented frame rate: the Flutter pipeline is
// flow-controlled, so a frame is not presented until the previous one has
// been rastered.
import 'dart:io';

import 'package:flutter/scheduler.dart';

class IntroFrameProbe {
  IntroFrameProbe._();

  static final IntroFrameProbe _instance = IntroFrameProbe._();

  static IntroFrameProbe get instance => _instance;

  final List<int> _at = <int>[];
  bool _installed = false;

  void onTick() {
    _at.add(DateTime.now().microsecondsSinceEpoch);
    if (!_installed) {
      _installed = true;
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
    }
  }

  final List<List<int>> _timings = <List<int>>[];

  void _onTimings(List<FrameTiming> timings) {
    for (final f in timings) {
      _timings.add(<int>[
        f.buildDuration.inMicroseconds,
        f.rasterDuration.inMicroseconds,
      ]);
    }
  }

  void report() {
    final gaps = <int>[];
    for (var i = 1; i < _at.length; i++) {
      gaps.add(_at[i] - _at[i - 1]);
    }
    final sb = StringBuffer();
    sb.writeln('frames=${_at.length}');
    if (gaps.isNotEmpty) {
      final sorted = List<int>.of(gaps)..sort();
      final elapsed = _at.last - _at.first;
      sb.writeln('elapsed_ms=${(elapsed / 1000).round()}');
      sb.writeln('fps=${(gaps.length * 1000000 / elapsed).toStringAsFixed(1)}');
      sb.writeln('gap_us_p50=${sorted[(sorted.length - 1) * 50 ~/ 100]}');
      sb.writeln('gap_us_p95=${sorted[(sorted.length - 1) * 95 ~/ 100]}');
      sb.writeln('gap_us_max=${sorted.last}');
      sb.writeln('over_33ms=${gaps.where((g) => g > 33333).length}');
      sb.writeln('over_100ms=${gaps.where((g) => g > 100000).length}');
    }
    for (var i = 0; i < _timings.length; i++) {
      final t = _timings[i];
      sb.writeln('frame $i build_us=${t[0]} raster_us=${t[1]}');
    }
    try {
      File('${Directory.systemTemp.path}/intro_probe.txt').writeAsStringSync('$sb');
    } catch (_) {
      // The probe is a measurement, never a failure.
    }
    // ignore: avoid_print
    print('INTRO_PROBE\n$sb');
  }
}
