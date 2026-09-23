import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/storage/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsService', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Returns defaultServerUrl when no URL has been saved', () async {
      final service = SettingsService();
      final url = await service.getServerBaseUrl();
      expect(url, equals(SettingsService.defaultServerUrl));
    });

    test('Persists and normalizes server URL without trailing slashes', () async {
      final service = SettingsService();

      await service.setServerBaseUrl('http://192.168.1.100:8000///');
      final savedUrl = await service.getServerBaseUrl();
      expect(savedUrl, equals('http://192.168.1.100:8000'));
    });

    test('Prepends http:// if scheme was omitted', () async {
      final service = SettingsService();

      await service.setServerBaseUrl('media.anisparvez.in');
      final savedUrl = await service.getServerBaseUrl();
      expect(savedUrl, equals('http://media.anisparvez.in'));
    });

    test('Preserves https:// scheme', () async {
      final service = SettingsService();

      await service.setServerBaseUrl('https://media.anisparvez.in/');
      final savedUrl = await service.getServerBaseUrl();
      expect(savedUrl, equals('https://media.anisparvez.in'));
    });
  });
}
