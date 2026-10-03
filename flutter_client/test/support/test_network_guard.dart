import 'dart:io';

import 'live_server_gate.dart';

/// Why this file exists
/// ---------------------
/// The Flutter app ships a production origin as a compile-time default
/// (`SettingsService.defaultServerUrl`), and `/player` even carries a hard-coded
/// production media URL as a last-resort fallback (`lib/app/routes.dart`) so that
/// `adb shell am start ... --es route "/player"` works. Ordinary widget tests that
/// mount the real app therefore inherit `https://media.anisparvez.in` unless every
/// provider in the chain is overridden.
///
/// `TestWidgetsFlutterBinding` already intercepts `dart:io` HTTP with a client that
/// returns 400, so today nothing actually leaves the machine. That protection is
/// implicit, though, and it disappears under `integration_test`
/// (`IntegrationTestWidgetsFlutterBinding.overrideHttpClient => false`). This guard
/// makes the protection explicit, host-aware, and loud.
///
/// Why the sentinel is NOT `127.0.0.1`
/// ----------------------------------
/// On this host `127.0.0.1:8000` *is* the live production service, so it is not a
/// safe placeholder. It is also useless here: `PlayerMediaResolver.resolveServerOrigin`
/// deliberately skips loopback media hosts and falls through to
/// `connectionControllerProvider.serverUrl`, which is the production default and is
/// overridden nowhere in the suite. A non-loopback sentinel short-circuits that
/// fallback instead of triggering it.
///
/// `test.invalid` is reserved by RFC 2606 and never resolves in any registry.
const String testOrigin = 'http://test.invalid:8000';

/// Hosts an ordinary test is permitted to address.
const Set<String> testAllowedHosts = <String>{'test.invalid'};

/// Requests the guard refused, newest last. Cleared by [resetBlockedRequests].
final List<Uri> blockedRequests = <Uri>[];

/// Installs the guard for the current test isolate.
///
/// `HttpOverrides` is per-isolate and `flutter test` runs every test file in its own
/// isolate, so this must be called from each file's `setUp`/`setUpAll` - there is no
/// global setup hook without adding a dependency.
///
/// Call it *after* `TestWidgetsFlutterBinding.ensureInitialized()`: the binding sets
/// `HttpOverrides.global` to its own 400-returning mock when it is constructed, and
/// installing later is what makes a violation loud instead of a silent 400. Installing
/// earlier is still safe (the binding's mock would simply win), never less safe.
void installTestNetworkGuard({Set<String>? allowedHosts}) {
  final resolved = guardAllowedHosts(allowedHosts: allowedHosts);
  if (resolved == null) return; // explicit opt-out for live-server tests
  blockedRequests.clear();
  HttpOverrides.global = TestNetworkGuardOverrides(resolved);
}

/// The hosts the guard will permit, or `null` when it must stand down entirely.
///
/// [liveTestsEnabled] exists so the opt-out branch is reachable from a test without
/// mutating `Platform.environment`; production callers leave it unset.
Set<String>? guardAllowedHosts({
  bool? liveTestsEnabled,
  Set<String>? allowedHosts,
}) {
  if (liveTestsEnabled ?? liveServerTestsEnabled) return null;
  return <String>{...?allowedHosts, ...testAllowedHosts};
}

/// Forgets previously blocked requests so each test asserts on its own traffic.
void resetBlockedRequests() => blockedRequests.clear();

/// Public only so a test can assert the routing policy directly, with no socket.
class TestNetworkGuardOverrides extends HttpOverrides {
  TestNetworkGuardOverrides(this.allowedHosts);

  final Set<String> allowedHosts;

  /// Decides how a request to [uri] is routed: a dead local port for an allowed host,
  /// and a hard refusal for anything else.
  String proxyFor(Uri uri) {
    if (allowedHosts.contains(uri.host.toLowerCase())) {
      // Allowed, but still contacted with nothing: a closed local port, so no socket
      // and no DNS lookup ever leaves the machine.
      return 'PROXY 127.0.0.1:1';
    }
    blockedRequests.add(uri);
    throw StateError(
      'TEST NETWORK GUARD: refused a request to $uri. Ordinary tests may only '
      'address $testOrigin. If a test genuinely needs the live server, set '
      'MEDIA_SERVER_LIVE_TESTS=1 (see live_server_gate.dart).',
    );
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionTimeout = const Duration(seconds: 2);
    // `findProxy` receives the destination `Uri`, which is the cheapest way to inspect
    // the host without reimplementing the whole `HttpClient` interface.
    client.findProxy = proxyFor;
    return client;
  }
}