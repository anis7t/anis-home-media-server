import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/features/library/data/models/library_response.dart';
import 'package:media_server_client/features/library/data/models/movie_item.dart';
import 'package:media_server_client/features/library/data/repositories/library_repository.dart';
import 'package:media_server_client/features/library/presentation/controllers/library_controller.dart';
import 'package:media_server_client/features/library/presentation/widgets/sort_filter_sheet.dart';

class MockSecureStorage extends FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
  }) async => data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
  }) async {
    if (value != null) data[key] = value;
  }
}

class FakeLibraryRepository extends LibraryRepository {
  final Future<LibraryResponse> Function()? onGetMovies;

  FakeLibraryRepository({this.onGetMovies})
    : super(
        ApiClient(
          baseUrl: 'http://127.0.0.1:8000',
          authInterceptor: DeviceAuthInterceptor(
            DeviceIdentityService(secureStorage: MockSecureStorage()),
          ),
        ),
      );

  @override
  Future<LibraryResponse> getMovies() async {
    if (onGetMovies != null) return onGetMovies!();
    return const LibraryResponse(movies: [], watching: [], total: 0);
  }
}

void main() {
  const movieA = MovieItem(
    filename: 'batman.mp4',
    title: 'Batman Knightfall',
    year: 2026,
    genres: 'Action, Mystery',
    rating: 8.4,
    percent: 50.0,
    position: 3420,
    duration: 6840,
  );

  const movieB = MovieItem(
    filename: 'spiderman.mkv',
    title: 'Spider-Man Brand New Day',
    year: 2025,
    genres: 'Action, Sci-Fi',
    rating: 7.9,
  );

  Widget createSubject({required ProviderContainer container}) {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SortFilterSheet())),
    );
  }

  group('SortFilterSheet Widget Tests', () {
    testWidgets('renders all sections, sort options, and genre chips', (
      tester,
    ) async {
      final fakeRepo = FakeLibraryRepository(
        onGetMovies: () async => const LibraryResponse(
          movies: [movieA, movieB],
          watching: [],
          total: 2,
        ),
      );

      final container = ProviderContainer(
        overrides: [libraryRepositoryProvider.overrideWithValue(fakeRepo)],
      );
      addTearDown(container.dispose);

      await container.read(libraryControllerProvider.notifier).loadLibrary();

      await tester.pumpWidget(createSubject(container: container));
      await tester.pumpAndSettle();

      // Header title
      expect(find.text('Sort & Filter'), findsOneWidget);

      // Section titles
      expect(find.text('WATCH STATUS'), findsOneWidget);
      expect(find.text('GENRE'), findsOneWidget);
      expect(find.text('SORT BY'), findsOneWidget);

      // Watch status options
      expect(find.text('All'), findsOneWidget);
      expect(find.text('In Progress'), findsOneWidget);
      expect(find.text('Unwatched'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);

      // Genre chips extracted from movies
      expect(find.text('All Genres'), findsOneWidget);
      expect(find.text('Action'), findsOneWidget);
      expect(find.text('Mystery'), findsOneWidget);
      expect(find.text('Sci-Fi'), findsOneWidget);

      // Sort options
      expect(find.text('Title (A → Z)'), findsOneWidget);
      expect(find.text('Title (Z → A)'), findsOneWidget);
      expect(find.text('Release Year (Newest first)'), findsOneWidget);
      expect(find.text('Release Year (Oldest first)'), findsOneWidget);
      expect(find.text('Rating (Highest first)'), findsOneWidget);
      expect(find.text('Watch Progress (% completed)'), findsOneWidget);
      expect(find.text('Recently Added'), findsOneWidget);
    });

    testWidgets('selecting sort and filter options updates controller state', (
      tester,
    ) async {
      final fakeRepo = FakeLibraryRepository(
        onGetMovies: () async => const LibraryResponse(
          movies: [movieA, movieB],
          watching: [],
          total: 2,
        ),
      );

      final container = ProviderContainer(
        overrides: [libraryRepositoryProvider.overrideWithValue(fakeRepo)],
      );
      addTearDown(container.dispose);

      await container.read(libraryControllerProvider.notifier).loadLibrary();

      await tester.pumpWidget(createSubject(container: container));
      await tester.pumpAndSettle();

      // Tap 'In Progress' watch status chip
      await tester.tap(find.text('In Progress'));
      await tester.pumpAndSettle();
      expect(
        container.read(libraryControllerProvider).watchStatusFilter,
        WatchStatusFilter.inProgress,
      );

      // Tap 'Mystery' genre chip
      await tester.tap(find.text('Mystery'));
      await tester.pumpAndSettle();
      expect(
        container.read(libraryControllerProvider).selectedGenre,
        'Mystery',
      );

      // Tap 'Rating (Highest first)' sort option
      await tester.tap(find.text('Rating (Highest first)'));
      await tester.pumpAndSettle();
      expect(
        container.read(libraryControllerProvider).sortOption,
        SortOption.ratingDesc,
      );

      // Active filters badge and Reset All button should appear
      expect(find.text('3'), findsOneWidget); // 3 active filters
      expect(find.text('Reset All'), findsOneWidget);

      // Tap 'Reset All'
      await tester.tap(find.text('Reset All'));
      await tester.pumpAndSettle();

      final resetState = container.read(libraryControllerProvider);
      expect(resetState.sortOption, SortOption.titleAsc);
      expect(resetState.watchStatusFilter, WatchStatusFilter.all);
      expect(resetState.selectedGenre, isNull);
      expect(resetState.activeFilterCount, 0);
      expect(find.text('Reset All'), findsNothing);
    });
  });
}
