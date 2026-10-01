import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:media_server_client/features/player/domain/player_controller_interface.dart';
import 'package:media_server_client/features/player/presentation/player_screen.dart';
import 'package:media_server_client/features/player/presentation/widgets/player_controls_overlay.dart';
import 'package:media_server_client/features/player/presentation/widgets/player_hud_toast.dart';
import 'package:media_server_client/features/player/presentation/widgets/player_loading_indicator.dart';

class _FakePlayerController implements PlayerControllerInterface {
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _stateController = StreamController<PlayerPlaybackState>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  final _tracksController = StreamController<PlayerTrackInfo>.broadcast();
  final _dimensionsController = StreamController<VideoDimensions>.broadcast();

  Duration _position = Duration.zero;
  Duration _duration = const Duration(minutes: 90);
  PlayerPlaybackState _state = PlayerPlaybackState.idle;
  bool _isBuffering = false;
  double _rate = 1.0;
  double _volume = 100.0;
  final PlayerTrackInfo _trackInfo = const PlayerTrackInfo();

  Duration? lastSeekTarget;
  int seekCallCount = 0;

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
    _state = PlayerPlaybackState.playing;
    _stateController.add(_state);
  }

  @override
  Future<void> pause() async {
    _state = PlayerPlaybackState.paused;
    _stateController.add(_state);
  }

  @override
  Future<void> seek(Duration position) async {
    seekCallCount++;
    lastSeekTarget = position;
    _position = position;
    _positionController.add(position);
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
  Future<void> setSubtitleTrack(PlayerSubtitleTrack track) async {}

  @override
  Future<void> setAudioTrack(PlayerAudioTrack track) async {}

  @override
  Future<void> stop() async {
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

  group('PlaybackOverlayStatus Domain Tests', () {
    test('initial none status has correct properties', () {
      const status = PlaybackOverlayStatus.none;
      expect(status.type, equals(PlaybackOverlayType.none));
      expect(status.isNone, isTrue);
      expect(status.isVisible, isFalse);
      expect(status.isOpening, isFalse);
      expect(status.isBuffering, isFalse);
      expect(status.isSeeking, isFalse);
      expect(status.isToast, isFalse);
    });

    test('seeking status provides active indicators', () {
      const status = PlaybackOverlayStatus(
        type: PlaybackOverlayType.seeking,
        message: '+10 sec',
        icon: Icons.fast_forward_rounded,
      );
      expect(status.isSeeking, isTrue);
      expect(status.isVisible, isTrue);
      expect(status.message, equals('+10 sec'));
      expect(status.icon, equals(Icons.fast_forward_rounded));
    });

    test('equality and hashCode contract', () {
      const a = PlaybackOverlayStatus(
        type: PlaybackOverlayType.buffering,
        message: 'Buffering Stream',
      );
      const b = PlaybackOverlayStatus(
        type: PlaybackOverlayType.buffering,
        message: 'Buffering Stream',
      );
      const c = PlaybackOverlayStatus(
        type: PlaybackOverlayType.opening,
        message: 'Loading Media',
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });

  group('Phase 4: Coordinated Playback Overlay State Machine Widget Tests', () {
    late _FakePlayerController controller;

    setUp(() {
      controller = _FakePlayerController();
    });

    Widget buildTestPlayer() {
      return ProviderScope(
        child: MaterialApp(
          home: PlayerScreen(
            mediaUrl: 'http://127.0.0.1:8000/media/test.mp4',
            title: 'Batman Knightfall Part 1 (2026)',
            subtitle: 'Direct MP4 • 1080p',
            deviceId: 'dev_test',
            customController: controller,
          ),
        ),
      );
    }

    testWidgets('1. Opening state displays Loading Media and suppresses HUD toast', (tester) async {
      await tester.pumpWidget(buildTestPlayer());
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(PlayerLoadingIndicator), findsOneWidget);
      expect(find.text('Loading Media'), findsOneWidget);

      // HUD toast must be invisible
      final hudToast = tester.widget<PlayerHudToast>(find.byType(PlayerHudToast));
      expect(hudToast.isVisible, isFalse);
    });

    testWidgets('2. Transition from Opening to Playing dismisses loading indicator immediately', (tester) async {
      await tester.pumpWidget(buildTestPlayer());
      await tester.pump(const Duration(milliseconds: 100));

      controller.emitState(PlayerPlaybackState.playing);
      controller.emitPosition(const Duration(seconds: 30));
      await tester.pump();

      expect(find.byType(PlayerLoadingIndicator), findsNothing);
    });

    testWidgets('3. Spontaneous Buffering during playback renders Buffering Stream without HUD toast', (tester) async {
      await tester.pumpWidget(buildTestPlayer());
      await tester.pump(const Duration(milliseconds: 100));

      controller.emitState(PlayerPlaybackState.playing);
      await tester.pump();
      expect(find.byType(PlayerLoadingIndicator), findsNothing);

      // Stream starves
      controller.emitBuffering(true);
      await tester.pump();

      expect(find.byType(PlayerLoadingIndicator), findsOneWidget);
      expect(find.text('Buffering Stream'), findsOneWidget);

      final hudToast = tester.widget<PlayerHudToast>(find.byType(PlayerHudToast));
      expect(hudToast.isVisible, isFalse);
    });

    testWidgets('4. Buffering clears immediately upon bufferingStream false without lingering', (tester) async {
      await tester.pumpWidget(buildTestPlayer());
      await tester.pump(const Duration(milliseconds: 100));

      controller.emitState(PlayerPlaybackState.playing);
      controller.emitBuffering(true);
      await tester.pump();
      expect(find.text('Buffering Stream'), findsOneWidget);

      // Buffering resolves
      controller.emitBuffering(false);
      await tester.pump();

      expect(find.byType(PlayerLoadingIndicator), findsNothing);
      expect(find.text('Buffering Stream'), findsNothing);
    });

    testWidgets('5. Seeking suppresses Buffering Stream and displays seek feedback exclusively', (tester) async {
      await tester.pumpWidget(buildTestPlayer());
      await tester.pump(const Duration(milliseconds: 100));

      controller.emitState(PlayerPlaybackState.playing);
      controller.emitPosition(const Duration(seconds: 60));
      await tester.pump();

      // Trigger relative seek (+10s) via D-pad Right / arrow Right
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      // Player backend emits buffering in response to seek
      controller.emitBuffering(true);
      await tester.pump();

      // Seek HUD must be visible with "+10 sec"
      expect(find.text('+10 sec'), findsOneWidget);
      final hudToast = tester.widget<PlayerHudToast>(find.byType(PlayerHudToast));
      expect(hudToast.isVisible, isTrue);

      // CRITICAL: PlayerLoadingIndicator must NOT be rendered (suppressed during seeking)
      expect(find.byType(PlayerLoadingIndicator), findsNothing);
      expect(find.text('Buffering Stream'), findsNothing);

      // Drain seek settle timer
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('6. Rapid successive seeks accumulate delta (+10s -> +20s -> +30s) in a single overlay', (tester) async {
      await tester.pumpWidget(buildTestPlayer());
      await tester.pump(const Duration(milliseconds: 100));

      controller.emitState(PlayerPlaybackState.playing);
      controller.emitPosition(const Duration(seconds: 100));
      await tester.pump();

      // 1st seek
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.text('+10 sec'), findsOneWidget);

      // 2nd seek 200ms later
      await tester.pump(const Duration(milliseconds: 200));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.text('+20 sec'), findsOneWidget);

      // 3rd seek 200ms later
      await tester.pump(const Duration(milliseconds: 200));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.text('+30 sec'), findsOneWidget);

      // Exactly one PlayerHudToast widget rendered (no stacking)
      expect(find.byType(PlayerHudToast), findsOneWidget);
      expect(find.byType(PlayerLoadingIndicator), findsNothing);

      // Drain seek settle timer
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('7. Seek settle window transitions cleanly to normal playback when stream is ready', (tester) async {
      await tester.pumpWidget(buildTestPlayer());
      await tester.pump(const Duration(milliseconds: 100));

      controller.emitState(PlayerPlaybackState.playing);
      controller.emitPosition(const Duration(seconds: 50));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.text('+10 sec'), findsOneWidget);

      // Stream completes buffering before settle window expires
      controller.emitBuffering(false);
      await tester.pump();

      // Wait out 1000ms settle timer
      await tester.pump(const Duration(milliseconds: 1100));

      final hudToast = tester.widget<PlayerHudToast>(find.byType(PlayerHudToast));
      expect(hudToast.isVisible, isFalse);
      expect(find.byType(PlayerLoadingIndicator), findsNothing);
    });

    testWidgets('8. Seek settle transitions smoothly to Buffering Stream if buffer is still starved', (tester) async {
      await tester.pumpWidget(buildTestPlayer());
      await tester.pump(const Duration(milliseconds: 100));

      controller.emitState(PlayerPlaybackState.playing);
      controller.emitPosition(const Duration(seconds: 50));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.text('+10 sec'), findsOneWidget);

      // Player backend remains buffering (e.g. transcode / network delay)
      controller.emitBuffering(true);
      await tester.pump();

      // Wait out 1000ms settle timer
      await tester.pump(const Duration(milliseconds: 1100));

      // After seek settles, if buffering persists, it transitions smoothly to Buffering Stream
      expect(find.byType(PlayerLoadingIndicator), findsOneWidget);
      expect(find.text('Buffering Stream'), findsOneWidget);
      final hudToast = tester.widget<PlayerHudToast>(find.byType(PlayerHudToast));
      expect(hudToast.isVisible, isFalse);
    });

    testWidgets('9. Center Play/Pause button in controls overlay is suppressed during active overlay', (tester) async {
      await tester.pumpWidget(buildTestPlayer());
      await tester.pump(const Duration(milliseconds: 100));

      controller.emitState(PlayerPlaybackState.playing);
      controller.emitPosition(const Duration(seconds: 50));
      await tester.pump();

      // Normal playback with controls visible shows Center Play/Pause (large size >= 36)
      expect(
        find.byWidgetPredicate((w) =>
            w is Icon && w.icon == Icons.pause_rounded && (w.size ?? 0) >= 36),
        findsOneWidget,
        reason: 'Center play/pause button must be visible when controls are open with no overlay',
      );

      // Trigger seek -> overlay active
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      // Center play/pause MUST be suppressed while seek overlay is active
      expect(
        find.byWidgetPredicate((w) =>
            w is Icon &&
            (w.icon == Icons.pause_rounded || w.icon == Icons.play_arrow_rounded) &&
            (w.size ?? 0) >= 36),
        findsNothing,
        reason: 'Center play/pause button must be suppressed while seek overlay is active',
      );
      expect(find.text('+10 sec'), findsOneWidget);

      // Drain seek settle timer
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('10. Timeline scrubbing suppresses buffering indicator to prevent viewport obstruction', (tester) async {
      await tester.pumpWidget(buildTestPlayer());
      await tester.pump(const Duration(milliseconds: 100));

      controller.emitState(PlayerPlaybackState.playing);
      controller.emitPosition(const Duration(seconds: 50));
      await tester.pump();

      // Access controls overlay scrubbing callback
      final overlay = tester.widget<PlayerControlsOverlay>(find.byType(PlayerControlsOverlay));
      overlay.onScrubbingChanged?.call(true);
      await tester.pump();

      // Simulate buffering event while user is dragging scrubber
      controller.emitBuffering(true);
      await tester.pump();

      // Buffering indicator must NOT be displayed over the user's scrub gesture
      expect(find.byType(PlayerLoadingIndicator), findsNothing);

      // End scrubbing
      overlay.onScrubbingChanged?.call(false);
      await tester.pump();

      // Now that scrubbing ended, if still buffering, buffering stream appears
      expect(find.byType(PlayerLoadingIndicator), findsOneWidget);
      expect(find.text('Buffering Stream'), findsOneWidget);
    });
  });
}
