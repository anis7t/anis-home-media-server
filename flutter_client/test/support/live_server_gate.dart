import 'dart:io';

/// Opt-in gate for tests that talk to a RUNNING Media Server.
///
/// These tests are integration tests, not unit tests: they open real sockets to the live
/// Waitress service and one of them (the heartbeat in `live_server_connection_test.dart`) *writes*
/// to the production `devices` table. Running them by accident therefore mutates live state, so
/// they are skipped unless the operator opts in explicitly:
///
///   MEDIA_SERVER_LIVE_TESTS=1 flutter test test/streaming_http_contract_test.dart
///
/// The origin defaults to http://127.0.0.1:8000 and can be pointed elsewhere with
/// MEDIA_SERVER_TEST_ORIGIN.
const String _liveTestsFlag = 'MEDIA_SERVER_LIVE_TESTS';
const String _originVariable = 'MEDIA_SERVER_TEST_ORIGIN';

/// Whether the live-server integration tests should run in this process.
bool get liveServerTestsEnabled => Platform.environment[_liveTestsFlag] == '1';

/// Origin the live-server integration tests hit.
String get liveServerOrigin =>
    Platform.environment[_originVariable] ?? 'http://127.0.0.1:8000';

/// `skip:` value for `test()`/`group()`: `null` when enabled, otherwise the reason it is skipped.
String? get liveServerSkip => liveServerTestsEnabled
    ? null
    : 'live-server integration test - set $_liveTestsFlag=1 to run it against '
        '$liveServerOrigin (it mutates live device telemetry)';