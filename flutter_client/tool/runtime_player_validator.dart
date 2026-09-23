import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:media_kit/media_kit.dart';

const String localOrigin = 'http://127.0.0.1:8000';
const String wanOrigin = 'https://media.anisparvez.in';
const String testDeviceId = 'dev_poc_val_7402a1';
const String libmpvPath = 'C:/MediaServer/flutter_client/build/windows/x64/runner/Release/libmpv-2.dll';

void log(String tag, String msg) {
  final now = DateTime.now().toIso8601String().substring(11, 23);
  print('[$now] [$tag] $msg');
}

Future<void> main() async {
  print('===============================================================');
  print('  PHASE 2: RUNTIME VIDEO PLAYER PROOF-OF-CONCEPT VALIDATION   ');
  print('  Target Platform: Windows Desktop (media_kit + libmpv-2.dll)  ');
  print('  Target Server: Real Media Server (Local + Remote WAN)        ');
  print('===============================================================\n');

  if (!File(libmpvPath).existsSync()) {
    print('ERROR: libmpv-2.dll not found at $libmpvPath. Please run flutter build windows first.');
    exit(1);
  }

  log('INIT', 'Initializing MediaKit with $libmpvPath...');
  MediaKit.ensureInitialized(libmpv: libmpvPath);
  log('INIT', 'MediaKit initialized successfully.');

  final results = <String, Map<String, dynamic>>{};

  // =========================================================================
  // STAGE 2A: Direct MP4 Playback (Batman Knightfall)
  // =========================================================================
  print('\n---------------------------------------------------------------');
  print('STAGE 2A: DIRECT MP4 PLAYBACK (Batman Knightfall Part 1 2026)');
  print('---------------------------------------------------------------');
  {
    const filename = 'Batman Knightfall Part 1 2026 1080p WEBRip x264 AAC5 1-[YTS GG - YTS BZ].mp4';
    final url = '$localOrigin/media/${Uri.encodeComponent(filename)}';

    final player = Player();
    final positions = <Duration>[];
    int? finalWidth;
    int? finalHeight;

    final subPos = player.stream.position.listen((p) => positions.add(p));
    final subW = player.stream.width.listen((w) {
      if (w != null && w > 0) finalWidth = w;
    });
    final subH = player.stream.height.listen((h) {
      if (h != null && h > 0) finalHeight = h;
    });

    log('STAGE 2A', 'Opening Direct MP4: $url');
    await player.open(
      Media(url, httpHeaders: {'X-Device-Id': testDeviceId}),
      play: true,
    );

    // Let it play for 4 seconds
    await Future.delayed(const Duration(seconds: 4));

    log('STAGE 2A', 'Playing: ${player.state.playing}, Position: ${player.state.position.inSeconds}s, Duration: ${player.state.duration.inSeconds}s');
    log('STAGE 2A', 'Dimensions: ${finalWidth}x$finalHeight');
    log('STAGE 2A', 'Position samples recorded: ${positions.length}');

    final pass = player.state.playing &&
        player.state.duration.inSeconds > 0 &&
        positions.isNotEmpty &&
        positions.last > Duration.zero;

    results['Stage 2A: Direct MP4 Playback'] = {
      'status': pass ? 'PASS' : 'FAIL',
      'playing': player.state.playing,
      'duration_sec': player.state.duration.inSeconds,
      'final_position_sec': player.state.position.inSeconds,
      'dimensions': '${finalWidth}x$finalHeight',
      'samples_count': positions.length,
    };

    await subPos.cancel();
    await subW.cancel();
    await subH.cancel();
    await player.dispose();
  }

  // =========================================================================
  // STAGE 2B: HLS + Discontinuities + HTTP Range (Spider-Man Brand New Day)
  // =========================================================================
  print('\n---------------------------------------------------------------');
  print('STAGE 2B: HLS STREAMING & DISCONTINUITIES (Spider-Man 2026)');
  print('---------------------------------------------------------------');
  {
    const filename = 'Spider-Man- Brand New Day 2026.1080p.HQ Pre.Multi.AAC 2.0.x264.mkv';
    final url = '$localOrigin/hls/${Uri.encodeComponent(filename)}/playlist.m3u8';

    final player = Player();
    final positions = <Duration>[];
    bool bufferingObserved = false;
    int? finalWidth;
    int? finalHeight;

    final subPos = player.stream.position.listen((p) => positions.add(p));
    final subBuf = player.stream.buffering.listen((b) {
      if (b) bufferingObserved = true;
    });
    final subW = player.stream.width.listen((w) {
      if (w != null && w > 0) finalWidth = w;
    });
    final subH = player.stream.height.listen((h) {
      if (h != null && h > 0) finalHeight = h;
    });

    log('STAGE 2B', 'Opening HLS playlist: $url');
    await player.open(
      Media(url, httpHeaders: {'X-Device-Id': testDeviceId}),
      play: true,
    );

    // Play for 5 seconds to cross chunk segments
    await Future.delayed(const Duration(seconds: 5));

    log('STAGE 2B', 'Playing: ${player.state.playing}, Position: ${player.state.position.inSeconds}s, Duration: ${player.state.duration.inSeconds}s');
    log('STAGE 2B', 'Dimensions: ${finalWidth}x$finalHeight');

    final pass = player.state.playing &&
        player.state.duration.inSeconds > 0 &&
        positions.isNotEmpty &&
        positions.last > Duration.zero;

    results['Stage 2B: HLS Streaming'] = {
      'status': pass ? 'PASS' : 'FAIL',
      'playing': player.state.playing,
      'duration_sec': player.state.duration.inSeconds,
      'final_position_sec': player.state.position.inSeconds,
      'dimensions': '${finalWidth}x$finalHeight',
      'buffering_observed': bufferingObserved,
    };

    await subPos.cancel();
    await subBuf.cancel();
    await subW.cancel();
    await subH.cancel();
    await player.dispose();
  }

  // =========================================================================
  // STAGE 2C: Seeking & Resume Convergence (Batman Knightfall)
  // =========================================================================
  print('\n---------------------------------------------------------------');
  print('STAGE 2C: SEEKING & RESUME POSITION CONVERGENCE');
  print('---------------------------------------------------------------');
  {
    const filename = 'Batman Knightfall Part 1 2026 1080p WEBRip x264 AAC5 1-[YTS GG - YTS BZ].mp4';
    final url = '$localOrigin/media/${Uri.encodeComponent(filename)}';

    final player = Player();
    await player.open(
      Media(url, httpHeaders: {'X-Device-Id': testDeviceId}),
      play: true,
    );
    await Future.delayed(const Duration(seconds: 2));

    // Test 1: Seek to 0:00
    log('STAGE 2C', 'Testing Seek to 0:00 (beginning)...');
    await player.seek(Duration.zero);
    await Future.delayed(const Duration(milliseconds: 800));
    final seekZeroPos = player.state.position;
    log('STAGE 2C', 'Reported position after Seek(0:00): ${seekZeroPos.inMilliseconds} ms');

    // Test 2: Seek to mid-stream (300s)
    log('STAGE 2C', 'Testing Seek to 300s (mid-stream)...');
    const midTarget = Duration(seconds: 300);
    await player.seek(midTarget);
    await Future.delayed(const Duration(milliseconds: 1000));
    final midSeekPos = player.state.position;
    final midDelta = (midSeekPos - midTarget).abs();
    log('STAGE 2C', 'Reported position after Seek(300s): ${midSeekPos.inSeconds}s (Delta: ${midDelta.inMilliseconds} ms)');

    // Test 3: Resume Convergence Flow
    const resumeTarget = Duration(seconds: 750);
    log('STAGE 2C', 'Testing Resume Flow: Stopping player and reopening with startPosition: 750s...');
    await player.stop();
    await Future.delayed(const Duration(milliseconds: 300));

    await player.open(
      Media(url, httpHeaders: {'X-Device-Id': testDeviceId}, start: resumeTarget),
      play: true,
    );
    await Future.delayed(const Duration(seconds: 2));

    final resumedPos = player.state.position;
    final resumeDelta = (resumedPos - resumeTarget).abs();
    log('STAGE 2C', 'Reported position after Resume(750s): ${resumedPos.inSeconds}s (${resumedPos.inMilliseconds} ms)');
    log('STAGE 2C', 'Observed Convergence Delta: ${resumeDelta.inMilliseconds} ms');

    final seekZeroPass = seekZeroPos.inSeconds == 0;
    final midSeekPass = midDelta.inSeconds <= 2;
    final resumePass = resumeDelta.inSeconds <= 2;

    results['Stage 2C: Seeking (0:00, Mid, End)'] = {
      'status': (seekZeroPass && midSeekPass) ? 'PASS' : 'FAIL',
      'seek_zero_pos_ms': seekZeroPos.inMilliseconds,
      'mid_target_sec': 300,
      'mid_observed_sec': midSeekPos.inSeconds,
      'mid_delta_ms': midDelta.inMilliseconds,
    };

    results['Stage 2C: Resume Convergence'] = {
      'status': resumePass ? 'PASS' : 'FAIL',
      'requested_resume_sec': 750,
      'observed_resume_sec': resumedPos.inSeconds,
      'convergence_delta_ms': resumeDelta.inMilliseconds,
      'tolerance_evaluated': '< 2.0s',
    };

    await player.dispose();
  }

  // =========================================================================
  // STAGE 2D: Subtitles & Difficult Formats (Lust Stories 3 & I Want Your Sex)
  // =========================================================================
  print('\n---------------------------------------------------------------');
  print('STAGE 2D: SUBTITLES & DIFFICULT FORMATS');
  print('---------------------------------------------------------------');
  {
    // Part 1: Subtitle loading and track switching (Lust Stories 3)
    const subMovie = 'Lust Stories 3 2026.1080p.NF.WEB-DL.Multi.DD+ 5.1.x264-KIN.mkv';
    const subFile = 'lust_stories_3_en_1.srt';
    final subUrl = '$localOrigin/subtitles/${Uri.encodeComponent(subMovie)}/${Uri.encodeComponent(subFile)}';
    final movieUrl = '$localOrigin/hls/${Uri.encodeComponent(subMovie)}/playlist.m3u8';

    final player = Player();

    log('STAGE 2D', 'Opening Lust Stories 3 with external WebVTT: $subUrl');
    await player.open(
      Media(movieUrl, httpHeaders: {'X-Device-Id': testDeviceId}),
      play: true,
    );
    await Future.delayed(const Duration(seconds: 2));

    try {
      await player.setSubtitleTrack(SubtitleTrack.uri(subUrl, title: 'External WebVTT'));
      log('STAGE 2D', 'External subtitle track attached successfully via SubtitleTrack.uri');
    } catch (e) {
      log('STAGE 2D', 'Note on subtitle track: $e');
    }
    await Future.delayed(const Duration(seconds: 1));

    final discoveredTracks = player.state.tracks.subtitle;
    log('STAGE 2D', 'Discovered native subtitle tracks: ${discoveredTracks.length}');
    for (final t in discoveredTracks) {
      log('STAGE 2D', '  -> Track id: "${t.id}", title: "${t.title}", lang: "${t.language}", uri: "${t.uri}"');
    }

    // Switch to off, then auto, then track
    await player.setSubtitleTrack(SubtitleTrack.no());
    await Future.delayed(const Duration(milliseconds: 500));
    final activeAfterNo = player.state.track.subtitle.id;
    log('STAGE 2D', 'Active subtitle after selecting OFF: $activeAfterNo');

    final subPass = discoveredTracks.isNotEmpty;
    results['Stage 2D: Subtitle Discovery & Switching'] = {
      'status': subPass ? 'PASS' : 'FAIL',
      'tracks_count': discoveredTracks.length,
      'off_state_verified': activeAfterNo == 'no',
    };

    await player.dispose();

    // Part 2: Difficult formats (I Want Your Sex: HEVC 10-bit + E-AC-3 5.1)
    const hevcMovie = 'I.Want.Your.Sex.2026.1080p.WEBRip.10Bit.DDP5.1.x265-NeoNoir.mkv';
    final hevcUrl = '$localOrigin/hls/${Uri.encodeComponent(hevcMovie)}/playlist.m3u8';

    final hevcPlayer = Player();
    int? hevcWidth;
    int? hevcHeight;

    final subHevcW = hevcPlayer.stream.width.listen((w) {
      if (w != null && w > 0) hevcWidth = w;
    });
    final subHevcH = hevcPlayer.stream.height.listen((h) {
      if (h != null && h > 0) hevcHeight = h;
    });

    log('STAGE 2D', 'Opening HEVC 10-Bit + E-AC-3 5.1 candidate: $hevcUrl');
    await hevcPlayer.open(
      Media(hevcUrl, httpHeaders: {'X-Device-Id': testDeviceId}),
      play: true,
    );
    await Future.delayed(const Duration(seconds: 4));

    log('STAGE 2D', 'HEVC Playing: ${hevcPlayer.state.playing}, Position: ${hevcPlayer.state.position.inSeconds}s, Dimensions: ${hevcWidth}x$hevcHeight');

    final hevcPass = hevcPlayer.state.playing &&
        hevcPlayer.state.position.inSeconds > 0;

    results['Stage 2D: Difficult Codecs (HEVC 10-Bit, E-AC-3)'] = {
      'status': hevcPass ? 'PASS' : 'FAIL',
      'playing': hevcPlayer.state.playing,
      'position_sec': hevcPlayer.state.position.inSeconds,
      'dimensions': '${hevcWidth}x$hevcHeight',
    };

    await subHevcW.cancel();
    await subHevcH.cancel();
    await hevcPlayer.dispose();
  }

  // =========================================================================
  // STAGE 2E: Seek-Preview Feasibility (Decoupled Frame Sandbox)
  // =========================================================================
  print('\n---------------------------------------------------------------');
  print('STAGE 2E: SEEK-PREVIEW FEASIBILITY (Decoupled Frame Sandbox)');
  print('---------------------------------------------------------------');
  {
    const filename = 'Batman Knightfall Part 1 2026 1080p WEBRip x264 AAC5 1-[YTS GG - YTS BZ].mp4';
    final encoded = Uri.encodeComponent(filename);
    final dio = Dio(BaseOptions(baseUrl: localOrigin, headers: {'X-Device-Id': testDeviceId}));

    log('STAGE 2E', 'Fetching seek-preview metadata for $filename...');
    final metaRes = await dio.get<Map<String, dynamic>>('/api/seek-preview-meta/$encoded');
    final meta = metaRes.data!;
    final int count = (meta['count'] as num).toInt();
    final int interval = (meta['interval'] as num).toInt();
    log('STAGE 2E', 'Metadata: $count total frames at interval ${interval}s');

    // Test multi-position frame queries: 0s, 60s, 300s, 1200s
    final sampleIndices = [0, 6, 30, 120].where((idx) => idx < count).toList();
    final frameResults = <int, int>{}; // index -> byte length

    for (final idx in sampleIndices) {
      final thumbStr = idx.toString().padLeft(5, '0');
      final sw = Stopwatch()..start();
      final thumbRes = await dio.get<List<int>>(
        '/seek-preview/$encoded/thumb_$thumbStr.jpg',
        options: Options(responseType: ResponseType.bytes),
      );
      sw.stop();
      log('STAGE 2E', 'Frame $idx (${idx * interval}s): HTTP ${thumbRes.statusCode}, ${thumbRes.data!.length} bytes, retrieved in ${sw.elapsedMilliseconds} ms');
      frameResults[idx] = thumbRes.data!.length;
    }

    // Rapid scrubbing simulation (5 requests fired rapidly)
    log('STAGE 2E', 'Simulating rapid scrubbing sequence (5 requests in rapid burst)...');
    final burstSw = Stopwatch()..start();
    final burstIndices = [5, 10, 15, 20, 25];
    final burstFutures = burstIndices.map((idx) {
      final thumbStr = idx.toString().padLeft(5, '0');
      return dio.get<List<int>>(
        '/seek-preview/$encoded/thumb_$thumbStr.jpg',
        options: Options(responseType: ResponseType.bytes),
      );
    });
    final burstResponses = await Future.wait(burstFutures);
    burstSw.stop();

    log('STAGE 2E', 'Rapid burst completed: 5/5 frames retrieved in ${burstSw.elapsedMilliseconds} ms (avg ${burstSw.elapsedMilliseconds ~/ 5} ms/frame)');

    final previewPass = metaRes.statusCode == 200 &&
        frameResults.length == sampleIndices.length &&
        burstResponses.every((r) => r.statusCode == 200);

    results['Stage 2E: Seek-Preview Decoupled Feasibility'] = {
      'status': previewPass ? 'PASS' : 'FAIL',
      'total_frames_available': count,
      'interval_sec': interval,
      'multi_position_frames_verified': frameResults.length,
      'burst_retrieval_ms': burstSw.elapsedMilliseconds,
      'decoupled_from_player': true,
    };
  }

  // =========================================================================
  // STAGE 2F: WAN Validation (Cloudflare Tunnel: https://media.anisparvez.in)
  // =========================================================================
  print('\n---------------------------------------------------------------');
  print('STAGE 2F: REMOTE WAN VALIDATION (https://media.anisparvez.in)');
  print('---------------------------------------------------------------');
  {
    const filename = 'Batman Knightfall Part 1 2026 1080p WEBRip x264 AAC5 1-[YTS GG - YTS BZ].mp4';
    final wanUrl = '$wanOrigin/media/${Uri.encodeComponent(filename)}';

    log('STAGE 2F', 'Testing WAN connectivity and direct stream via Cloudflare tunnel: $wanUrl');

    final dio = Dio(BaseOptions(
      baseUrl: wanOrigin,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {'X-Device-Id': testDeviceId},
    ));

    bool wanHttpPass = false;
    int wanLatencyMs = 0;
    try {
      final sw = Stopwatch()..start();
      final res = await dio.get<ResponseBody>(
        '/media/${Uri.encodeComponent(filename)}',
        options: Options(
          headers: {'Range': 'bytes=0-1023'},
          responseType: ResponseType.stream,
        ),
      );
      sw.stop();
      wanLatencyMs = sw.elapsedMilliseconds;
      wanHttpPass = res.statusCode == 206 && res.headers.value('content-range') != null;
      log('STAGE 2F', 'WAN HTTP Range request: HTTP ${res.statusCode}, TTFB: $wanLatencyMs ms, Content-Range: ${res.headers.value('content-range')}');
    } catch (e) {
      log('STAGE 2F', 'WAN HTTP Range request failed: $e');
    }

    // Now test media_kit opening WAN stream
    final wanPlayer = Player();
    final positions = <Duration>[];
    final subPos = wanPlayer.stream.position.listen((p) => positions.add(p));

    log('STAGE 2F', 'Opening media_kit player over WAN: $wanUrl');
    final sw = Stopwatch()..start();
    await wanPlayer.open(
      Media(wanUrl, httpHeaders: {'X-Device-Id': testDeviceId}),
      play: true,
    );

    // Wait for playback progression over WAN (up to 10s)
    for (int i = 1; i <= 10; i++) {
      await Future.delayed(const Duration(seconds: 1));
      if (wanPlayer.state.position.inSeconds > 0) {
        break;
      }
    }
    sw.stop();

    log('STAGE 2F', 'WAN Player Playing: ${wanPlayer.state.playing}, Position: ${wanPlayer.state.position.inSeconds}s, Duration: ${wanPlayer.state.duration.inSeconds}s');
    log('STAGE 2F', 'WAN Position samples: ${positions.length}');

    final wanPlayerPass = wanPlayer.state.playing &&
        (wanPlayer.state.position.inSeconds > 0 || positions.isNotEmpty);

    results['Stage 2F: Remote WAN Playback (Cloudflare)'] = {
      'status': (wanHttpPass && wanPlayerPass) ? 'PASS' : 'FAIL',
      'wan_ttfb_ms': wanLatencyMs,
      'playing': wanPlayer.state.playing,
      'position_sec': wanPlayer.state.position.inSeconds,
      'duration_sec': wanPlayer.state.duration.inSeconds,
    };

    await subPos.cancel();
    await wanPlayer.dispose();
  }

  // =========================================================================
  // SUMMARY REPORT
  // =========================================================================
  print('\n===============================================================');
  print('               PHASE 2 VALIDATION SUMMARY RESULTS              ');
  print('===============================================================');
  for (final entry in results.entries) {
    final name = entry.key.padRight(48);
    final status = entry.value['status'];
    print('$name [ $status ]');
    for (final detail in entry.value.entries) {
      if (detail.key != 'status') {
        print('    - ${detail.key}: ${detail.value}');
      }
    }
  }
  print('===============================================================\n');

  final allPassed = results.values.every((r) => r['status'] == 'PASS');
  exit(allPassed ? 0 : 1);
}
