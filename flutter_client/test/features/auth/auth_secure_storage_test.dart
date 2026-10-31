import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/constants/storage_keys.dart';
import 'package:media_server_client/features/auth/data/auth_secure_storage.dart';

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

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
  }) async {
    memory.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AuthSecureStorage', () {
    late MockSecureStorage mockStorage;
    late AuthSecureStorage authStorage;

    setUp(() {
      mockStorage = MockSecureStorage();
      authStorage = AuthSecureStorage(secureStorage: mockStorage);
    });

    test('stores, retrieves, and clears session token', () async {
      expect(await authStorage.getSessionToken(), isNull);

      const token = 'sess_abcdef0123456789';
      await authStorage.saveSessionToken(token);

      expect(await authStorage.getSessionToken(), equals(token));
      expect(mockStorage.memory[StorageKeys.sessionToken], equals(token));

      await authStorage.clearSessionToken();
      expect(await authStorage.getSessionToken(), isNull);
      expect(mockStorage.memory.containsKey(StorageKeys.sessionToken), isFalse);
    });

    test('getAdminPin always returns null and saveAdminPin is a no-op (OTPs not persisted)', () async {
      expect(await authStorage.getAdminPin(), isNull);

      const pin = '123456';
      await authStorage.saveAdminPin(pin);

      expect(await authStorage.getAdminPin(), isNull);
      expect(mockStorage.memory.containsKey(StorageKeys.adminPin), isFalse);

      await authStorage.clearAdminPin();
      expect(await authStorage.getAdminPin(), isNull);
    });

    test('clearAll wipes session token and clears admin pin key', () async {
      await authStorage.saveSessionToken('sess_test_123');
      mockStorage.memory[StorageKeys.adminPin] = 'legacy_pin';

      expect(await authStorage.getSessionToken(), equals('sess_test_123'));

      await authStorage.clearAll();

      expect(await authStorage.getSessionToken(), isNull);
      expect(await authStorage.getAdminPin(), isNull);
      expect(mockStorage.memory.containsKey(StorageKeys.adminPin), isFalse);
    });
  });
}
