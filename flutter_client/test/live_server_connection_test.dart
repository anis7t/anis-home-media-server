import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
  });

  test('Live integration test: Connect to local media server and verify Device ID', () async {
    final deviceService = DeviceIdentityService();
    final deviceId = await deviceService.getOrCreateDeviceId();

    // Verify cryptographic format: dev_<16 lowercase hex>
    expect(DeviceIdentityService.isValidDeviceId(deviceId), isTrue);

    final interceptor = DeviceAuthInterceptor(deviceService);
    final apiClient = ApiClient(
      baseUrl: 'http://127.0.0.1:8000',
      authInterceptor: interceptor,
    );

    // 1. Test connectivity to live Waitress service
    final result = await apiClient.testConnection();

    debugPrint('----------------------------------------------------');
    debugPrint('Live Server Connection Result:');
    debugPrint('  Success: ${result.success}');
    debugPrint('  Latency: ${result.latencyMs} ms');
    debugPrint('  Hostname: ${result.hostname}');
    debugPrint('  Server Status: ${result.status}');
    debugPrint('  Device ID: $deviceId');
    debugPrint('----------------------------------------------------');

    expect(result.success, isTrue, reason: 'Failed to connect to local media server: ${result.errorMessage}');
    expect(result.latencyMs, greaterThan(0));

    // 2. Send heartbeat with X-Device-Id header to register device on server
    final heartbeatRes = await apiClient.dio.post('http://127.0.0.1:8000/api/devices/heartbeat');
    expect(heartbeatRes.statusCode, equals(200));
    expect(heartbeatRes.data['device_id'], equals(deviceId));

    // 3. Query GET /api/devices and verify server recognized our persistent device ID
    final devicesResponse = await apiClient.dio.get('http://127.0.0.1:8000/api/devices');
    expect(devicesResponse.statusCode, equals(200));
    expect(devicesResponse.data, isA<Map>());

    final devicesData = devicesResponse.data as Map<String, dynamic>;
    final devicesList = devicesData['devices'] as List<dynamic>?;
    expect(devicesList, isNotNull);

    debugPrint('Registered devices found on server: ${devicesList?.length}');
    final matched = devicesList?.any((d) => d['device_id'] == deviceId || d['client_id'] == deviceId || d['id'] == deviceId);
    debugPrint('Our persistent device ID ($deviceId) registered on server: $matched');
    expect(matched, isTrue, reason: 'Device ID was not found in server devices registry');
  });
}
