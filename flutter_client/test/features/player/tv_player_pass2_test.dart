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

class _FakeTvPass2PlayerController implements PlayerControllerInterface {
  Duration _position = const Duration(minutes: 5);
  final Duration _duration = const Duration(minutes: 90);
  PlayerPlaybackState _state = PlayerPlaybackState.playing;
  final bool _isBuffering = false;
  final double _rate = 1.0;
  double _volume = 80.0;
  final PlayerTrackInfo _trackInfo = const PlayerTrackInfo();

  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _stateController = StreamController<PlayerPlaybackState>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  final _tracksController = StreamController<PlayerTrackInfo>.broadcast();
  final _dimensionsController = StreamController<VideoDimensions>.broadcast();

  bool playCalled = false;
  bool pauseCalled = false;
  bool stopCalled = false;
  bool setVolumeCalled = false;
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

  @override
  Future<void> open(String url, {Map<String, String>? headers, Duration? startPosition, String? externalSubtitleUrl}) async {}
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
    _state = PlayerPlaybackState.idle;
    _stateController.add(_state);
  }
  @override
  Future<void> seek(Duration position) async {
    lastSeekTarget = position;
    _position = position;
    _positionController.add(_position);
  }
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {
    setVolumeCalled = true;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeTvPass2PlayerController controller;

  setUp(() {
    controller = _FakeTvPass2PlayerController();
  });

  tearDown(() async {
    await controller.dispose();
  });

  const tvCapabilities = DeviceCapabilities(
    isTv: true,
    isAmazonFireTv: true,
    hasTouchscreen: false,
    hasLeanbackFeature: true,
    model: 'AFTMM',
    manufacturer: 'Amazon',
  );

  Widget createTvPlayerApp() {
    return ProviderScope(
      overrides: [
        deviceCapabilitiesProvider.overrideWithValue(tvCapabilities),
      ],
      child: MaterialApp(
        home: PlayerScreen(
          mediaUrl: 'http://127.0.0.1:8000/media/test.mp4',
          title: 'Pass 2 TV Player Test',
          deviceId: 'dev_tv_test',
          customController: controller,
        ),
      ),
    );
  }

  group('TV Player Pass 2: 2-Zone Focus & Remote Invariants', () {
    testWidgets('D-pad Up and Down do NOT alter volume on TV', (tester) async {
      await tester.pumpWidget(createTvPlayerApp());
      await tester.pump(const Duration(milliseconds: 100));

      final initialVolume = controller.volume;

      // Send D-pad Up
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 100));

      // Send D-pad Down
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 100));

      // Volume should remain untouched because Fire TV remote has dedicated volume hardware
      expect(controller.setVolumeCalled, isFalse);
      expect(controller.volume, initialVolume);
    });

    testWidgets('Aspect Ratio button is rendered within controls row on TV', (tester) async {
      await tester.pumpWidget(createTvPlayerApp());
      await tester.pump(const Duration(milliseconds: 100));

      // In TV mode, Aspect Ratio button should be visible in PlayerControlsOverlay
      expect(find.byTooltip('Aspect Ratio'), findsOneWidget);
    });

    testWidgets('Multi-tier Back state machine unwinds Zone 2 -> Zone 1 -> hidden -> exit', (tester) async {
      await tester.pumpWidget(createTvPlayerApp());
      await tester.pump(const Duration(milliseconds: 100));

      // 1. Controls are visible initially, Zone is timeline (Zone 1)
      final overlay1 = tester.widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay));
      expect(overlay1.isVisible, isTrue);
      expect(overlay1.isTimelineFocused, isTrue);

      // 2. Press ArrowDown to enter controls row (Zone 2)
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 100));

      final overlay2 = tester.widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay));
      expect(overlay2.isTimelineFocused, isFalse);
      expect(overlay2.tvFocusedControlIndex, greaterThanOrEqualTo(0));

      // 3. Press Back / Escape key: should unwind from Zone 2 back to Zone 1 (timeline)
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 100));

      final overlay3 = tester.widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay));
      expect(overlay3.isVisible, isTrue);
      expect(overlay3.isTimelineFocused, isTrue);

      // 4. Press Back / Escape again: should hide controls overlay
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 100));

      final overlay4 = tester.widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay));
      expect(overlay4.isVisible, isFalse);
      expect(controller.stopCalled, isFalse);

      // 5. Press Back / Escape with controls hidden: stops player & exits
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 100));

      expect(controller.stopCalled, isTrue);
    });
  });
}
