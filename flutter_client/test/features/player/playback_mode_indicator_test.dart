import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player/domain/player_controller_interface.dart';
import 'package:media_server_client/features/player/domain/playback_mode.dart';
import 'package:media_server_client/features/player/presentation/player_screen.dart';

import '../../support/recording_player_controller.dart';

/// Regression tests for the playback-mode indicator.
///
/// The player used to derive its DIRECT PLAY / HLS STREAM badge from a display
/// subtitle (`subtitle.contains('direct')`), so every real movie - whose
/// subtitle is "2026 • 1h 43m" - was labelled HLS STREAM even while it was
/// streamed directly over `/media/` byte ranges. The indicator must now come
/// from the server's authoritative `direct_play` value and must match the URL
/// the player actually opens.
const String _origin = 'http://192.168.1.16:8000';

/// Dio whose `/api/media-info/<file>` reply carries the server's authoritative
/// `direct_play` flag. Every other request 404s, which the player treats as
/// non-fatal.
Dio _mediaInfoDio({
  Object? directPlay,
  int status = 200,
  List<String>? record,
  Dio? base,
}) {
  final dio = base ?? Dio(BaseOptions(baseUrl: _origin));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        record?.add(options.uri.toString());
        if (options.path.contains('/api/media-info/')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: status,
              data: <String, dynamic>{
                'direct_play': directPlay,
                'title': 'Test Movie',
              },
            ),
          );
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 404,
            data: <String, dynamic>{},
          ),
        );
      },
    ),
  );
  return dio;
}

Widget _buildPlayer({
  required String mediaUrl,
  required String? subtitle,
  required Dio dio,
  required RecordingPlayerController controller,
}) {
  return ProviderScope(
    child: MaterialApp(
      home: PlayerScreen(
        mediaUrl: mediaUrl,
        title: 'Test Movie',
        subtitle: subtitle,
        deviceId: 'dev_test',
        customController: controller,
        customDio: dio,
      ),
    ),
  );
}

/// Matches a `RichText` span by its plain text - the stream-spec table renders
/// its label/value pairs with `RichText`, which `find.text` does not match.
/// Offstage is allowed because the table sits below the fold of the details
/// panel, which is a `SingleChildScrollView` (all rows are built).
Finder _richText(String value) => find.byWidgetPredicate(
      (widget) => widget is RichText && widget.text.toPlainText() == value,
      description: 'RichText "$value"',
      skipOffstage: false,
    );

