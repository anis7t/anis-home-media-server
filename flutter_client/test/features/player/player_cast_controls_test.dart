import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/features/cast/data/models/cast_device.dart';
import 'package:media_server_client/features/cast/data/repositories/cast_repository.dart';
import 'package:media_server_client/features/cast/presentation/controllers/cast_controller.dart';
import 'package:media_server_client/features/player/domain/player_controller_interface.dart';
import 'package:media_server_client/features/player/presentation/player_screen.dart';
import 'package:media_server_client/features/player/presentation/widgets/player_controls_overlay.dart';

import 'player_screen_test.dart' show FakePlayerController;

/// Reported symptom: "no matter at what time position I start casting it casts from the
/// beginning, and seeking on the phone or play/pause does nothing on the casted video".
///
/// A Cast receiver is controlled by whoever loaded the media, so the phone has to forward
/// its transport commands whenever a TV owns playback - the local player stays paused for
/// the whole cast and must not be what the controls drive.

const _tv = CastDevice(id: 'cast:72d252f1', name: 'TV', kind: 'cast', model: 'DU7000');

/// Records every command the phone sends to the TV; touches no network and no state.
class _RecordingCastController extends CastController {
  _RecordingCastController(this._fixed);

  final CastState _fixed;
  final List<RecordedControl> sent = [];

  @override
  CastState build() => _fixed;

  @override
  Future<void> pollStatus() async {}

  @override
  Future<void> sendControl(String action, {double? value}) async {
    sent.add(RecordedControl(action, value));
  }
}

class RecordedControl {
  const RecordedControl(this.action, this.value);

  final String action;
  final double? value;

  @override
  String toString() => '$action($value)';
}

Future<PlayerControlsOverlay> _pumpPlayer(
  WidgetTester tester, {
  required _RecordingCastController cast,
  required FakePlayerController player,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [castControllerProvider.overrideWith(() => cast)],
      child: MaterialApp(
        home: PlayerScreen(
          mediaUrl: 'http://127.0.0.1:8000/media/Some%20Movie.mp4',
          title: 'Some Movie (2026)',
          subtitle: 'Direct MP4',
          deviceId: 'dev_test',
          customController: player,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return tester.widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay));
}

void main() {
  testWidgets('while casting, play/pause drives the TV and not the local player',
      (tester) async {
    final player = FakePlayerController();
    final cast = _RecordingCastController(
      const CastState(activeDevice: _tv, playbackState: 'playing'),
    );
    final overlay = await _pumpPlayer(tester, cast: cast, player: player);

    overlay.onTogglePlay();
    await tester.pump();

    expect(cast.sent.map((c) => c.action), ['pause'],
        reason: 'the TV is what the viewer is watching');
    expect(player.pauseCalled, isFalse,
        reason: 'the local player is deliberately paused during a cast');
  });

  testWidgets('while casting, the button offers play again once the TV is paused',
      (tester) async {
    final player = FakePlayerController();
    final cast = _RecordingCastController(
      const CastState(activeDevice: _tv, playbackState: 'paused'),
    );
    final overlay = await _pumpPlayer(tester, cast: cast, player: player);

    expect(overlay.isPlaying, isFalse, reason: 'the bar must show the cast state');

    overlay.onTogglePlay();
    await tester.pump();

    expect(cast.sent.map((c) => c.action), ['play']);
    expect(player.playCalled, isFalse);
  });

  testWidgets('a scrub on the phone seeks the TV, and the bar tracks the TV',
      (tester) async {
    final player = FakePlayerController();
    final cast = _RecordingCastController(
      const CastState(
        activeDevice: _tv,
        playbackState: 'playing',
        position: Duration(minutes: 5),
        duration: Duration(minutes: 78, seconds: 37),
      ),
    );
    final overlay = await _pumpPlayer(tester, cast: cast, player: player);

    // the controls read as a remote for the TV, not as the paused local player
    expect(overlay.position, const Duration(minutes: 5));
    expect(overlay.duration, const Duration(minutes: 78, seconds: 37));
    expect(overlay.isPlaying, isTrue);

    overlay.onSeek(const Duration(seconds: 600));
    await tester.pump();

    expect(cast.sent.single.action, 'seek');
    expect(cast.sent.single.value, 600.0);
    expect(player.position, isNot(const Duration(seconds: 600)),
        reason: 'the local player must not be scrubbed while a TV owns playback');
  });

  testWidgets('restart while casting rewinds the TV', (tester) async {
    final player = FakePlayerController();
    final cast = _RecordingCastController(
      const CastState(
        activeDevice: _tv,
        playbackState: 'playing',
        position: Duration(minutes: 42),
      ),
    );
    final overlay = await _pumpPlayer(tester, cast: cast, player: player);

    overlay.onRestart!();
    await tester.pump();

    expect(cast.sent.single.action, 'seek');
    expect(cast.sent.single.value, 0.0);
  });

  testWidgets('without a cast the same controls still drive the local player',
      (tester) async {
    final player = FakePlayerController();
    final cast = _RecordingCastController(const CastState());

    final overlay = await _pumpPlayer(tester, cast: cast, player: player);
    player.emitState(PlayerPlaybackState.playing);
    await tester.pump();

    overlay.onTogglePlay();
    await tester.pump();
    overlay.onSeek(const Duration(seconds: 42));
    await tester.pump();

    expect(player.pauseCalled, isTrue);
    expect(player.position, const Duration(seconds: 42));
    expect(cast.sent, isEmpty, reason: 'nothing may reach a device when there is no cast');
  });

  group('CastController', () {
    /// The local player is not running during a cast, so the bar would otherwise sit
    /// frozen between 5-second polls while the viewer scrubs.
    test('a seek is reflected immediately and a play/pause flips the shown state', () async {
      final requested = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8000'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requested.add(options);
            handler.resolve(Response(requestOptions: options, statusCode: 200, data: {'ok': true}));
          },
        ),
      );
      final container = ProviderContainer(
        overrides: [
          castRepositoryProvider.overrideWithValue(
            CastRepository(
              ApiClient(
                baseUrl: 'http://127.0.0.1:8000',
                authInterceptor: _PassthroughAuthInterceptor(),
                customDio: dio,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(castControllerProvider.notifier);
      await controller.castTo(_tv, 'Some Movie.mp4');
      expect(controller.state.isCasting, isTrue);

      await controller.sendControl('seek', value: 600);
      expect(controller.state.position, const Duration(minutes: 10));

      await controller.sendControl('pause');
      expect(controller.state.playbackState, 'paused');
      await controller.sendControl('play');
      expect(controller.state.playbackState, 'playing');

      expect(requested.map((r) => r.path), [
        '/api/cast/play',
        '/api/cast/control',
        '/api/cast/control',
        '/api/cast/control',
      ]);
    });
  });
}

/// DeviceAuthInterceptor needs secure storage, which a unit test has no platform for;
/// the cast calls under test do not depend on the device header.
class _PassthroughAuthInterceptor extends DeviceAuthInterceptor {
  _PassthroughAuthInterceptor() : super(DeviceIdentityService());

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    handler.next(options);
  }
}