import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_server_gate.dart';

void main() {
  final serverOrigin = liveServerOrigin;
  const testDeviceId = 'dev_poc_test_3896e0';

  final dio = Dio(
    BaseOptions(
      baseUrl: serverOrigin,
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 10),
      headers: {
        'X-Device-Id': testDeviceId,
      },
    ),
  );

  group('HTTP Streaming & Playback Contracts (Automated Integration)', () {
    test('Direct Playback: RFC 7233 byte-range request returns 206 with correct Content-Range', () async {
      const filename = 'Batman Knightfall Part 1 2026 1080p WEBRip x264 AAC5 1-[YTS GG - YTS BZ].mp4';
      final encoded = Uri.encodeComponent(filename);

      final response = await dio.get<ResponseBody>(
        '/media/$encoded',
        options: Options(
          headers: {'Range': 'bytes=0-1023'},
          responseType: ResponseType.stream,
        ),
      );

      expect(response.statusCode, HttpStatus.partialContent); // 206
      expect(response.headers.value('accept-ranges'), 'bytes');
      final contentRange = response.headers.value('content-range');
      expect(contentRange, isNotNull);
      expect(contentRange, startsWith('bytes 0-1023/'));
      expect(response.headers.value('content-length'), '1024');
    });

    test('Direct Playback: Mid-stream seeking byte-range request', () async {
      const filename = 'Batman Knightfall Part 1 2026 1080p WEBRip x264 AAC5 1-[YTS GG - YTS BZ].mp4';
      final encoded = Uri.encodeComponent(filename);

      final response = await dio.get<ResponseBody>(
        '/media/$encoded',
        options: Options(
          headers: {'Range': 'bytes=10000000-10004095'},
          responseType: ResponseType.stream,
        ),
      );

      expect(response.statusCode, HttpStatus.partialContent); // 206
      final contentRange = response.headers.value('content-range');
      expect(contentRange, isNotNull);
      expect(contentRange, startsWith('bytes 10000000-10004095/'));
      expect(response.headers.value('content-length'), '4096');
    });

    test('HLS Playback: Master playlist returns 200 with valid M3U8 tags', () async {
      const filename = 'Coyote.vs.Acme.2026.1080p.HEVC.x265.RMTeam.mkv';
      final encoded = Uri.encodeComponent(filename);

      final response = await dio.get<String>('/hls/$encoded/playlist.m3u8');

      expect(response.statusCode, HttpStatus.ok);
      final body = response.data!;
      expect(body, contains('#EXTM3U'));
      expect(body, contains('#EXTINF'));
      expect(body, contains('.ts'));
    });

    test('Sidecar Subtitles: WebVTT route delivers valid VTT file with X-Device-Id', () async {
      const movieFilename = 'The End Of Oak Street 2026 1080p WEB-DL HEVC x265 10Bit DDP5.1 Subs KINGDOM_RG/The End Of Oak Street 2026 1080p WEB-DL HEVC x265 10Bit DDP5.1 Subs KINGDOM.mkv';
      const subFilename = 'the_end_of_oak_street_en_1.srt';
      final encodedMovie = Uri.encodeComponent(movieFilename);
      final encodedSub = Uri.encodeComponent(subFilename);

      final response = await dio.get<String>('/subtitles/$encodedMovie/$encodedSub');

      expect(response.statusCode, HttpStatus.ok);
      expect(response.data, contains('WEBVTT'));
    });

    test('Seek-Preview: API delivers metadata and valid JPEG frame thumbnail', () async {
      const filename = 'Batman Knightfall Part 1 2026 1080p WEBRip x264 AAC5 1-[YTS GG - YTS BZ].mp4';
      final encoded = Uri.encodeComponent(filename);

      // 1. Meta endpoint
      final metaRes = await dio.get<Map<String, dynamic>>('/api/seek-preview-meta/$encoded');
      expect(metaRes.statusCode, HttpStatus.ok);
      final meta = metaRes.data!;
      expect(meta.containsKey('duration'), isTrue);
      expect(meta.containsKey('interval'), isTrue);
      expect(meta.containsKey('count'), isTrue);
      expect(meta['count'], greaterThan(0));

      // 2. First thumbnail frame
      final thumbRes = await dio.get<List<int>>(
        '/seek-preview/$encoded/thumb_00000.jpg',
        options: Options(responseType: ResponseType.bytes),
      );
      expect(thumbRes.statusCode, HttpStatus.ok);
      expect(thumbRes.headers.value('content-type'), contains('image/jpeg'));
      expect(thumbRes.data!.length, greaterThan(100)); // Non-empty JPEG bytes
    });

    test('Watch Progress: the payload the app sends is persisted and readable back', () async {
      const filename = 'Batman Knightfall Part 1 2026 1080p WEBRip x264 AAC5 1-[YTS GG - YTS BZ].mp4';
      final encoded = Uri.encodeComponent(filename);
      const deviceId = 'dev_live_contract_test';

      // Read the live row first so the operator's real resume point is restored.
      final before = await dio.get<Map<String, dynamic>>(
        '/api/progress?filename=$encoded',
        options: Options(headers: {'X-Device-Id': deviceId}),
      );
      expect(before.statusCode, HttpStatus.ok);
      final originalPosition = (before.data!['position'] as num).toDouble();
      final originalDuration = (before.data!['duration'] as num).toDouble();

      try {
        // Exactly what the app's player now posts on pause / every 10s / teardown.
        final post = await dio.post<Map<String, dynamic>>(
          '/api/progress',
          data: <String, dynamic>{
            'filename': filename,
            'position': 1234.5,
            'duration': 7200.0,
          },
          options: Options(headers: {'X-Device-Id': deviceId}),
        );
        expect(post.statusCode, HttpStatus.ok);
        expect(post.data!['success'], isTrue);

        final after = await dio.get<Map<String, dynamic>>(
          '/api/progress?filename=$encoded',
          options: Options(headers: {'X-Device-Id': deviceId}),
        );
        expect((after.data!['position'] as num).toDouble(), closeTo(1234.5, 0.001));
        expect((after.data!['duration'] as num).toDouble(), closeTo(7200.0, 0.001));

        // The movie list is what the app reads on open - the same row must feed it.
        final movies = await dio.get<Map<String, dynamic>>(
          '/api/movies',
          options: Options(headers: {'X-Device-Id': deviceId}),
        );
        expect(movies.statusCode, HttpStatus.ok);
        final entry = (movies.data!['movies'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .firstWhere((m) => m['filename'] == filename);
        expect((entry['position'] as num).toDouble(), closeTo(1234.5, 0.001),
            reason: 'the resume point the app shows must come from this write');
      } finally {
        await dio.post<Map<String, dynamic>>(
          '/api/progress',
          data: <String, dynamic>{
            'filename': filename,
            'position': originalPosition,
            'duration': originalDuration,
          },
          options: Options(headers: {'X-Device-Id': deviceId}),
        );
      }
    });
  }, skip: liveServerSkip);
}
