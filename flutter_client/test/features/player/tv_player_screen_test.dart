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

class _FakePlayerController implements PlayerControllerInterface {
  Duration _position = Duration.zero;
  final Duration _duration = const Duration(minutes: 90);
  PlayerPlaybackState _state = PlayerPlaybackState.idle;
  final bool _isBuffering = false;
  double _rate = 1.0;
  double _volume = 80.0;
  PlayerTrackInfo _trackInfo = const PlayerTrackInfo();

  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _stateController = StreamController<PlayerPlaybackState>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  final _tracksController = StreamController<PlayerTrackInfo>.broadcast();
  final _dimensionsController = StreamController<VideoDimensions>.broadcast();

  bool playCalled = false;
  bool pauseCalled = false;
  bool stopCalled = false;

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

  @override
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Duration? startPosition,
    String? externalSubtitleUrl,
  }) async {
    _state = PlayerPlaybackState.opening;
    _stateController.add(_state);
    if (startPosition != null) {
      _position = startPosition;
      _positionController.add(_position);
    }
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
  Future<void> seek(Duration position) async {
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
  Future<void> setSubtitleTrack(PlayerSubtitleTrack track) async {
    _trackInfo = PlayerTrackInfo(
      subtitleTracks: _trackInfo.subtitleTracks,
      currentSubtitleTrack: track,
      audioTracks: _trackInfo.audioTracks,
      currentAudioTrack: _trackInfo.currentAudioTrack,
    );
    _tracksController.add(_trackInfo);
  }

  @override
  Future<void> setAudioTrack(PlayerAudioTrack track) async {
    _trackInfo = PlayerTrackInfo(
      subtitleTracks: _trackInfo.subtitleTracks,
      currentSubtitleTrack: _trackInfo.currentSubtitleTrack,
      audioTracks: _trackInfo.audioTracks,
      currentAudioTrack: track,
    );
    _tracksController.add(_trackInfo);
  }

  @override
  Future<void> stop() async {
    stopCalled = true;
    _state = PlayerPlaybackState.idle;
    _stateController.add(_state);
  }

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

  late _FakePlayerController controller;

  setUp(() {
    controller = _FakePlayerController();
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
          title: 'Batman Knightfall Part 1 (2026)',
          deviceId: 'dev_test',
          customController: controller,
        ),
      ),
    );
  }

  group('TV Player Invariants & Remote Back State Machine Tests', () {
    testWidgets('TV mode enforces borderless fullscreen and omits mobile split view', (tester) async {
      await tester.pumpWidget(createTvPlayerApp());
      controller.emitState(PlayerPlaybackState.playing);
      await tester.pumpAndSettle();

      // In TV mode, the mobile split view (AspectRatio 16/10.5 and details column) should NOT exist
      expect(find.byType(AspectRatio), findsNothing);
      // Fullscreen scaffold background should be black
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, Colors.black);
    });

    testWidgets('TV mode hides Cast button and Fullscreen toggle button', (tester) async {
      await tester.pumpWidget(createTvPlayerApp());
      controller.emitState(PlayerPlaybackState.playing);
      await tester.pumpAndSettle();

      // Cast button must be absent on TV
      expect(find.byIcon(Icons.cast_rounded), findsNothing);
      expect(find.byIcon(Icons.cast_connected_rounded), findsNothing);

      // Fullscreen button must be absent on TV
      expect(find.byTooltip('Fullscreen (f)'), findsNothing);
      expect(find.byTooltip('Exit Fullscreen (f)'), findsNothing);
    });

    testWidgets('TV remote Back key when controls are hidden reveals controls and keeps playback active', (tester) async {
      await tester.pumpWidget(createTvPlayerApp());
      controller.emitState(PlayerPlaybackState.playing);
      await tester.pumpAndSettle();

      // Fast-forward past auto-hide timer (4s) so controls become hidden
      await tester.pump(const Duration(seconds: 5));
      final overlayHidden = tester.widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay));
      expect(overlayHidden.isVisible, isFalse);

      // Press Back key (escape / goBack) with controls hidden
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // Controls should now be revealed, focus restored to timeline, controller NOT stopped
      expect(controller.stopCalled, isFalse);
      final overlayRevealed = tester.widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay));
      expect(overlayRevealed.isVisible, isTrue);
      expect(overlayRevealed.isTimelineFocused, isTrue);
    });

    testWidgets('TV remote Back key when controls are visible stops controller and exits', (tester) async {
      await tester.pumpWidget(createTvPlayerApp());
      controller.emitState(PlayerPlaybackState.playing);
      await tester.pumpAndSettle();

      // Initially controls overlay should be visible
      expect(find.byType(PlayerControlsOverlay), findsOneWidget);
      final overlay1 = tester.widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay));
      expect(overlay1.isVisible, isTrue);

      // Press Back key (escape / goBack) with controls visible
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 100));

      // Controller should be stopped and progress flushed
      expect(controller.stopCalled, isTrue);
    });
  });
}
