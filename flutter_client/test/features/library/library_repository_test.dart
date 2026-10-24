import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/errors/app_exception.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/features/library/data/repositories/library_repository.dart';

class MockSecureStorage extends FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({required String key, AppleOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, WindowsOptions? wOptions, AppleOptions? mOptions}) async => data[key];
  @override
  Future<void> write({required String key, required String? value, AppleOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions, WindowsOptions? wOptions, AppleOptions? mOptions}) async {
    if (value != null) data[key] = value;
  }
}

void main() {
  late DeviceIdentityService deviceService;
  late DeviceAuthInterceptor authInterceptor;

  setUp(() {
    deviceService = DeviceIdentityService(secureStorage: MockSecureStorage());
    authInterceptor = DeviceAuthInterceptor(deviceService);
  });

  ApiClient createMockApiClient(
    Future<Response<dynamic>> Function(RequestOptions options) handler,
  ) {
    final customDio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8000'));
    customDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, reqHandler) async {
          try {
            final res = await handler(options);
            reqHandler.resolve(res);
          } on DioException catch (e) {
            reqHandler.reject(e);
          } catch (e) {
            reqHandler.reject(DioException(requestOptions: options, error: e));
          }
        },
      ),
    );

    return ApiClient(
      baseUrl: 'http://127.0.0.1:8000',
      authInterceptor: authInterceptor,
      customDio: customDio,
    );
  }

  group('LibraryRepository', () {
    test('getMovies returns LibraryResponse on 200 OK', () async {
      final apiClient = createMockApiClient((options) async {
        expect(options.path, '/api/movies');
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'movies': [
              {
                'filename': 'Movie1.mp4',
                'title': 'Movie One',
                'year': 2026,
                'position': 0.0,
                'duration': 1000.0,
              },
            ],
            'watching': [],
            'total': 1,
          },
        );
      });

      final repo = LibraryRepository(apiClient);
      final result = await repo.getMovies();

      expect(result.total, 1);
      expect(result.movies.length, 1);
      expect(result.movies.first.title, 'Movie One');
    });

    test('getMovieDetails returns MovieDetails on 200 OK', () async {
      final apiClient = createMockApiClient((options) async {
        expect(options.path, '/api/movie/Mayday.mkv');
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'movie': {
              'filename': 'Mayday.mkv',
              'title': 'Mayday',
              'year': 2026,
            },
            'specs': {
              'resolution': '1080p',
              'container': 'MKV',
            },
            'extended': {
              'tagline': 'Emergency landing.',
            },
            'formatted_runtime': '1h 50m',
          },
        );
      });

      final repo = LibraryRepository(apiClient);
      final details = await repo.getMovieDetails('Mayday.mkv');

      expect(details.movie.title, 'Mayday');
      expect(details.specs.resolution, '1080p');
      expect(details.extended.tagline, 'Emergency landing.');
      expect(details.formattedRuntime, '1h 50m');
    });

    test('triggerScan returns true on 200 OK', () async {
      final apiClient = createMockApiClient((options) async {
        expect(options.path, '/api/scan');
        expect(options.method, 'POST');
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {'status': 'scanning', 'busy': false},
        );
      });

      final repo = LibraryRepository(apiClient);
      final success = await repo.triggerScan();
      expect(success, isTrue);
    });

    test('getMovies throws NetworkException on DioException error', () async {
      final apiClient = createMockApiClient((options) async {
        throw DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 503),
          message: 'Service Unavailable',
        );
      });

      final repo = LibraryRepository(apiClient);
      expect(
        () => repo.getMovies(),
        throwsA(isA<NetworkException>()),
      );
    });

    test('getMovieDetails throws NetworkException on 404', () async {
      final apiClient = createMockApiClient((options) async {
        throw DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 404),
          message: 'Not Found',
        );
      });

      final repo = LibraryRepository(apiClient);
      expect(
        () => repo.getMovieDetails('missing.mp4'),
        throwsA(isA<NetworkException>()),
      );
    });
  });
}
