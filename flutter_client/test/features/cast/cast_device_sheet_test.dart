import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/features/cast/data/repositories/cast_repository.dart';
import 'package:media_server_client/features/cast/presentation/widgets/cast_device_sheet.dart';

import 'cast_repository_test.dart' show MockSecureStorage;

/// A server answer with the given devices, and a record of what the sheet sent.
class _Server {
  final List<Map<String, dynamic>> devices;
  final String? playError;
  final List<Map<String, dynamic>> posts = [];

  _Server({this.devices = const [], this.playError});

  Future<Response<dynamic>> handle(RequestOptions options) async {
    if (options.path == '/api/cast/devices') {
      return Response(requestOptions: options, statusCode: 200, data: {
        'ok': true,
        'scanning': false,
        'devices': devices,
      });
    }
    if (options.path == '/api/cast/play') {
      final body = Map<String, dynamic>.from(options.data as Map);
      posts.add(body);
      if (playError != null) {
        return Response(requestOptions: options, statusCode: 400, data: {'ok': false, 'error': playError});
      }
      return Response(requestOptions: options, statusCode: 200, data: {'ok': true});
    }
    return Response(requestOptions: options, statusCode: 200, data: {'ok': true});
  }
}

const _tv = {'id': 'dlna:uuid:tv', 'name': 'TV', 'kind': 'dlna', 'model': 'UA43DU7000', 'host': '192.168.1.8'};
const _chromecast = {'id': 'cast:abc', 'name': 'Living room', 'kind': 'cast', 'model': 'Chromecast Ultra'};

void main() {
  ApiClient mockApiClient(_Server server) {
    final deviceService = DeviceIdentityService(secureStorage: MockSecureStorage());
    final customDio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8000'));
    customDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, reqHandler) async {
          try {
            reqHandler.resolve(await server.handle(options));
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
      authInterceptor: DeviceAuthInterceptor(deviceService),
      customDio: customDio,
    );
  }

  Future<void> pumpSheet(
    WidgetTester tester,
    _Server server, {
    String? filename = 'Batman.mp4',
    ValueChanged<String>? onStarted,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          castRepositoryProvider.overrideWithValue(CastRepository(mockApiClient(server))),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => CastDeviceSheet.show(
                    context: context,
                    filename: filename,
                    onStarted: onStarted,
                  ),
                  child: const Text('open cast'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open cast'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists the devices the server found, with their protocol', (tester) async {
    await pumpSheet(tester, _Server(devices: [_tv, _chromecast]));

    expect(find.text('Cast to device'), findsOneWidget);
    expect(find.text('TV'), findsOneWidget);
    expect(find.text('DLNA · UA43DU7000'), findsOneWidget);
    expect(find.text('Living room'), findsOneWidget);
    expect(find.text('Chromecast · Chromecast Ultra'), findsOneWidget);
    expect(find.byIcon(Icons.cast_rounded), findsOneWidget);
  });

  testWidgets('tapping a device hands the file over and reports it', (tester) async {
    final server = _Server(devices: [_tv, _chromecast]);
    String? started;
    await pumpSheet(tester, server, onStarted: (name) => started = name);

    await tester.tap(find.text('TV'));
    await tester.pumpAndSettle();

    expect(server.posts.single['device_id'], 'dlna:uuid:tv');
    expect(server.posts.single['filename'], 'Batman.mp4');
    expect(started, 'TV');
    expect(find.text('Cast to device'), findsNothing, reason: 'the sheet closes once the device takes over');
  });

  testWidgets("a refusal shows the server's own reason and keeps the sheet open", (tester) async {
    final server = _Server(
      devices: [_chromecast],
      playError: 'Chromecast cannot play .mkv directly - no HLS version is cached yet.',
    );
    await pumpSheet(tester, server);

    await tester.tap(find.text('Living room'));
    await tester.pumpAndSettle();

    expect(find.textContaining('no HLS version is cached yet'), findsOneWidget);
    expect(find.text('Cast to device'), findsOneWidget, reason: 'the user must be able to pick another device');
  });

  testWidgets('an empty result explains itself instead of showing a blank list', (tester) async {
    await pumpSheet(tester, _Server());

    expect(find.textContaining('No cast devices found'), findsOneWidget);
  });

  testWidgets('without a file the sheet only manages the session', (tester) async {
    final server = _Server(devices: [_tv]);
    await pumpSheet(tester, server, filename: null);

    await tester.tap(find.text('TV'));
    await tester.pumpAndSettle();

    expect(server.posts, isEmpty);
    expect(find.text('Cast to device'), findsOneWidget);
  });
}