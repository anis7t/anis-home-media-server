import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/api/api_client.dart';
import '../../../../core/api/api_endpoints.dart';
import '../../../../core/errors/app_exception.dart';
import '../../../../core/storage/settings_service.dart';
import '../models/library_response.dart';
import '../models/movie_details.dart';

/// Repository responsible for movie library catalog and details network operations.
class LibraryRepository {
  final ApiClient _apiClient;
  final SettingsService? _settingsService;

  LibraryRepository(this._apiClient, [this._settingsService]);

  Dio get _dio => _apiClient.dio;

  Future<void> _ensureBaseUrl() async {
    if (_settingsService != null) {
      final savedUrl = await _settingsService.getServerBaseUrl();
      if (savedUrl.isNotEmpty && _dio.options.baseUrl != savedUrl) {
        _apiClient.updateBaseUrl(savedUrl);
      }
    }
  }

  /// Fetches the complete media library and continue-watching rail.
  Future<LibraryResponse> getMovies() async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.get(ApiEndpoints.movies);
      if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
        return LibraryResponse.fromJson(response.data as Map<String, dynamic>);
      }
      throw ServerException(
        'Unexpected response format from ${ApiEndpoints.movies}',
        statusCode: response.statusCode,
      );
    } on DioException catch (e) {
      throw NetworkException(
        e.message ?? 'Failed to load movies',
        statusCode: e.response?.statusCode,
        details: e.error,
      );
    } catch (e) {
      if (e is AppException) rethrow;
      throw AppException('Error fetching movie library: $e');
    }
  }

  /// Fetches rich details, technical specs, and TMDb metadata for a single movie.
  Future<MovieDetails> getMovieDetails(String filename) async {
    await _ensureBaseUrl();
    try {
      final encoded = Uri.encodeComponent(filename);
      final response = await _dio.get('${ApiEndpoints.movieDetails}/$encoded');
      if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
        return MovieDetails.fromJson(response.data as Map<String, dynamic>);
      }
      throw ServerException(
        'Unexpected response format for movie details',
        statusCode: response.statusCode,
      );
    } on DioException catch (e) {
      throw NetworkException(
        e.message ?? 'Failed to load movie details for $filename',
        statusCode: e.response?.statusCode,
        details: e.error,
      );
    } catch (e) {
      if (e is AppException) rethrow;
      throw AppException('Error fetching movie details: $e');
    }
  }

  /// Triggers an explicit background library scan on the media server.
  Future<bool> triggerScan() async {
    await _ensureBaseUrl();
    try {
      final response = await _dio.post(ApiEndpoints.scan);
      return response.statusCode == 200;
    } on DioException catch (e) {
      throw NetworkException(
        e.message ?? 'Failed to trigger library scan',
        statusCode: e.response?.statusCode,
        details: e.error,
      );
    } catch (e) {
      if (e is AppException) rethrow;
      throw AppException('Error triggering library scan: $e');
    }
  }
}

/// Riverpod provider for LibraryRepository.
final libraryRepositoryProvider = Provider<LibraryRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final settingsService = ref.watch(settingsServiceProvider);
  return LibraryRepository(apiClient, settingsService);
});
