import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/device/domain/device_capabilities.dart';
import 'package:media_server_client/core/device/infrastructure/device_capability_service.dart';
import 'package:media_server_client/features/player/domain/player_controller_interface.dart';
import 'package:media_server_client/features/player/presentation/player_screen.dart';
import 'package:media_server_client/features/player/presentation/widgets/player_controls_overlay.dart';
import 'package:media_server_client/features/player/presentation/widgets/track_selector_sheet.dart';

class RemoteTestPlayerController implements PlayerControllerInterface {
  Duration _position = const Duration(minutes: 10);
  Duration _duration = const Duration(minutes: 90);
  PlayerPlaybackState _state = PlayerPlaybackState.idle;
  final bool _isBuffering = false;
  double _rate = 1.0;
  double _volume = 80.0;
  final PlayerTrackInfo _trackInfo = const PlayerTrackInfo(
    subtitleTracks: [
      PlayerSubtitleTrack(id: 'no', title: 'Off', isDefault: false),
      PlayerSubtitleTrack(id: 'en_1', title: 'English', language: 'en', isDefault: true),
    ],
  );

  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _stateController = StreamController<PlayerPlaybackState>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  final _tracksController = StreamController<PlayerTrackInfo>.broadcast();
  final _dimensionsController = StreamController<VideoDimensions>.broadcast();

  bool playCalled = false;
  bool pauseCalled = false;
  bool stopCalled = false;
  Duration? lastSeekTarget;

  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  PlayerPlaybackState get state => _state;
  @override
  bool get isBuffering => _isBuffering;
  @override
  double get rate => _rate;
  @override
  double get volume => _volume;
  @override
  VideoDimensions get dimensions => const VideoDimensions(1920, 1080);
  @override
  PlayerTrackInfo get trackInfo => _trackInfo;

  @override
  Stream<Duration> get positionStream => _positionController.stream;
  @override
  Stream<Duration> get durationStream => _durationController.stream;
  @override
  Stream<PlayerPlaybackState> get stateStream => _stateController.stream;
  @override
  Stream<bool> get bufferingStream => _bufferingController.stream;
  @override
  Stream<PlayerTrackInfo> get tracksStream => _tracksController.stream;
  @override
  Stream<VideoDimensions> get dimensionsStream => _dimensionsController.stream;

  void emitState(PlayerPlaybackState s) {
    _state = s;
    _stateController.add(s);
  }

  void emitPosition(Duration p) {
    _position = p;
    _positionController.add(p);
  }

  void emitDuration(Duration d) {
    _duration = d;
    _durationController.add(d);
  }

  @override
  Future<void> open(String url, {Map<String, String>? headers, Duration? startPosition, String? externalSubtitleUrl}) async {
    _state = PlayerPlaybackState.playing;
    _stateController.add(_state);
    _durationController.add(_duration);
    _positionController.add(_position);
  }

  @override
  Future<void> play() async {
    playCalled = true;
    _state = PlayerPlaybackState.playing;
    _stateController.add(_state);
  }

  @override
  Future<void> pause() async {
    pauseCalled = true;
    _state = PlayerPlaybackState.paused;
    _stateController.add(_state);
  }

  @override
  Future<void> stop() async {
    stopCalled = true;
  }

  @override
  Future<void> seek(Duration position) async {
    lastSeekTarget = position;
    _position = position;
    _positionController.add(_position);
  }

  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
  }

  @override
  Future<void> setAudioTrack(PlayerAudioTrack track) async {}

  @override
  Future<void> setSubtitleTrack(PlayerSubtitleTrack track) async {}

  @override
  Future<void> dispose() async {
    await _positionController.close();
    await _durationController.close();
    await _stateController.close();
    await _bufferingController.close();
    await _tracksController.close();
    await _dimensionsController.close();
  }
}

Widget createTestApp(PlayerControllerInterface controller) {
  return ProviderScope(
    overrides: [
      deviceCapabilitiesProvider.overrideWithValue(DeviceCapabilities.tvDefault),
    ],
    child: MaterialApp(
      home: PlayerScreen(
        mediaUrl: 'http://127.0.0.1:8000/media/test.mp4',
        title: 'Test Movie',
        customController: controller,
      ),
    ),
  );
}

