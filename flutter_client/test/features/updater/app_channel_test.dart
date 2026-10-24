import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/models/app_channel.dart';

void main() {
  group('AppChannel Model Tests', () {
    test('parses standard channel identifiers correctly', () {
      expect(AppChannel.fromString('production'), AppChannel.production);
      expect(AppChannel.fromString('developer'), AppChannel.developer);
    });

    test('parses common shorthand and case-insensitive strings', () {
      expect(AppChannel.fromString('prod'), AppChannel.production);
      expect(AppChannel.fromString('dev'), AppChannel.developer);
      expect(AppChannel.fromString('DEVELOPER'), AppChannel.developer);
      expect(AppChannel.fromString(' Production '), AppChannel.production);
    });

    test('falls back to production for null or unknown identifiers', () {
      expect(AppChannel.fromString(null), AppChannel.production);
      expect(AppChannel.fromString(''), AppChannel.production);
      expect(AppChannel.fromString('beta'), AppChannel.production);
      expect(AppChannel.fromString('nightly'), AppChannel.production);
    });

    test('compileTimeDefault resolves to valid AppChannel', () {
      expect(AppChannel.compileTimeDefault, isA<AppChannel>());
    });

    test('displays friendly human-readable names and descriptions', () {
      expect(AppChannel.production.displayName, 'Production');
      expect(AppChannel.developer.displayName, 'Developer');
      expect(AppChannel.production.description, contains('Stable'));
      expect(AppChannel.developer.description, contains('development'));
    });
  });
}
