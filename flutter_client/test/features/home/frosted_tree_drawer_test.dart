import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/home/presentation/widgets/frosted_tree_drawer.dart';
import 'package:media_server_client/features/library/domain/models/movie_item.dart';
import 'package:media_server_client/features/library/presentation/controllers/library_controller.dart';

void main() {
  group('FrostedTreeDrawer Widget Tests', () {
    final sampleMovies = [
      const MovieItem(
        filename: 'action1.mp4',
        title: 'Action Movie 1',
        year: 2024,
        genres: 'Action',
      ),
      const MovieItem(
        filename: 'scifi1.mp4',
        title: 'Sci-Fi Movie 1',
        year: 2018,
        genres: 'Sci-Fi',
      ),
    ];

    Widget createTestableWidget({
      ValueChanged<String>? onGenreSelected,
      ValueChanged<String>? onDecadeSelected,
    }) {
      return ProviderScope(
        overrides: [
          libraryControllerProvider.overrideWith(
            () => _FakePopulatedLibraryController(sampleMovies),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: FrostedTreeDrawer(
              onGenreSelected: onGenreSelected,
              onDecadeSelected: onDecadeSelected,
            ),
          ),
        ),
      );
    }

    testWidgets('renders header, All Movies node, and expandable branches',
        (tester) async {
      await tester.pumpWidget(createTestableWidget());
      await tester.pumpAndSettle();

      expect(find.text('Media Catalog Tree'), findsOneWidget);
      expect(find.text('All Movies'), findsOneWidget);
      expect(find.text('Recently Added'), findsOneWidget);
      expect(find.text('Genres'), findsOneWidget);
      expect(find.text('Release Eras'), findsOneWidget);
      expect(find.text('Action'), findsOneWidget);
      expect(find.text('Sci-Fi'), findsOneWidget);
    });

    testWidgets('selecting a genre leaf invokes onGenreSelected',
        (tester) async {
      String? selectedGenre;
      await tester.pumpWidget(createTestableWidget(
        onGenreSelected: (genre) => selectedGenre = genre,
      ));
      await tester.pumpAndSettle();

      final actionLeaf = find.text('Action');
      expect(actionLeaf, findsOneWidget);

      await tester.tap(actionLeaf);
      await tester.pumpAndSettle();

      expect(selectedGenre, 'Action');
    });

    testWidgets('expanding release eras renders decade leaves and invokes callback',
        (tester) async {
      String? selectedDecade;
      await tester.pumpWidget(createTestableWidget(
        onDecadeSelected: (decade) => selectedDecade = decade,
      ));
      await tester.pumpAndSettle();

      // Tap to expand Release Eras
      final releaseErasNode = find.text('Release Eras');
      await tester.tap(releaseErasNode);
      await tester.pumpAndSettle();

      expect(find.text('2020s'), findsOneWidget);
      expect(find.text('2010s'), findsOneWidget);

      await tester.tap(find.text('2020s'));
      await tester.pumpAndSettle();

      expect(selectedDecade, '2020s');
    });
  });
}

class _FakePopulatedLibraryController extends LibraryController {
  final List<MovieItem> _movies;
  _FakePopulatedLibraryController(this._movies);

  @override
  LibraryState build() {
    return LibraryState(
      status: LibraryStatus.loaded,
      movies: _movies,
      total: _movies.length,
    );
  }
}
