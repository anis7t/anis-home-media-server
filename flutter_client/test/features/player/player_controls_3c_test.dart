import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player/presentation/widgets/player_controls_overlay.dart';
import 'package:media_server_client/features/player/presentation/widgets/player_hud_toast.dart';

void main() {
  group('PlayerControlsOverlay Phase 3C Controls Tests', () {
    testWidgets('renders Replay, Speed, Audio, Subtitle buttons and invokes callbacks', (tester) async {
      bool restarted = false;
      bool speedOpened = false;
      bool audioOpened = false;
      bool subtitleOpened = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 480,
              child: PlayerControlsOverlay(
                title: 'Test Movie',
                isVisible: true,
                isPlaying: true,
                isBuffering: false,
                position: const Duration(seconds: 45),
                duration: const Duration(minutes: 90),
                volume: 80,
                isFullscreen: false,
                playbackRate: 1.25,
                hasActiveSubtitles: true,
                onTogglePlay: () {},
                onVolumeChanged: (_) {},
                onToggleMute: () {},
                onToggleFullscreen: () {},
                onBack: () {},
                onUserInteraction: () {},
                onSeek: (_) {},
                onRestart: () => restarted = true,
                onOpenSpeedSheet: () => speedOpened = true,
                onOpenAudioSheet: () => audioOpened = true,
                onOpenSubtitleSheet: () => subtitleOpened = true,
              ),
            ),
          ),
        ),
      );

      // Verify buttons
      expect(find.byIcon(Icons.replay_rounded), findsOneWidget);
      expect(find.text('1.25×'), findsOneWidget);
      expect(find.byIcon(Icons.audiotrack_rounded), findsOneWidget);
      expect(find.byIcon(Icons.subtitles_rounded), findsOneWidget);

      // Tap Replay
      await tester.tap(find.byIcon(Icons.replay_rounded));
      expect(restarted, isTrue);

      // Tap Speed
      await tester.tap(find.text('1.25×'));
      expect(speedOpened, isTrue);

      // Tap Audio
      await tester.tap(find.byIcon(Icons.audiotrack_rounded));
      expect(audioOpened, isTrue);

      // Tap Subtitles
      await tester.tap(find.byIcon(Icons.subtitles_rounded));
      expect(subtitleOpened, isTrue);
    });

    testWidgets('responsive layout hides volume slider on compact widths (< 620)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400, // Compact mobile width
              height: 700,
              child: PlayerControlsOverlay(
                title: 'Compact View',
                isVisible: true,
                isPlaying: true,
                isBuffering: false,
                position: Duration.zero,
                duration: const Duration(minutes: 60),
                volume: 50,
                isFullscreen: false,
                onTogglePlay: () {},
                onVolumeChanged: (_) {},
                onToggleMute: () {},
                onToggleFullscreen: () {},
                onBack: () {},
                onUserInteraction: () {},
                onSeek: (_) {},
              ),
            ),
          ),
        ),
      );

      // Volume slider should NOT be present on < 620dp width
      expect(find.byType(Slider), findsNothing);
      // Mute button should still be present
      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
    });
  });

  group('PlayerHudToast Tests', () {
    testWidgets('renders message and icon when visible', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PlayerHudToast(
              message: '1.5× Speed',
              icon: Icons.speed_rounded,
              isVisible: true,
            ),
          ),
        ),
      );

      expect(find.text('1.5× Speed'), findsOneWidget);
      expect(find.byIcon(Icons.speed_rounded), findsOneWidget);
    });

    testWidgets('hides when isVisible is false', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PlayerHudToast(
              message: 'Hidden Toast',
              isVisible: false,
            ),
          ),
        ),
      );

      final animatedOpacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(animatedOpacity.opacity, equals(0.0));
    });
  });
}
