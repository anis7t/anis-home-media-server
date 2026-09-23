import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:media_kit/media_kit.dart';

const String wanOrigin = 'https://media.anisparvez.in';
const String testDeviceId = 'dev_poc_wan_probe';
const String libmpvPath = 'C:/MediaServer/flutter_client/build/windows/x64/runner/Release/libmpv-2.dll';

void log(String tag, String msg) {
  final now = DateTime.now().toIso8601String().substring(11, 23);
  print('[$now] [$tag] $msg');
}

Future<void> main() async {
  MediaKit.ensureInitialized(libmpv: libmpvPath);

  print('\n=== PROBING WAN DIRECT MP4 (15s Window) ===');
  {
    const filename = 'Batman Knightfall Part 1 2026 1080p WEBRip x264 AAC5 1-[YTS GG - YTS BZ].mp4';
    final wanUrl = '$wanOrigin/media/${Uri.encodeComponent(filename)}';

    final player = Player();
    final positions = <Duration>[];
    final subPos = player.stream.position.listen((p) {
      if (p > Duration.zero) positions.add(p);
      log('WAN MP4 STREAM', 'Pos: ${p.inSeconds}s (${p.inMilliseconds}ms), Playing: ${player.state.playing}, Buffering: ${player.state.buffering}');
    });
    final subBuf = player.stream.buffering.listen((b) {
      log('WAN MP4 BUF', 'Buffering state: $b');
    });

    log('WAN MP4', 'Opening $wanUrl');
    final sw = Stopwatch()..start();
    await player.open(Media(wanUrl, httpHeaders: {'X-Device-Id': testDeviceId}), play: true);

    // Monitor for 15 seconds
    for (int i = 1; i <= 15; i++) {
      await Future.delayed(const Duration(seconds: 1));
      log('WAN MP4 [t=${i}s]', 'Pos: ${player.state.position.inSeconds}s, Dur: ${player.state.duration.inSeconds}s, Buf: ${player.state.buffering}');
      if (player.state.position.inSeconds > 0) break;
    }
    sw.stop();
    log('WAN MP4 RESULT', 'Finished in ${sw.elapsedMilliseconds}ms. Total samples > 0: ${positions.length}');

    await subPos.cancel();
    await subBuf.cancel();
    await player.dispose();
  }

  print('\n=== PROBING WAN HLS (15s Window) ===');
  {
    const filename = 'Spider-Man- Brand New Day 2026.1080p.HQ Pre.Multi.AAC 2.0.x264.mkv';
    final wanUrl = '$wanOrigin/hls/${Uri.encodeComponent(filename)}/playlist.m3u8';

    final player = Player();
    final positions = <Duration>[];
    final subPos = player.stream.position.listen((p) {
      if (p > Duration.zero) positions.add(p);
      log('WAN HLS STREAM', 'Pos: ${p.inSeconds}s (${p.inMilliseconds}ms), Playing: ${player.state.playing}');
    });

    log('WAN HLS', 'Opening $wanUrl');
    final sw = Stopwatch()..start();
    await player.open(Media(wanUrl, httpHeaders: {'X-Device-Id': testDeviceId}), play: true);

    for (int i = 1; i <= 15; i++) {
      await Future.delayed(const Duration(seconds: 1));
      log('WAN HLS [t=${i}s]', 'Pos: ${player.state.position.inSeconds}s, Dur: ${player.state.duration.inSeconds}s, Buf: ${player.state.buffering}');
      if (player.state.position.inSeconds > 0) break;
    }
    sw.stop();
    log('WAN HLS RESULT', 'Finished in ${sw.elapsedMilliseconds}ms. Total samples > 0: ${positions.length}');

    await subPos.cancel();
    await player.dispose();
  }
}
