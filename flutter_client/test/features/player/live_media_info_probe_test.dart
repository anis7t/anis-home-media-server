import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/live_server_gate.dart';

/// Live probe of the exact request the player makes for its playback mode.
///
/// Gated like the other live tests (`MEDIA_SERVER_LIVE_TESTS=1`): it reads the
/// real server, so it is skipped by default. It exists because the player's
/// mode probe failed on a physical device while the same URL answered 200 from
/// the device's own curl - this isolates "the code path is wrong" from
/// "something about the device's Dart HTTP is wrong".
void main() {
  const filename =
      'Batman Knightfall Part 1 2026 1080p WEBRip x264 AAC5 1-[YTS GG - YTS BZ].mp4';

  test('bare Dio (what the player builds) resolves direct_play', () async {
    final encoded = Uri.encodeComponent(filename);
    final url = '$liveServerOrigin/api/media-info/$encoded';

    final dio = Dio();
    final res = await dio.get<dynamic>(
      url,
      options: Options(
        responseType: ResponseType.json,
        validateStatus: (status) => status != null && status < 500,
      ),
    );

    expect(res.statusCode, 200, reason: 'probe URL: $url');
    expect(res.data, isA<Map>());
    expect((res.data as Map)['direct_play'], isTrue);
  }, skip: liveServerSkip);
}
