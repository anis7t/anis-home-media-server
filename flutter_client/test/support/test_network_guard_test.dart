import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/storage/settings_service.dart';

import 'test_network_guard.dart';

/// Proves the routing policy itself. Nothing here opens a socket: the policy is the
/// `findProxy` callback, which is invoked with the destination [Uri] and returns a
/// proxy directive (or throws) without contacting anything.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestNetworkGuardOverrides guard;

  setUp(() {
    resetBlockedRequests();
    guard = TestNetworkGuardOverrides(testAllowedHosts);
  });

  group('production origin policy', () {
    test('the app default really is the production host (guards the premise)', () {
      expect(SettingsService.defaultServerUrl, 'https://media.anisparvez.in');
    });

    test('the sentinel is non-loopback so it short-circuits the fallback', () {
      // PlayerMediaResolver.resolveServerOrigin skips loopback media hosts and then
      // falls through to connectionControllerProvider.serverUrl, which is production.
      final host = Uri.parse(testOrigin).host;
      expect(host, isNot('127.0.0.1'));
      expect(host, isNot('localhost'));
      expect(host, 'test.invalid');
    });

    test('blocks the production host', () {
      const uri = 'https://media.anisparvez.in/api/media-info/Batman.mp4';
      expect(
        () => guard.proxyFor(Uri.parse(uri)),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('TEST NETWORK GUARD'),
        )),
      );
    });

    test('records what it blocked, so a test can assert on its own traffic', () {
      const uri = 'https://media.anisparvez.in/api/movies';
      expect(() => guard.proxyFor(Uri.parse(uri)), throwsStateError);
      expect(blockedRequests, hasLength(1));
      expect(blockedRequests.single.host, 'media.anisparvez.in');
    });

    test('blocks the live loopback service too', () {
      // 127.0.0.1:8000 IS the running Waitress service on this host.
      expect(
        () => guard.proxyFor(Uri.parse('http://127.0.0.1:8000/api/movies')),
        throwsStateError,
      );
    });

    test('blocks any non-allowlisted host', () {
      for (final host in const ['example.com', '192.168.1.16', 'localhost']) {
        expect(
          () => guard.proxyFor(Uri.parse('http://$host:8000/api/movies')),
          throwsStateError,
          reason: '$host must not be reachable from an ordinary test',
        );
      }
    });
  });

  group('sentinel routing', () {
    test('routes the sentinel to a dead port, so nothing is contacted', () {
      expect(guard.proxyFor(Uri.parse(testOrigin)), 'PROXY 127.0.0.1:1');
    });

    test('allows any path under the sentinel host', () {
      for (final path in const [
        '/api/movies',
        '/api/media-info/x.mp4',
        '/hls/x/playlist.m3u8',
      ]) {
        expect(
          guard.proxyFor(Uri.parse('$testOrigin$path')),
          'PROXY 127.0.0.1:1',
          reason: path,
        );
      }
      expect(blockedRequests, isEmpty);
    });

    test('host matching is case-insensitive', () {
      expect(
        guard.proxyFor(Uri.parse('http://TEST.INVALID:8000/api/movies')),
        'PROXY 127.0.0.1:1',
      );
    });
  });

  group('explicit live-test opt-in', () {
    test('stands down entirely when live tests are enabled', () {
      expect(guardAllowedHosts(liveTestsEnabled: true), isNull);
    });

    test('is armed when live tests are disabled', () {
      expect(guardAllowedHosts(liveTestsEnabled: false), testAllowedHosts);
    });

    test('an extra allowed host is unioned in, never replacing the sentinel', () {
      final hosts = guardAllowedHosts(
        liveTestsEnabled: false,
        allowedHosts: const {'example.test'},
      );
      expect(hosts, containsAll(testAllowedHosts));
      expect(hosts, contains('example.test'));
    });
  });
}