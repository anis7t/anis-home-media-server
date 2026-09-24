import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player/domain/player_controller_interface.dart';
import 'package:media_server_client/features/player/presentation/player_screen.dart';
import 'package:media_server_client/features/player/presentation/widgets/player_controls_overlay.dart';
import 'package:media_server_client/features/player/presentation/widgets/player_error_card.dart';
import 'package:media_server_client/features/player/presentation/widgets/player_loading_indicator.dart';

class FakePlayerController implements PlayerControllerInterface {
  Duration _position = Duration.zero;
  Duration _duration = const Duration(minutes: 90);
  PlayerPlaybackState _state = PlayerPlaybackState.idle;
  bool _isBuffering = false;
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
  bool disposeCalled = false;

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

  void emitBuffering(bool b) {
    _isBuffering = b;
    _bufferingController.add(b);
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
    disposeCalled = true;
    await _positionController.close();
    await _durationController.close();
    await _stateController.close();
    await _bufferingController.close();
    await _tracksController.close();
    await _dimensionsController.close();
  }
}

void main() {
  group('Phase 3A: Production PlayerScreen Widget Tests', () {
    late FakePlayerController controller;

    setUp(() {
      controller = FakePlayerController();
    });

    testWidgets('renders loading state initially during opening', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: PlayerScreen(
              mediaUrl: 'http://127.0.0.1:8000/media/test.mp4',
              title: 'Batman Knightfall Part 1 (2026)',
              subtitle: 'Direct MP4 • 1080p',
              deviceId: 'dev_test',
              customController: controller,
            ),
          ),
        ),
      );

      // Verify loading indicator is present
      expect(find.byType(PlayerLoadingIndicator), findsOneWidget);
      expect(find.text('Loading Media'), findsOneWidget);
      expect(find.text('Batman Knightfall Part 1 (2026)'), findsOneWidget);
    });

    testWidgets('transitions to playing state and renders controls overlay', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: PlayerScreen(
              mediaUrl: 'http://127.0.0.1:8000/media/test.mp4',
              title: 'Batman Knightfall Part 1 (2026)',
              subtitle: 'Direct MP4 • 1080p',
              deviceId: 'dev_test',
              customController: controller,
            ),
          ),
        ),
      );

      // Transition to playing
      controller.emitState(PlayerPlaybackState.playing);
      controller.emitPosition(const Duration(minutes: 5));
      controller.emitDuration(const Duration(minutes: 90));
      await tester.pumpAndSettle();

      // Loading indicator disappears
      expect(find.byType(PlayerLoadingIndicator), findsNothing);

      // Controls overlay is present
      expect(find.byType(PlayerControlsOverlay), findsOneWidget);
      expect(find.text('Batman Knightfall Part 1 (2026)'), findsOneWidget);
      expect(find.text('Direct MP4 • 1080p'), findsOneWidget);
      expect(find.text('5:00 / 1:30:00'), findsOneWidget);

      // Toggle play/pause button
      final pauseButton = find.byTooltip('Pause (Space / k)');
      expect(pauseButton, findsOneWidget);
      await tester.tap(pauseButton);
      await tester.pump();

      expect(controller.pauseCalled, isTrue);
    });

    testWidgets('renders PlayerErrorCard on error state with retry action', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: PlayerScreen(
              mediaUrl: 'http://127.0.0.1:8000/media/test.mp4',
              title: 'Batman Knightfall Part 1 (2026)',
              deviceId: 'dev_test',
              customController: controller,
            ),
          ),
        ),
      );

      // Emit error
      controller.emitState(PlayerPlaybackState.error);
      await tester.pumpAndSettle();

      expect(find.byType(PlayerErrorCard), findsOneWidget);
      expect(find.text('Playback Encountered an Error'), findsOneWidget);

      // Tap retry
      final retryBtn = find.text('Retry');
      expect(retryBtn, findsOneWidget);
      await tester.tap(retryBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Controller should transition back to opening
      expect(controller.state, PlayerPlaybackState.opening);
    });

    testWidgets('toggles fullscreen via button and keyboard shortcut F', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: PlayerScreen(
              mediaUrl: 'http://127.0.0.1:8000/media/test.mp4',
              title: 'Batman Knightfall Part 1 (2026)',
              deviceId: 'dev_test',
              customController: controller,
            ),
          ),
        ),
      );

      controller.emitState(PlayerPlaybackState.playing);
      await tester.pumpAndSettle();

      // Find bottom fullscreen button
      final fsButtons = find.byTooltip('Fullscreen (f)');
      expect(fsButtons, findsWidgets);

      // Tap fullscreen button to enter fullscreen
      await tester.tap(fsButtons.first);
      await tester.pumpAndSettle();

      // Tooltip should update to Exit Fullscreen
      expect(find.byTooltip('Exit Fullscreen (f)'), findsWidgets);

      // Press key 'F' to exit fullscreen
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();

      // Tooltip should revert to Fullscreen
      expect(find.byTooltip('Fullscreen (f)'), findsWidgets);

      // Press key 'F' to enter fullscreen again
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Exit Fullscreen (f)'), findsWidgets);

      // Press Escape to exit fullscreen
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Fullscreen (f)'), findsWidgets);
    });
  });
}
