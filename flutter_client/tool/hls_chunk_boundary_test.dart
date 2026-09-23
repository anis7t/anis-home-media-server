import 'dart:async';
import 'package:media_kit/media_kit.dart';

const String lanOrigin = 'http://127.0.0.1:8000';
const String testDeviceId = 'dev_hls_boundary_probe';
const String libmpvPath =
    'C:/MediaServer/flutter_client/build/windows/x64/runner/Release/libmpv-2.dll';

void log(String tag, String msg) {
  final now = DateTime.now().toIso8601String().substring(11, 23);
  print('[$now] [$tag] $msg');
}

Future<void> main() async {
  MediaKit.ensureInitialized(libmpv: libmpvPath);

  print('\n=== HLS CHUNK BOUNDARY PLAYBACK RUNTIME TEST ===');
  const filename =
      'Spider-Man- Brand New Day 2026.1080p.HQ Pre.Multi.AAC 2.0.x264.mkv';
  final url =
      '$lanOrigin/hls/${Uri.encodeComponent(filename)}/playlist.m3u8';

  final player = Player();

  final positions = <Duration>[];
  final bufferingEvents = <bool>[];
  bool crossedBoundary = false;
  Duration? positionAtBoundary;
  DateTime? timeAtBoundary;

  player.stream.buffering.listen((b) {
    bufferingEvents.add(b);
    log('BUFFERING', 'Buffering state: $b');
  });

  player.stream.error.listen((e) {
    log('ERROR', 'libmpv error: $e');
  });

  player.stream.position.listen((p) {
    if (p > Duration.zero) {
      positions.add(p);
      if (!crossedBoundary && p >= const Duration(seconds: 60)) {
        crossedBoundary = true;
        positionAtBoundary = p;
        timeAtBoundary = DateTime.now();
        log('BOUNDARY', '>>> CROSSED 60.0s CHUNK BOUNDARY into chunk 1 at pos ${p.inMilliseconds}ms <<<');
      }
    }
  });

  // Start at 52 seconds (8s before the 60.0s boundary)
  const startSec = 52;
  log('TEST', 'Opening HLS playlist at ${startSec}s (8s before 60.0s boundary)...');
  log('TEST', 'URL: $url');

  final sw = Stopwatch()..start();
  await player.open(
    Media(
      url,
      start: const Duration(seconds: startSec),
      httpHeaders: {'X-Device-Id': testDeviceId},
    ),
    play: true,
  );

  // Poll for up to 35 seconds to allow playback to progress from 52s past 68s-70s
  final maxDeadline = DateTime.now().add(const Duration(seconds: 35));
  int lastLoggedSec = 0;

  while (DateTime.now().isBefore(maxDeadline)) {
    await Future.delayed(const Duration(milliseconds: 500));
    final currentPos = player.state.position;
    final sec = currentPos.inSeconds;

    if (sec != lastLoggedSec && sec >= startSec) {
      lastLoggedSec = sec;
      log('PLAYBACK', 'Pos: ${sec}s (${currentPos.inMilliseconds}ms), Playing: ${player.state.playing}, Buffering: ${player.state.buffering}');
    }

    // Stop once we have reached at least 68s (8s past boundary)
    if (sec >= 68) {
      log('TEST', 'Target position >= 68s achieved past boundary!');
      break;
    }
  }
  sw.stop();

  log('SUMMARY', 'Test duration: ${sw.elapsedMilliseconds}ms');
  log('SUMMARY', 'Crossed 60s boundary: $crossedBoundary');
  if (crossedBoundary) {
    log('SUMMARY', 'First position recorded >= 60s: ${positionAtBoundary?.inMilliseconds}ms at $timeAtBoundary');
  }
  log('SUMMARY', 'Final position reached: ${player.state.position.inSeconds}s (${player.state.position.inMilliseconds}ms)');
  log('SUMMARY', 'Total unique positions recorded: ${positions.length}');
  log('SUMMARY', 'Buffering state changes during run: ${bufferingEvents.length}');

  final pass = crossedBoundary && player.state.position >= const Duration(seconds: 68);
  log('VERDICT', 'HLS Chunk Boundary Transition Test: ${pass ? "PASS" : "FAIL"}');

  await player.dispose();
}
