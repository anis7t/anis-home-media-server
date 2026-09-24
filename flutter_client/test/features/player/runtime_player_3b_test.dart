import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_server_client/features/player/domain/player_controller_interface.dart';
import 'package:media_server_client/features/player/domain/seek_preview_controller.dart';
import 'package:media_server_client/features/player/infrastructure/media_kit_player_adapter.dart';

const String localOrigin = 'http://127.0.0.1:8000';
const String testDeviceId = 'dev_phase3b_val_104f7c';
const String libmpvPath =
    'C:/MediaServer/flutter_client/build/windows/x64/runner/Release/libmpv-2.dll';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
    if (File(libmpvPath).existsSync()) {
      MediaKit.ensureInitialized(libmpv: libmpvPath);
    } else {
      MediaKit.ensureInitialized();
    }
  });

  group('Phase 3B Runtime Verification Against Live Server', () {
    test('1. Live seek-preview metadata and thumbnail frame resolution', () async {
      const filename =
          'Batman Knightfall Part 1 2026 1080p WEBRip x264 AAC5 1-[YTS GG - YTS BZ].mp4';
      final encoded = Uri.encodeComponent(filename);

      final dio = Dio(BaseOptions(baseUrl: localOrigin));

      // 1. Fetch live preview metadata
      final metaRes = await dio.get<Map<String, dynamic>>('/api/seek-preview-meta/$encoded');
      expect(metaRes.statusCode, HttpStatus.ok);

      final meta = metaRes.data!;
      expect(meta.containsKey('duration'), isTrue);
      expect(meta.containsKey('interval'), isTrue);
      expect(meta.containsKey('count'), isTrue);

      final interval = (meta['interval'] as num).toDouble();
      final count = (meta['count'] as num).toInt();
      expect(interval, greaterThan(0.0));
      expect(count, greaterThan(0));

      // 2. Wire canonical SeekPreviewController
      final committedUrls = <String>[];
      final controller = SeekPreviewController(
        debounceDuration: const Duration(milliseconds: 80),
        urlResolver: (int frameIndex, int sequenceId) async {
          final thumbStr = frameIndex.toString().padLeft(5, '0');
          return '$localOrigin/seek-preview/$encoded/thumb_$thumbStr.jpg';
        },
        onStateChanged: (state) {
          if (state.displayedImageUrl != null) {
            committedUrls.add(state.displayedImageUrl!);
          }
        },
      );

      // Simulate seeking to 120 seconds
      const targetSeconds = 120.0;
      final frameIndex = (targetSeconds / interval).floor().clamp(0, count - 1);
      controller.requestFrame(frameIndex);

      expect(controller.state.isPendingDebounce, isTrue);

      // Wait for 80ms debounce + URL resolution
      await Future.delayed(const Duration(milliseconds: 120));

      expect(controller.state.isPendingDebounce, isFalse);
      expect(controller.state.displayedFrameIndex, equals(frameIndex));
      expect(committedUrls, isNotEmpty);

      // 3. Fetch the resolved JPEG thumbnail from the server
      final thumbRes = await dio.get<List<int>>(
        committedUrls.last.replaceFirst(localOrigin, ''),
        options: Options(responseType: ResponseType.bytes),
      );

      expect(thumbRes.statusCode, HttpStatus.ok);
      expect(thumbRes.headers.value('content-type'), contains('image/jpeg'));
      expect(thumbRes.data!.length, greaterThan(100)); // Valid non-empty JPEG bytes

      controller.dispose();
    });

    test('2. Live direct playback seeking and position progression', () async {
      final adapter = MediaKitPlayerAdapter();
      const filename =
          'Batman Knightfall Part 1 2026 1080p WEBRip x264 AAC5 1-[YTS GG - YTS BZ].mp4';
      final url = '$localOrigin/media/${Uri.encodeComponent(filename)}';

      final positions = <Duration>[];
      final sub = adapter.positionStream.listen((p) => positions.add(p));

      await adapter.open(
        url,
        headers: {'X-Device-Id': testDeviceId},
      );

      // Wait for playback to start
      final sw = Stopwatch()..start();
      while (positions.isEmpty || positions.last < const Duration(milliseconds: 1000)) {
        if (sw.elapsedMilliseconds > 15000) {
          fail('Playback failed to reach 1.0s within 15s');
        }
        await Future.delayed(const Duration(milliseconds: 200));
      }

      expect(adapter.state, equals(PlayerPlaybackState.playing));

      // Commit a seek to 30.0 seconds
      const seekTarget = Duration(seconds: 30);
      await adapter.seek(seekTarget);

      // Wait for position to jump to ~30s and continue advancing
      sw.reset();
      while (positions.last < const Duration(seconds: 29)) {
        if (sw.elapsedMilliseconds > 10000) {
          fail('Seek to 30s did not advance within 10s. Current: ${positions.last}');
        }
        await Future.delayed(const Duration(milliseconds: 200));
      }

      expect(positions.last.inSeconds, greaterThanOrEqualTo(29));
      expect(adapter.state, equals(PlayerPlaybackState.playing));

      await sub.cancel();
      await adapter.stop();
      await adapter.dispose();
    });
  });
}
