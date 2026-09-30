import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_client.dart';

import 'package:media_server_client/core/storage/settings_service.dart' hide serverBaseUrlProvider;

/// The library/home cards resolve artwork with `serverBaseUrlProvider`, which
/// reads `dio.options.baseUrl`. That URL is only corrected to the *saved* server
/// later, by the repositories' `_ensureBaseUrl()` - so a snapshot taken on the
/// first frame pins artwork to the compile-time default `defaultServerUrl`,
/// which on a phone points to WAN by default.
void main() {
  test('serverBaseUrlProvider tracks the active server, not a first-frame snapshot', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // First frame: the home screen builds before any repository call.
    final atFirstFrame = container.read(serverBaseUrlProvider);
    expect(atFirstFrame, SettingsService.defaultServerUrl,
        reason: 'the compile-time default is what the app starts with');

    // The library repository then resolves the saved server and points Dio at it.
    container.read(apiClientProvider).updateBaseUrl('http://192.168.1.16:8000');

    expect(container.read(serverBaseUrlProvider), 'http://192.168.1.16:8000',
        reason: 'artwork must follow the server the app actually talks to');
  });
}