import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/constants/storage_keys.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';

class MockSecureStorage extends FlutterSecureStorage {
  final Map<String, String> memory = {};

  MockSecureStorage([Map<String, String>? initial]) {
    if (initial != null) memory.addAll(initial);
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
  }) async =>
      memory[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
  }) async {
    if (value != null) {
      memory[key] = value;
    } else {
      memory.remove(key);
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
  }) async {
    memory.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceIdentityService - Cryptographic Format & Entropy', () {
    test('generateSecureDeviceId produces dev_<16 lowercase hex>', () {
      final id = DeviceIdentityService.generateSecureDeviceId();

      expect(id, startsWith('dev_'));
      expect(id.length, equals(20)); // 'dev_' (4) + 16 hex = 20 chars
      expect(DeviceIdentityService.deviceIdRegex.hasMatch(id), isTrue);
    });

    test('1000 generated IDs are strictly unique and valid', () {
      final generated = <String>{};
      for (int i = 0; i < 1000; i++) {
        final id = DeviceIdentityService.generateSecureDeviceId();
        expect(DeviceIdentityService.isValidDeviceId(id), isTrue);
        expect(generated.contains(id), isFalse, reason: 'Duplicate ID generated');
        generated.add(id);
      }
      expect(generated.length, equals(1000));
    });

    test('isValidDeviceId validation table', () {
      expect(DeviceIdentityService.isValidDeviceId('dev_0123456789abcdef'), isTrue);
      expect(DeviceIdentityService.isValidDeviceId('dev_9f8e7d6c5b4a3210'), isTrue);
      expect(DeviceIdentityService.isValidDeviceId('dev_ffffffffffffffff'), isTrue);

      // Rejections:
      expect(DeviceIdentityService.isValidDeviceId(null), isFalse);
      expect(DeviceIdentityService.isValidDeviceId(''), isFalse);
      expect(DeviceIdentityService.isValidDeviceId('dev_12345'), isFalse); // too short
      expect(DeviceIdentityService.isValidDeviceId('dev_0123456789ABCDEF'), isFalse); // uppercase
      expect(DeviceIdentityService.isValidDeviceId('usr_0123456789abcdef'), isFalse); // wrong prefix
      expect(DeviceIdentityService.isValidDeviceId('dev_0123456789abcdef01'), isFalse); // too long
      expect(
        DeviceIdentityService.isValidDeviceId('550e8400-e29b-41d4-a716-446655440000'),
        isFalse, // standard UUID rejected
      );
      expect(
        DeviceIdentityService.isValidDeviceId('dev_550e8400e29b41d4'),
        isTrue, // 16 valid hex with dev_ prefix is valid
      );
    });
  });

  group('DeviceIdentityService - Persistence & Restart Lifecycle', () {
    test('Generates new ID when storage is empty and persists it', () async {
      final mockStorage = MockSecureStorage();
      final service = DeviceIdentityService(
        secureStorage: mockStorage,
      );

      expect(mockStorage.memory[StorageKeys.deviceId], isNull);

      final deviceId = await service.getOrCreateDeviceId();
      expect(DeviceIdentityService.isValidDeviceId(deviceId), isTrue);
      expect(mockStorage.memory[StorageKeys.deviceId], equals(deviceId));
    });

    test('Survives simulated application restart and reuses exact same ID', () async {
      // Shared persistent backing store across simulated process restarts
      final persistentStore = MockSecureStorage();

      // Session 1: First app launch
      final serviceSession1 = DeviceIdentityService(
        secureStorage: persistentStore,
      );

      final idSession1 = await serviceSession1.getOrCreateDeviceId();
      expect(DeviceIdentityService.isValidDeviceId(idSession1), isTrue);

      // Session 2: Cold app restart with new service instance
      final serviceSession2 = DeviceIdentityService(
        secureStorage: persistentStore,
      );

      final idSession2 = await serviceSession2.getOrCreateDeviceId();

      // Invariant: Must return the EXACT same ID on restart
      expect(idSession2, equals(idSession1));

      // Session 3: Multiple subsequent requests in same session reuse ID
      final idSession2Subsequent = await serviceSession2.getOrCreateDeviceId();
      expect(idSession2Subsequent, equals(idSession1));
    });

    test('Preserves pre-existing valid device ID without overwriting', () async {
      const existingId = 'dev_a1b2c3d4e5f67890';
      final mockStorage = MockSecureStorage({
        StorageKeys.deviceId: existingId,
      });

      final service = DeviceIdentityService(
        secureStorage: mockStorage,
      );

      final resultId = await service.getOrCreateDeviceId();
      expect(resultId, equals(existingId));
      expect(mockStorage.memory[StorageKeys.deviceId], equals(existingId));
    });

    test('Overwrites invalid corrupted stored ID with new cryptographically valid ID', () async {
      final mockStorage = MockSecureStorage({
        StorageKeys.deviceId: 'corrupted_or_truncated_uuid',
      });

      final service = DeviceIdentityService(
        secureStorage: mockStorage,
      );

      final newId = await service.getOrCreateDeviceId();
      expect(DeviceIdentityService.isValidDeviceId(newId), isTrue);
      expect(newId, isNot(equals('corrupted_or_truncated_uuid')));
      expect(mockStorage.memory[StorageKeys.deviceId], equals(newId));
    });
  });
}
