import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/library/data/models/movie_item.dart';
import 'package:media_server_client/features/library/presentation/widgets/continue_watching_rail.dart';

void main() {
  group('ContinueWatchingRail Widget', () {
    const movie1 = MovieItem(
      filename: 'movie1.mp4',
      title: 'Movie One',
      percent: 30.0,
      position: 1800,
    );
    const movie2 = MovieItem(
      filename: 'movie2.mp4',
      title: 'Movie Two',
      percent: 65.0,
      position: 4200,
    );

    testWidgets('renders header and movie cards', (tester) async {
      MovieItem? tappedMovie;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContinueWatchingRail(
              movies: const [movie1, movie2],
              baseUrl: 'http://127.0.0.1:8000',
              onMovieTap: (m) => tappedMovie = m,
            ),
          ),
        ),
      );

      expect(find.text('Continue Watching'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Movie One'), findsOneWidget);
      expect(find.text('Movie Two'), findsOneWidget);

      await tester.tap(find.text('Movie One'));
      expect(tappedMovie?.filename, 'movie1.mp4');
    });

    testWidgets('renders empty shrink widget when list is empty',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContinueWatchingRail(
              movies: const [],
              baseUrl: 'http://127.0.0.1:8000',
              onMovieTap: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('Continue Watching'), findsNothing);
      expect(find.byType(SizedBox), findsWidgets);
    });
  });
}
