import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player/domain/player_models.dart';
import 'package:media_server_client/features/player/presentation/widgets/playback_speed_sheet.dart';
import 'package:media_server_client/features/player/presentation/widgets/track_selector_sheet.dart';

void main() {
  group('PlaybackSpeedSheet Widget Tests', () {
    testWidgets('renders all supported speeds and highlights active rate', (tester) async {
      double selectedRate = 0.0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackSpeedSheet(
              currentRate: 1.25,
              onRateSelected: (rate) => selectedRate = rate,
            ),
          ),
        ),
      );

      expect(find.text('Playback Speed'), findsOneWidget);
      expect(find.text('0.5×'), findsOneWidget);
      expect(find.text('0.75×'), findsOneWidget);
      expect(find.text('1.0× (Normal)'), findsOneWidget);
      expect(find.text('1.25×'), findsOneWidget);
      expect(find.text('1.5×'), findsOneWidget);
      expect(find.text('2×'), findsOneWidget);

      // Verify active checkmark is present
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);

      // Tap 1.5x
      await tester.tap(find.text('1.5×'));
      await tester.pumpAndSettle();

      expect(selectedRate, equals(1.5));
    });
  });

  group('AudioTrackSheet Widget Tests', () {
    testWidgets('renders audio tracks with channel metadata and handles selection', (tester) async {
      PlayerAudioTrack? selectedTrack;

      const tracks = [
        PlayerAudioTrack(
          id: '1',
          title: 'English',
          language: 'eng',
          channels: '5.1(side)',
          codec: 'eac3',
        ),
        PlayerAudioTrack(
          id: '2',
          title: 'Hindi',
          language: 'hin',
          channels: 'stereo',
          codec: 'aac',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AudioTrackSheet(
              tracks: tracks,
              currentTrack: tracks[0],
              onTrackSelected: (t) => selectedTrack = t,
            ),
          ),
        ),
      );

      expect(find.text('Audio Tracks'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('5.1(side) • EAC3'), findsOneWidget);
      expect(find.text('Hindi'), findsOneWidget);
      expect(find.text('stereo • AAC'), findsOneWidget);

      // Tap Hindi track
      await tester.tap(find.text('Hindi'));
      await tester.pumpAndSettle();

      expect(selectedTrack?.id, equals('2'));
    });
  });

  group('SubtitleTrackSheet Widget Tests', () {
    testWidgets('renders Off option, embedded tracks, and local sidecars', (tester) async {
      PlayerSubtitleTrack? selectedTrack;

      const tracks = [
        PlayerSubtitleTrack.no,
        PlayerSubtitleTrack(
          id: '1',
          title: 'English [Embedded]',
          language: 'eng',
          isExternal: false,
        ),
        PlayerSubtitleTrack(
          id: 'http://127.0.0.1:8000/subtitles/movie.mp4/sub.srt',
          title: 'Spanish (Local)',
          language: 'es',
          isExternal: true,
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubtitleTrackSheet(
              tracks: tracks,
              currentTrack: tracks[1],
              onTrackSelected: (t) => selectedTrack = t,
            ),
          ),
        ),
      );

      expect(find.text('Subtitles'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('English [Embedded]'), findsOneWidget);
      expect(find.text('Spanish (Local)'), findsOneWidget);
      expect(find.text('Local'), findsOneWidget); // External badge

      // Tap Spanish track
      await tester.tap(find.text('Spanish (Local)'));
      await tester.pumpAndSettle();

      expect(selectedTrack?.id, equals('http://127.0.0.1:8000/subtitles/movie.mp4/sub.srt'));
      expect(selectedTrack?.isExternal, isTrue);
    });
  });
}
