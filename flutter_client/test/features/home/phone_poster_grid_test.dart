import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/home/presentation/widgets/genre_rail_widget.dart';
import 'package:media_server_client/features/library/domain/models/movie_item.dart';
import 'package:media_server_client/features/library/presentation/widgets/movie_card.dart';

void main() {
  for (final width in [320.0, 360.0, 430.0]) {
    testWidgets('phone poster grid fits three full cards at ${width}dp', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final movies = List.generate(
        5,
        (index) => MovieItem(filename: '$index.mp4', title: 'Movie $index'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: GenreRailWidget(
                title: 'Drama',
                movies: movies,
                baseUrl: 'http://localhost',
                phoneLayout: true,
                onMovieTap: (_) {},
              ),
            ),
          ),
        ),
      );

      final grid = tester.widget<GridView>(find.byType(GridView));
      final delegate =
          grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 3);

      final cards = find.byType(MovieCard);
      final rects = [for (var i = 0; i < 3; i++) tester.getRect(cards.at(i))];
      expect(rects.map((rect) => rect.top).toSet(), hasLength(1));
      expect(rects.last.right, lessThanOrEqualTo(width - 15));
      expect(tester.widget<MovieCard>(cards.first).containArtwork, isTrue);
    });
  }
}
