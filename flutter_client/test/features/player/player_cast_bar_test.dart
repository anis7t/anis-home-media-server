import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/cast/data/models/cast_device.dart';
import 'package:media_server_client/features/cast/presentation/controllers/cast_controller.dart';
import 'package:media_server_client/features/player/presentation/player_screen.dart';

import 'player_screen_test.dart' show FakePlayerController;

/// The TV in this household refuses seeks (UPnP 701), so every cast started from a
/// resume point reports a seek refusal. That refusal used to replace the position in
/// the cast bar for the whole cast — the state matters more once playback is running.
class _FixedCastController extends CastController {
  _FixedCastController(this._fixed);

  final CastState _fixed;

  @override
  CastState build() => _fixed;

  @override
  Future<void> pollStatus() async {}

  @override
  Future<void> sendControl(String action, {double? value}) async {}
}

const _tv = CastDevice(id: 'dlna:1', name: 'TV', kind: 'dlna', model: 'UA43DU7000KLXL');
const _seekRefusal =
    'This device does not allow seeking from another app - use its own remote to jump ahead. (UPnP 701)';

void main() {
  Future<void> pumpCasting(WidgetTester tester, CastState state) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [castControllerProvider.overrideWith(() => _FixedCastController(state))],
        child: MaterialApp(
          home: PlayerScreen(
            mediaUrl: 'http://127.0.0.1:8000/media/Some%20Movie.mp4',
            title: 'Some Movie (2026)',
            subtitle: 'Direct MP4',
            deviceId: 'dev_test',
            customController: FakePlayerController(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('while the TV plays, the bar shows the position instead of an old refusal',
      (tester) async {
    await pumpCasting(
      tester,
      const CastState(
        activeDevice: _tv,
        playbackState: 'playing',
        position: Duration(minutes: 1, seconds: 5),
        error: _seekRefusal,
      ),
    );

    expect(find.textContaining('TV · 1:05'), findsOneWidget);
    expect(find.textContaining('does not allow seeking'), findsNothing);
  });

  testWidgets('when nothing is playing, the refusal is what the bar reports', (tester) async {
    await pumpCasting(
      tester,
      const CastState(
        activeDevice: _tv,
        playbackState: 'stopped',
        error: _seekRefusal,
      ),
    );

    expect(find.textContaining('does not allow seeking'), findsOneWidget);
  });

  testWidgets('a paused cast shows the paused position, not the refusal', (tester) async {
    await pumpCasting(
      tester,
      const CastState(
        activeDevice: _tv,
        playbackState: 'paused',
        position: Duration(minutes: 2),
        error: _seekRefusal,
      ),
    );

    expect(find.textContaining('Paused · 2:00'), findsOneWidget);
  });
}