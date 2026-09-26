import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/library/data/models/movie_item.dart';
import 'package:media_server_client/features/library/presentation/widgets/movie_card.dart';

void main() {
  group('MovieCard Widget', () {
    testWidgets('renders title, year, and runtime correctly', (tester) async {
      const movie = MovieItem(
        filename: 'batman.mp4',
        title: 'Batman Knightfall',
        year: 2026,
        runtime: 114,
        rating: 8.5,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 160,
              height: 260,
              child: MovieCard(
                movie: movie,
                baseUrl: 'http://127.0.0.1:8000',
              ),
            ),
          ),
        ),
      );

      expect(find.text('Batman Knightfall'), findsOneWidget);
      expect(find.text('2026'), findsOneWidget);
      expect(find.text('1h 54m'), findsOneWidget);
      expect(find.text('8.5'), findsOneWidget);
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    });

    testWidgets('renders fallback artwork when poster is null', (tester) async {
      const movie = MovieItem(
        filename: 'unknown.mp4',
        title: 'Unknown Flick',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 160,
              height: 260,
              child: MovieCard(
                movie: movie,
                baseUrl: 'http://127.0.0.1:8000',
              ),
            ),
          ),
        ),
      );

      expect(find.text('Unknown Flick'), findsOneWidget);
      // Fallback initial 'U' is displayed
      expect(find.text('U'), findsOneWidget);
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    });

    testWidgets('renders progress bar when percent > 0', (tester) async {
      const movie = MovieItem(
        filename: 'watching.mp4',
        title: 'In Progress Movie',
        percent: 45.0,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 160,
              height: 260,
              child: MovieCard(
                movie: movie,
                baseUrl: 'http://127.0.0.1:8000',
                showProgress: true,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(FractionallySizedBox), findsOneWidget);
      final fractionalBox =
          tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox));
      expect(fractionalBox.widthFactor, 0.45);
    });

    testWidgets('fires onTap callback on card tap', (tester) async {
      var tapped = false;
      const movie = MovieItem(
        filename: 'tap.mp4',
        title: 'Tap Movie',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 160,
              height: 260,
              child: MovieCard(
                movie: movie,
                baseUrl: 'http://127.0.0.1:8000',
                onTap: () => tapped = true,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Tap Movie'));
      expect(tapped, isTrue);
    });
  });
}
