import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/errors/app_exception.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/features/cast/data/repositories/cast_repository.dart';

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
            reqHandler.resolve(await handler(options));
          } on DioException catch (e) {
            reqHandler.reject(e);
          } catch (e) {
            reqHandler.reject(DioException(requestOptions: options, error: e));
          }
        },
      ),
    );
    return ApiClient(baseUrl: 'http://127.0.0.1:8000', authInterceptor: authInterceptor, customDio: customDio);
  }

  group('CastRepository', () {
    test('discover parses devices, the scanning flag and per-protocol errors', () async {
      final apiClient = createMockApiClient((options) async {
        expect(options.path, '/api/cast/devices');
        expect(options.queryParameters, {'refresh': '1'});
        return Response(requestOptions: options, statusCode: 200, data: {
          'ok': true,
          'scanning': true,
          'devices': [
            {'id': 'dlna:uuid:tv', 'name': 'TV', 'kind': 'dlna', 'model': 'UA43DU7000', 'host': '192.168.1.8'},
            {'id': 'cast:abc', 'name': 'Living room', 'kind': 'cast'},
            {'name': 'no id, dropped'},
          ],
          'errors': {'cast': 'no mDNS responder'},
        });
      });

      final discovery = await CastRepository(apiClient).discover(refresh: true);

      expect(discovery.devices.length, 2);
      expect(discovery.devices.first.name, 'TV');
      expect(discovery.devices.first.protocolLabel, 'DLNA');
      expect(discovery.devices.last.isChromecast, isTrue);
      expect(discovery.scanning, isTrue);
      expect(discovery.errors['cast'], 'no mDNS responder');
    });

    test('play posts the device, file and resume point in seconds', () async {
      RequestOptions? seen;
      final apiClient = createMockApiClient((options) async {
        seen = options;
        return Response(requestOptions: options, statusCode: 200, data: {'ok': true});
      });

      await CastRepository(apiClient).play(
        deviceId: 'dlna:uuid:tv',
        filename: 'Batman Knightfall.mp4',
        position: const Duration(seconds: 90, milliseconds: 500),
      );

      expect(seen!.path, '/api/cast/play');
      expect(seen!.data, {'device_id': 'dlna:uuid:tv', 'filename': 'Batman Knightfall.mp4', 'position': 90.5});
    });

    test("play surfaces the server's own error text", () async {
      final apiClient = createMockApiClient((options) async {
        throw DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 400, data: {
            'ok': false,
            'error': 'Chromecast cannot play .mkv directly - no HLS version is cached yet.',
          }),
        );
      });

      expect(
        () => CastRepository(apiClient).play(deviceId: 'cast:abc', filename: 'movie.mkv'),
        throwsA(isA<ServerException>().having((e) => e.message, 'message', contains('no HLS version'))),
      );
    });

    test('control posts the action and value', () async {
      RequestOptions? seen;
      final apiClient = createMockApiClient((options) async {
        seen = options;
        return Response(requestOptions: options, statusCode: 200, data: {'ok': true});
      });

      await CastRepository(apiClient).control(deviceId: 'dlna:uuid:tv', action: 'seek', value: 42);
      expect(seen!.path, '/api/cast/control');
      expect(seen!.data, {'device_id': 'dlna:uuid:tv', 'action': 'seek', 'value': 42});
    });

    test('status returns the parsed transport state, and null when unavailable', () async {
      var call = 0;
      final apiClient = createMockApiClient((options) async {
        call++;
        if (call == 1) {
          return Response(requestOptions: options, statusCode: 200, data: {
            'ok': true,
            'state': 'playing',
            'position': 12.5,
            'duration': 4717.0,
            'filename': 'Batman.mp4',
          });
        }
        return Response(requestOptions: options, statusCode: 200, data: {'ok': false, 'error': 'unreachable'});
      });

      final repo = CastRepository(apiClient);
      final status = await repo.status('dlna:uuid:tv');
      expect(status!.state, 'playing');
      expect(status.isPlaying, isTrue);
      expect(status.position, const Duration(milliseconds: 12500));
      expect(status.filename, 'Batman.mp4');

      expect(await repo.status('dlna:uuid:tv'), isNull);
    });
  });
}
