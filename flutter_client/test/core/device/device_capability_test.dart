import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/constants/storage_keys.dart';
import 'package:media_server_client/core/device/domain/device_capabilities.dart';
import 'package:media_server_client/core/device/infrastructure/device_capability_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('DeviceCapabilities Model Tests', () {
    test('mobileDefault has isTv=false and hasTouchscreen=true', () {
      const caps = DeviceCapabilities.mobileDefault;
      expect(caps.isTv, isFalse);
      expect(caps.hasTouchscreen, isTrue);
      expect(caps.isAmazonFireTv, isFalse);
      expect(caps.hasLeanbackFeature, isFalse);
    });

    test('tvDefault has isTv=true and hasLeanbackFeature=true', () {
      const caps = DeviceCapabilities.tvDefault;
      expect(caps.isTv, isTrue);
      expect(caps.hasTouchscreen, isFalse);
      expect(caps.hasLeanbackFeature, isTrue);
    });

    test('fromMap correctly parses Android TV payload', () {
      final map = {
        'isTv': true,
        'isFireTv': false,
        'hasLeanback': true,
        'hasTouchscreen': false,
        'model': 'Chromecast with Google TV',
        'manufacturer': 'Google',
      };
      final caps = DeviceCapabilities.fromMap(map);
      expect(caps.isTv, isTrue);
      expect(caps.isAmazonFireTv, isFalse);
      expect(caps.hasLeanbackFeature, isTrue);
      expect(caps.hasTouchscreen, isFalse);
      expect(caps.model, equals('Chromecast with Google TV'));
      expect(caps.manufacturer, equals('Google'));
    });

    test('fromMap correctly parses Amazon Fire TV payload', () {
      final map = {
        'isTv': true,
        'isFireTv': true,
        'hasLeanback': true,
        'hasTouchscreen': false,
        'model': 'AFTMM',
        'manufacturer': 'Amazon',
      };
      final caps = DeviceCapabilities.fromMap(map);
      expect(caps.isTv, isTrue);
      expect(caps.isAmazonFireTv, isTrue);
      expect(caps.model, equals('AFTMM'));
    });

    test('fromMap handles null gracefully by returning mobileDefault', () {
      final caps = DeviceCapabilities.fromMap(null);
      expect(caps.isTv, isFalse);
      expect(caps.hasTouchscreen, isTrue);
    });
  });

  group('DeviceCapabilityService Tests', () {
    test('detect reads SharedPreferences debug override when set to true', () async {
      SharedPreferences.setMockInitialValues({
        StorageKeys.debugTvModeOverride: true,
      });
      final prefs = await SharedPreferences.getInstance();
      final caps = await DeviceCapabilityService.detect(prefs: prefs);
      expect(caps.isTv, isTrue);
    });

    test('detect reads SharedPreferences debug override when set to false', () async {
      SharedPreferences.setMockInitialValues({
        StorageKeys.debugTvModeOverride: false,
      });
      final prefs = await SharedPreferences.getInstance();
      final caps = await DeviceCapabilityService.detect(prefs: prefs);
      expect(caps.isTv, isFalse);
      expect(caps.hasTouchscreen, isTrue);
    });

    test('Riverpod providers reflect active capabilities', () {
      final container = ProviderContainer(
        overrides: [
          deviceCapabilitiesProvider.overrideWithValue(
            const DeviceCapabilities(
              isTv: true,
              isAmazonFireTv: true,
              hasTouchscreen: false,
              hasLeanbackFeature: true,
              model: 'AFTMM',
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(deviceCapabilitiesProvider).isTv, isTrue);
      expect(container.read(isTvModeProvider), isTrue);
      expect(container.read(isFireTvProvider), isTrue);
    });
  });
}
