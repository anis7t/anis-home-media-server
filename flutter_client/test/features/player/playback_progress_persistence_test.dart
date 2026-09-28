import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player/domain/player_controller_interface.dart';
import 'package:media_server_client/features/player/presentation/player_screen.dart';
import 'package:media_server_client/features/player/presentation/widgets/player_controls_overlay.dart';

import '../../support/recording_player_controller.dart';

/// End-to-end regression for the resume-position bug.
///
/// Reported symptom: "no matter to which time I play and watch, when I go back
/// the resume time stays the same" — the app only ever *read* the position, so
/// the row only changed when the web player wrote it. This drives the real
/// [PlayerScreen] with a recording controller and asserts the HTTP calls it now
/// makes to `/api/progress`.
const String _origin = 'http://192.168.1.16:8000';
const String _filename = 'Batman Knightfall Part 1 2026 1080p WEBRip x264 AAC5 1.mp4';

class _RecordedProgress {
  _RecordedProgress(this.url, this.body);
  final String url;
  final Map<String, dynamic> body;
}

/// Dio that answers `/api/media-info/<file>` (the bootstrap probe) and records
/// every `/api/progress` POST the player sends. Everything else 404s, which the
/// player treats as non-fatal.
Dio _recordingDio(List<_RecordedProgress> recorded, {bool directPlay = true}) {
  final dio = Dio(BaseOptions(baseUrl: _origin));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final path = options.uri.path;
        if (path.startsWith('/api/progress')) {
          recorded.add(_RecordedProgress(
            options.uri.toString(),
            Map<String, dynamic>.from(options.data as Map? ?? const {}),
          ));
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{'success': true},
            ),
          );
          return;
        }
        if (path.startsWith('/api/media-info/')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{'direct_play': directPlay, 'title': 'Test Movie'},
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

Widget _buildPlayer(
  Dio dio,
  RecordingPlayerController controller, {
  String? mediaFilename = _filename,
}) =>
    ProviderScope(
      child: MaterialApp(
        home: PlayerScreen(
          mediaUrl: '$_origin/media/${Uri.encodeComponent(_filename)}',
          title: 'Test Movie',
          deviceId: 'dev_test',
          mediaFilename: mediaFilename,
          customController: controller,
          customDio: dio,
        ),
      ),
    );

/// Drives the async bootstrap (authoritative-mode probe -> open) to completion.
Future<void> _bootAndPlay(WidgetTester tester, RecordingPlayerController controller) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  controller.emitState(PlayerPlaybackState.playing);
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('the player persists watch progress to /api/progress', (tester) async {
    final recorded = <_RecordedProgress>[];
    final controller = RecordingPlayerController();

    await tester.pumpWidget(_buildPlayer(_recordingDio(recorded), controller));
    await _bootAndPlay(tester, controller);

    controller.emitDuration(const Duration(minutes: 90));
    await tester.pump(const Duration(milliseconds: 50));

    // Opening at the saved resume point must not itself write progress.
    controller.emitPosition(const Duration(seconds: 600));
    await tester.pump(const Duration(milliseconds: 50));
    expect(recorded, isEmpty, reason: 'the first sample is a baseline, not progress');

    // 12s of playback crosses the 10s delta.
    controller.emitPosition(const Duration(seconds: 612));
    await tester.pump(const Duration(milliseconds: 50));
    expect(recorded, hasLength(1));
    expect(recorded.single.url, '$_origin/api/progress');
    expect(recorded.single.body['filename'], _filename);
    expect(recorded.single.body['position'], 612.0);
    expect(recorded.single.body['duration'], 5400.0);

    // 6s more is below the delta: still nothing.
    controller.emitPosition(const Duration(seconds: 618));
    await tester.pump(const Duration(milliseconds: 50));
    expect(recorded, hasLength(1));

    // Pausing writes immediately, the way the web player's `onpause` does.
    controller.emitState(PlayerPlaybackState.paused);
    await tester.pump(const Duration(milliseconds: 50));
    expect(recorded, hasLength(2));
    expect(recorded.last.body['position'], 618.0);

    // Leaving the player flushes once more without re-writing the same spot.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
    expect(recorded, hasLength(2));
  });

  testWidgets('reaching the end marks the title watched (position 0)', (tester) async {
    final recorded = <_RecordedProgress>[];
    final controller = RecordingPlayerController();

    await tester.pumpWidget(_buildPlayer(_recordingDio(recorded), controller));
    await _bootAndPlay(tester, controller);

    controller.emitDuration(const Duration(minutes: 90));
    // The end of the media: completion only marks a title watched from here, so
    // the position must sit at the end (a mid-file `completed` keeps the resume
    // point - see the reporter tests).
    controller.emitPosition(const Duration(seconds: 5395));
    await tester.pump(const Duration(milliseconds: 50));
    expect(recorded, isEmpty);

    controller.emitState(PlayerPlaybackState.completed);
    await tester.pump(const Duration(milliseconds: 50));

    expect(recorded, hasLength(1));
    expect(recorded.single.body['position'], 0.0,
        reason: '0 is how the server distinguishes watched from in-progress');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('a committed seek is persisted once the debounce settles', (tester) async {
    final recorded = <_RecordedProgress>[];
    final controller = RecordingPlayerController();

    await tester.pumpWidget(_buildPlayer(_recordingDio(recorded), controller));
    await _bootAndPlay(tester, controller);

    controller.emitDuration(const Duration(minutes: 90));
    controller.emitPosition(const Duration(seconds: 300));
    await tester.pump(const Duration(milliseconds: 50));
    expect(recorded, isEmpty);

    // Exactly what a drag-to-seek emits when the finger lifts: the screen's
    // `_onSeek` through the controls overlay. The seeked-to time reaches the
    // server at once (the player's position stream reports it) and the seek
    // debounce must not write the same spot a second time.
    final overlay = tester.widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay));
    overlay.onSeek(const Duration(seconds: 900));
    await tester.pump(const Duration(milliseconds: 50));
    expect(recorded, hasLength(1));
    expect(recorded.single.body['position'], 900.0,
        reason: 'the seeked-to time is what the server must offer as the resume point');

    await tester.pump(const Duration(seconds: 2));
    expect(recorded, hasLength(1), reason: 'the seek debounce must not duplicate the write');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
    expect(recorded, hasLength(1), reason: 'leaving right after the write must not duplicate it');
  });

  testWidgets('saves progress with the filename parsed from the media URL', (tester) async {
    // The router hands the player a `/media/<file>` URL; this is the path the
    // phone actually takes, so the filename must survive without being passed in.
    final recorded = <_RecordedProgress>[];
    final controller = RecordingPlayerController();

    await tester.pumpWidget(
      _buildPlayer(_recordingDio(recorded), controller, mediaFilename: null),
    );
    await _bootAndPlay(tester, controller);

    controller.emitDuration(const Duration(minutes: 90));
    controller.emitPosition(const Duration(seconds: 600));
    await tester.pump(const Duration(milliseconds: 50));
    controller.emitPosition(const Duration(seconds: 615));
    await tester.pump(const Duration(milliseconds: 50));

    expect(recorded, hasLength(1));
    expect(recorded.single.body['filename'], _filename,
        reason: 'the filename must be recovered from the URL when none is passed');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('saves progress for an HLS title using the playlist URL filename', (tester) async {
    // MKV titles stream as HLS: the URL the player is handed is the playlist,
    // and the filename the server stores progress under is the media file.
    const mkv =
        'The End Of Oak Street 2026 1080p WEB-DL HEVC x265 10Bit DDP5.1 Subs KINGDOM_RG/The End Of Oak Street 2026 1080p WEB-DL HEVC x265 10Bit DDP5.1 Subs KINGDOM.mkv';
    final recorded = <_RecordedProgress>[];
    final controller = RecordingPlayerController();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: PlayerScreen(
            mediaUrl: '$_origin/hls/${Uri.encodeComponent(mkv)}/playlist.m3u8',
            title: 'Test Movie',
            deviceId: 'dev_test',
            customController: controller,
            customDio: _recordingDio(recorded, directPlay: false),
          ),
        ),
      ),
    );
    await _bootAndPlay(tester, controller);

    controller.emitDuration(const Duration(minutes: 95));
    controller.emitPosition(const Duration(seconds: 1200));
    await tester.pump(const Duration(milliseconds: 50));
    controller.emitPosition(const Duration(seconds: 1215));
    await tester.pump(const Duration(milliseconds: 50));

    expect(recorded, hasLength(1));
    expect(recorded.single.body['filename'], mkv,
        reason: 'progress is keyed by the media file, not the playlist URL');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('leaving the player saves the watched position, not the 0 that stop() reports',
      (tester) async {
    final recorded = <_RecordedProgress>[];
    final controller = RecordingPlayerController();

    // A real route, so the player's back path can actually pop it.
    late BuildContext ctx;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    Navigator.of(ctx).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          mediaUrl: '$_origin/media/${Uri.encodeComponent(_filename)}',
          title: 'Test Movie',
          deviceId: 'dev_test',
          mediaFilename: _filename,
          customController: controller,
          customDio: _recordingDio(recorded),
        ),
      ),
    );
    // The player keeps animating (auto-hide timers), so pumpAndSettle would
    // never settle: pump the route transition explicitly instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _bootAndPlay(tester, controller);

    controller.emitDuration(const Duration(minutes: 78));
    controller.emitPosition(const Duration(seconds: 1600));
    await tester.pump(const Duration(milliseconds: 50));

    // Leave the player the way the user does: the overlay's back button.
    await tester.tap(find.byTooltip('Back'));
    await tester.pump(const Duration(milliseconds: 50));

    // media_kit's stop() resets the player to 0 - the sample the device saw
    // persisted as "watched", wiping a 160 s resume point.
    controller.emitPosition(Duration.zero);
    await tester.pump(const Duration(milliseconds: 50));

    expect(recorded, isNotEmpty, reason: 'leaving the player must save the position');
    expect(recorded.last.body['position'], 1600.0,
        reason: 'the exit save must be the watched position, not 0');
    expect(recorded.where((r) => r.body['position'] == 0.0), isEmpty,
        reason: 'a torn-down player is not a watched title');
  });
}