void main() {
  group('Fire TV Stick 4K Remote Controls Tests', () {
    testWidgets('mediaPlayPause key toggles play/pause', (tester) async {
      final controller = RemoteTestPlayerController();
      await tester.pumpWidget(createTestApp(controller));
      controller.emitState(PlayerPlaybackState.playing);
      controller.emitPosition(const Duration(minutes: 10));
      controller.emitDuration(const Duration(minutes: 90));
      await tester.pump(const Duration(milliseconds: 100));

      // Controller is currently playing, mediaPlayPause should pause
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.pauseCalled, isTrue);

      // Reset and send again, should play
      controller.playCalled = false;
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.playCalled, isTrue);
    });

    testWidgets('mediaRewind and mediaFastForward keys seek -15s and +15s', (tester) async {
      final controller = RemoteTestPlayerController();
      await tester.pumpWidget(createTestApp(controller));
      controller.emitState(PlayerPlaybackState.playing);
      controller.emitPosition(const Duration(minutes: 10));
      controller.emitDuration(const Duration(minutes: 90));
      await tester.pump(const Duration(milliseconds: 100));

      // Rewind 15s from 10 minutes (600s -> 585s)
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaRewind);
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.lastSeekTarget, const Duration(seconds: 585));

      // Fast forward 15s from 585s -> 600s
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaFastForward);
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.lastSeekTarget, const Duration(seconds: 600));
    });

    testWidgets('arrowLeft and arrowRight keys scrub timeline and Select commits seek', (tester) async {
      final controller = RemoteTestPlayerController();
      await tester.pumpWidget(createTestApp(controller));
      controller.emitState(PlayerPlaybackState.playing);
      controller.emitPosition(const Duration(minutes: 10));
      controller.emitDuration(const Duration(minutes: 90));
      await tester.pump(const Duration(milliseconds: 100));

      // D-Pad Left: scrubs -10s from 600s -> 590s, Select commits seek
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.lastSeekTarget, const Duration(seconds: 590));

      // D-Pad Right: scrubs +10s from 590s -> 600s, Select commits seek
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.lastSeekTarget, const Duration(seconds: 600));
    });

    testWidgets('D-Pad Select key reveals controls when hidden and toggles play when visible', (tester) async {
      final controller = RemoteTestPlayerController();
      await tester.pumpWidget(createTestApp(controller));
      controller.emitState(PlayerPlaybackState.playing);
      controller.emitPosition(const Duration(minutes: 10));
      controller.emitDuration(const Duration(minutes: 90));
      await tester.pump(const Duration(milliseconds: 100));

      // Wait for auto-hide (3.5s timer)
      await tester.pump(const Duration(seconds: 4));
      expect(
        tester.widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay)).isVisible,
        isFalse,
      );

      // First Select press: wakes up controls
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay)).isVisible,
        isTrue,
      );

      // Second Select press when visible: toggles pause
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.pauseCalled, isTrue);
    });

    testWidgets('contextMenu key (Fire TV remote Menu button ☰) opens subtitle track sheet', (tester) async {
      final controller = RemoteTestPlayerController();
      await tester.pumpWidget(createTestApp(controller));
      controller.emitState(PlayerPlaybackState.playing);
      controller.emitPosition(const Duration(minutes: 10));
      controller.emitDuration(const Duration(minutes: 90));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(SubtitleTrackSheet), findsNothing);

      // Press Menu key
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byType(SubtitleTrackSheet), findsOneWidget);
    });

    testWidgets('Back / Escape key exits when controls are visible', (tester) async {
      final controller = RemoteTestPlayerController();
      await tester.pumpWidget(createTestApp(controller));
      controller.emitState(PlayerPlaybackState.playing);
      controller.emitPosition(const Duration(minutes: 10));
      controller.emitDuration(const Duration(minutes: 90));
      await tester.pump(const Duration(milliseconds: 100));

      // Controls are initially visible
      expect(
        tester.widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay)).isVisible,
        isTrue,
      );

      // Press Back / Escape key with controls visible -> exits player
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 100));

      expect(controller.stopCalled, isTrue);
    });

    testWidgets('Back / Escape key reveals controls when hidden without stopping playback', (tester) async {
      final controller = RemoteTestPlayerController();
      await tester.pumpWidget(createTestApp(controller));
      controller.emitState(PlayerPlaybackState.playing);
      controller.emitPosition(const Duration(minutes: 10));
      controller.emitDuration(const Duration(minutes: 90));
      await tester.pump(const Duration(milliseconds: 100));

      // Wait for auto-hide
      await tester.pump(const Duration(seconds: 5));
      expect(
        tester.widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay)).isVisible,
        isFalse,
      );

      // Press Back / Escape key when controls are hidden
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 100));

      // Controls should now be visible and playback still active
      expect(
        tester.widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay)).isVisible,
        isTrue,
      );
      expect(controller.stopCalled, isFalse);
    });
  });
}