/// Drives the async bootstrap (authoritative-mode probe -> open) to completion.
///
/// `pumpAndSettle` is unusable here: the loading indicator animates until the
/// stream reports `playing`, so the tree never reaches a settled frame.
Future<void> _bootAndPlay(
  WidgetTester tester,
  RecordingPlayerController controller,
) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  controller.emitState(PlayerPlaybackState.playing);
  await tester.pump(const Duration(milliseconds: 50));
  // Fire the controls auto-hide timer so no timer outlives the test.
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  group('PlaybackMode.fromDirectPlay maps the authoritative server flag', () {
    test('true -> directPlay', () {
      expect(PlaybackMode.fromDirectPlay(true), PlaybackMode.directPlay);
    });

    test('false -> hls', () {
      expect(PlaybackMode.fromDirectPlay(false), PlaybackMode.hls);
    });

    test('missing / non-bool values stay unknown instead of guessing', () {
      expect(PlaybackMode.fromDirectPlay(null), PlaybackMode.unknown);
      expect(PlaybackMode.fromDirectPlay('true'), PlaybackMode.unknown);
      expect(PlaybackMode.fromDirectPlay(1), PlaybackMode.unknown);
    });
  });

  group('Player playback-mode indicator follows the server, not the subtitle', () {
    testWidgets('direct-play MP4: DIRECT PLAY badge and byte-range URL',
        (tester) async {
      final controller = RecordingPlayerController();
      await tester.pumpWidget(
        _buildPlayer(
          mediaUrl: '$_origin/media/Batman%20Knightfall.mp4',
          subtitle: '2026 • 1h 19m',
          dio: _mediaInfoDio(directPlay: true),
          controller: controller,
        ),
      );
      await _bootAndPlay(tester, controller);

      expect(controller.openedUrl, '$_origin/media/Batman%20Knightfall.mp4');
      expect(find.text('DIRECT PLAY'), findsOneWidget);
      // The spec table sits below the fold of the details panel.
      expect(_richText('Direct Stream (RFC 7233)'), findsOneWidget);
      expect(find.text('HLS STREAM'), findsNothing);
    });

    testWidgets('HLS-advertised MKV: HLS STREAM badge and HLS playlist URL',
        (tester) async {
      final controller = RecordingPlayerController();
      await tester.pumpWidget(
        _buildPlayer(
          mediaUrl: '$_origin/media/The%20Odyssey%202026.mkv',
          subtitle: '2026 • 1h 43m',
          dio: _mediaInfoDio(directPlay: false),
          controller: controller,
        ),
      );
      await _bootAndPlay(tester, controller);

      expect(
        controller.openedUrl,
        '$_origin/hls/The%20Odyssey%202026.mkv/playlist.m3u8',
      );
      expect(find.text('HLS STREAM'), findsOneWidget);
      expect(_richText('HLS Segmented'), findsOneWidget);
      expect(find.text('DIRECT PLAY'), findsNothing);
    });

    testWidgets('a cold-start client is pointed at the player origin before probing',
        (tester) async {
      // A cold start (direct-intent launch) leaves the shared client on the
      // default 127.0.0.1 origin; the probe would then miss the real server and
      // the mode would stay unknown forever.
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8000'));
      final requested = <String>[];
      _mediaInfoDio(directPlay: true, record: requested, base: dio);
      final controller = RecordingPlayerController();

      await tester.pumpWidget(
        _buildPlayer(
          mediaUrl: '$_origin/media/Batman%20Knightfall.mp4',
          subtitle: '2026 • 1h 43m',
          dio: dio,
          controller: controller,
        ),
      );
      await _bootAndPlay(tester, controller);

      expect(dio.options.baseUrl, _origin);
      final probes =
          requested.where((u) => u.contains('/api/media-info/')).toList();
      expect(probes, hasLength(1));
      expect(probes.single, contains('$_origin/api/media-info/'));
      expect(find.text('DIRECT PLAY'), findsOneWidget);
    });

    testWidgets('a display subtitle containing "direct" cannot override the server',
        (tester) async {
      final controller = RecordingPlayerController();
      await tester.pumpWidget(
        _buildPlayer(
          // The old heuristic read this string and claimed DIRECT PLAY.
          mediaUrl: '$_origin/media/The%20Odyssey%202026.mkv',
          subtitle: 'Direct MP4 • 1080p • AAC 5.1',
          dio: _mediaInfoDio(directPlay: false),
          controller: controller,
        ),
      );
      await _bootAndPlay(tester, controller);

      expect(find.text('HLS STREAM'), findsOneWidget);
      expect(find.text('DIRECT PLAY'), findsNothing);
      expect(
        controller.openedUrl,
        '$_origin/hls/The%20Odyssey%202026.mkv/playlist.m3u8',
      );
    });

    testWidgets('no authoritative value: neutral badge, URL left untouched',
        (tester) async {
      final controller = RecordingPlayerController();
      await tester.pumpWidget(
        _buildPlayer(
          mediaUrl: '$_origin/media/Batman%20Knightfall.mp4',
          subtitle: 'Direct MP4 • 1080p • AAC 5.1',
          // 500 is not accepted by the player's media-info probe.
          dio: _mediaInfoDio(status: 500),
          controller: controller,
        ),
      );
      await _bootAndPlay(tester, controller);

      expect(controller.openedUrl, '$_origin/media/Batman%20Knightfall.mp4');
      expect(find.text('STREAM'), findsOneWidget);
      expect(_richText('Unknown (server mode unavailable)'), findsOneWidget);
      expect(find.text('DIRECT PLAY'), findsNothing);
      expect(find.text('HLS STREAM'), findsNothing);
    });
  });
}
