import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/device/domain/device_capabilities.dart';
import 'package:media_server_client/core/device/infrastructure/device_capability_service.dart';
import 'package:media_server_client/features/library/data/models/movie_item.dart';
import 'package:media_server_client/features/library/presentation/screens/movie_details_screen.dart';

void main() {
  const dummyMovie = MovieItem(
    filename: 'The.Matrix.1999.mkv',
    title: 'The Matrix',
    year: 1999,
    duration: 8160.0,
    position: 0.0,
    overview: 'A computer hacker learns from mysterious rebels about the true nature of his reality.',
  );

  group('MovieDetailsScreen TV vs Mobile Layout & Autofocus Tests', () {
    testWidgets('TV mode renders 2-column TV layout and autofocuses primary Play button', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceCapabilitiesProvider.overrideWithValue(DeviceCapabilities.tvDefault),
          ],
          child: const MaterialApp(
            home: MovieDetailsScreen(initialMovie: dummyMovie),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Check TV-specific back button is rendered
      expect(find.byKey(const ValueKey('tv_details_back_btn')), findsOneWidget);
      expect(find.byKey(const ValueKey('movie_details_back_btn')), findsNothing);

      // Verify primary play button is present and focused
      final playButtonFinder = find.byKey(const ValueKey('primary_play_button'));
      expect(playButtonFinder, findsOneWidget);

      final button = tester.widget<ElevatedButton>(playButtonFinder);
      expect(button.autofocus, isTrue);
    });

    testWidgets('Mobile mode renders standard mobile layout with autofocus false', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceCapabilitiesProvider.overrideWithValue(DeviceCapabilities.mobileDefault),
          ],
          child: const MaterialApp(
            home: MovieDetailsScreen(initialMovie: dummyMovie),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Check mobile back button is rendered
      expect(find.byKey(const ValueKey('movie_details_back_btn')), findsOneWidget);
      expect(find.byKey(const ValueKey('tv_details_back_btn')), findsNothing);

      // Verify primary play button has autofocus false
      final playButtonFinder = find.byKey(const ValueKey('primary_play_button'));
      expect(playButtonFinder, findsOneWidget);

      final button = tester.widget<ElevatedButton>(playButtonFinder);
      expect(button.autofocus, isFalse);
    });
  });
}
