import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/core/storage/settings_service.dart';
import 'package:media_server_client/features/devices/data/repositories/device_repository.dart';
import 'package:media_server_client/features/devices/presentation/controllers/device_presence_controller.dart';
import 'package:media_server_client/features/devices/presentation/widgets/device_presence_scope.dart';

/// A shared client is enough for the fakes below: nothing here performs I/O.
ApiClient _testApiClient() => ApiClient(
      baseUrl: SettingsService.defaultServerUrl,
      authInterceptor:
          DeviceAuthInterceptor(DeviceIdentityService()),
    );

/// Reports a saved LAN origin, like a configured install.
class FakeSettingsService extends SettingsService {
  FakeSettingsService(this.savedUrl);

  final String savedUrl;

  @override
  Future<String> getServerBaseUrl() async => savedUrl;
}

/// Captures the URLs Dio would have sent, without touching the network.
class RecordingAdapter implements HttpClientAdapter {
  RecordingAdapter({this.statusCode = 200});

  final int statusCode;
  final List<String> requestedUrls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedUrls.add(options.uri.toString());
    return ResponseBody.fromString(
      jsonEncode({'success': true}),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Records heartbeat calls so the cadence, lifecycle gating and cleanup can be
/// asserted without a live server.
class FakeDeviceRepository extends DeviceRepository {
  FakeDeviceRepository({this.result = true, this.delay = Duration.zero})
      : super(_testApiClient());

  bool result;
  Duration delay;
  int calls = 0;
  int _inFlight = 0;
  int maxConcurrent = 0;

  @override
  Future<bool> sendHeartbeat() async {
    calls++;
    _inFlight++;
    if (_inFlight > maxConcurrent) maxConcurrent = _inFlight;
    try {
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      return result;
    } finally {
      _inFlight--;
    }
  }
}

ProviderContainer _containerWith(FakeDeviceRepository repository) {
  final container = ProviderContainer(
    overrides: [deviceRepositoryProvider.overrideWithValue(repository)],
  );
  return container;
}

void main() {
  group('DevicePresenceController - registration and cadence', () {
    test('registers immediately, then pings every 45s', () {
      fakeAsync((async) {
        final repo = FakeDeviceRepository();
        final container = _containerWith(repo);

        container.read(devicePresenceControllerProvider);
        async.flushMicrotasks();
        expect(repo.calls, 1, reason: 'registration ping on start');

        async.elapse(const Duration(seconds: 45));
        expect(repo.calls, 2);

        async.elapse(const Duration(seconds: 90));
        expect(repo.calls, 4);

        container.dispose();
        expect(async.periodicTimerCount, 0, reason: 'timer cancelled on dispose');
      });
    });

    test('stops pinging while backgrounded and pings again on resume', () {
      fakeAsync((async) {
        final repo = FakeDeviceRepository();
        final container = _containerWith(repo);
        final notifier = container.read(devicePresenceControllerProvider.notifier);
        async.flushMicrotasks();
        expect(repo.calls, 1);

        notifier.handleLifecycle(AppLifecycleState.paused);
        async.elapse(const Duration(minutes: 5));
        expect(repo.calls, 1, reason: 'no traffic while backgrounded');
        expect(async.periodicTimerCount, 0);

        notifier.handleLifecycle(AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(repo.calls, 2, reason: 'immediate ping on foreground');

        async.elapse(const Duration(seconds: 45));
        expect(repo.calls, 3);

        container.dispose();
      });
    });

    test('start is idempotent (no duplicate timers)', () {
      fakeAsync((async) {
        final repo = FakeDeviceRepository();
        final container = _containerWith(repo);
        final notifier = container.read(devicePresenceControllerProvider.notifier);
        async.flushMicrotasks();

        notifier.start();
        notifier.start();
        async.elapse(const Duration(seconds: 45));

        expect(repo.calls, 2, reason: 'one registration ping + one interval tick');
        container.dispose();
      });
    });

    test('dispose cancels the timer and sends nothing further', () {
      fakeAsync((async) {
        final repo = FakeDeviceRepository();
        final container = _containerWith(repo);
        container.read(devicePresenceControllerProvider);
        async.flushMicrotasks();
        expect(repo.calls, 1);

        container.dispose();
        async.elapse(const Duration(minutes: 10));
        expect(repo.calls, 1);
      });
    });

    test('a failed ping is swallowed and does not stop the cadence', () {
      fakeAsync((async) {
        final repo = FakeDeviceRepository(result: false);
        final container = _containerWith(repo);
        container.read(devicePresenceControllerProvider);
        async.flushMicrotasks();
        expect(repo.calls, 1);

        async.elapse(const Duration(seconds: 90));
        expect(repo.calls, 3);
        expect(
          container.read(devicePresenceControllerProvider),
          isNull,
          reason: 'state only advances on an acknowledged ping',
        );

        container.dispose();
      });
    });

    test('a slow ping is never overlapped by the next interval', () {
      fakeAsync((async) {
        final repo = FakeDeviceRepository(delay: const Duration(seconds: 60));
        final container = _containerWith(repo);
        container.read(devicePresenceControllerProvider);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 50));
        expect(repo.calls, 1, reason: 'interval tick skipped while in flight');
        expect(repo.maxConcurrent, 1);

        async.elapse(const Duration(seconds: 45));
        expect(repo.calls, 2, reason: 'next tick after the slow ping finished');

        container.dispose();
      });
    });

    test('an acknowledged ping records the heartbeat time', () {
      fakeAsync((async) {
        final repo = FakeDeviceRepository();
        final container = _containerWith(repo);
        container.read(devicePresenceControllerProvider);
        async.flushMicrotasks();

        expect(container.read(devicePresenceControllerProvider), isNotNull);
        container.dispose();
      });
    });
  });

  group('DeviceRepository - active origin', () {
    test('sends the heartbeat to the saved server, not the default origin',
        () async {
      final apiClient = _testApiClient();
      final adapter = RecordingAdapter();
      apiClient.dio.httpClientAdapter = adapter;

      final repo = DeviceRepository(
        apiClient,
        FakeSettingsService('http://192.168.1.16:8000'),
      );

      expect(await repo.sendHeartbeat(), isTrue);
      expect(
        adapter.requestedUrls.single,
        'http://192.168.1.16:8000/api/devices/heartbeat',
        reason: 'a cold start must not ping the default 127.0.0.1 origin',
      );
      expect(apiClient.dio.options.baseUrl, 'http://192.168.1.16:8000');
    });

    test('an unacknowledged ping returns false instead of throwing', () async {
      final apiClient = _testApiClient();
      apiClient.dio.httpClientAdapter = RecordingAdapter(statusCode: 500);

      final repo = DeviceRepository(
        apiClient,
        FakeSettingsService('http://192.168.1.16:8000'),
      );

      expect(await repo.sendHeartbeat(), isFalse);
    });
  });

  group('DevicePresenceScope - lifecycle wiring', () {
    testWidgets('mounts tracking and follows app lifecycle transitions',
        (tester) async {
      final repo = FakeDeviceRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [deviceRepositoryProvider.overrideWithValue(repo)],
          child: const DevicePresenceScope(
            child: SizedBox.shrink(),
          ),
        ),
      );
      await tester.pump();
      expect(repo.calls, 1, reason: 'registration ping on mount');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 2));
      expect(repo.calls, 1, reason: 'backgrounded app sends nothing');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(repo.calls, 2, reason: 'immediate ping on foreground');
    });
  });
}
