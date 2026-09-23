import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const serverOrigin = 'http://127.0.0.1:8000';
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
      const filename = 'Spider-Man- Brand New Day 2026.1080p.HQ Pre.Multi.AAC 2.0.x264.mkv';
      final encoded = Uri.encodeComponent(filename);

      final response = await dio.get<String>('/hls/$encoded/playlist.m3u8');

      expect(response.statusCode, HttpStatus.ok);
      final body = response.data!;
      expect(body, contains('#EXTM3U'));
      expect(body, contains('#EXTINF'));
      expect(body, contains('.ts'));
    });

    test('Sidecar Subtitles: WebVTT route delivers valid VTT file with X-Device-Id', () async {
      const movieFilename = 'Lust Stories 3 2026.1080p.NF.WEB-DL.Multi.DD+ 5.1.x264-KIN.mkv';
      const subFilename = 'lust_stories_3_en_1.srt';
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
  });
}
