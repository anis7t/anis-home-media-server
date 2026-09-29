import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/player/presentation/player_screen.dart';

import 'player_screen_test.dart' show FakePlayerController;

/// The cast button hands a file to a TV, so it needs to know the file name. The
/// details screen passes one, but a deep link (route /player + mediaUrl) does not -
/// the name has to come out of the media URL instead, or casting would silently be
/// unavailable exactly when the player is opened directly.
void main() {
  late FakePlayerController controller;

  setUp(() => controller = FakePlayerController());

  Future<void> pumpPlayer(
    WidgetTester tester, {
    String? mediaFilename,
    required String mediaUrl,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: PlayerScreen(
            mediaUrl: mediaUrl,
            mediaFilename: mediaFilename,
            title: 'Batman Knightfall Part 1 (2026)',
            subtitle: 'Direct MP4 • 1080p',
            deviceId: 'dev_test',
            customController: controller,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('offers casting when the file name arrives with the media URL', (tester) async {
    await pumpPlayer(tester, mediaUrl: 'http://127.0.0.1:8000/media/Some%20Movie.mp4');

    expect(find.byTooltip('Cast to device'), findsOneWidget);
  });

  testWidgets('offers casting for an HLS URL too', (tester) async {
    await pumpPlayer(tester, mediaUrl: 'http://127.0.0.1:8000/hls/Some%20Movie/playlist.m3u8');

    expect(find.byTooltip('Cast to device'), findsOneWidget);
  });

  testWidgets('an explicitly passed file name still wins', (tester) async {
    await pumpPlayer(
      tester,
      mediaFilename: 'Explicit Name.mp4',
      mediaUrl: 'http://127.0.0.1:8000/media/Some%20Movie.mp4',
    );

    expect(find.byTooltip('Cast to device'), findsOneWidget);
  });

  testWidgets('offers no casting when nothing identifies a file', (tester) async {
    await pumpPlayer(tester, mediaUrl: 'http://127.0.0.1:8000/not-media/x');

    expect(find.byTooltip('Cast to device'), findsNothing);
  });
}