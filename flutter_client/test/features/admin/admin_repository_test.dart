import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/api/api_client.dart';
import 'package:media_server_client/core/api/api_endpoints.dart';
import 'package:media_server_client/core/api/api_interceptors.dart';
import 'package:media_server_client/core/storage/device_identity_service.dart';
import 'package:media_server_client/features/admin/infrastructure/admin_repository.dart';
import 'package:media_server_client/features/auth/infrastructure/auth_secure_storage.dart';
import '../auth/auth_secure_storage_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSecureStorage mockSecureStorage;
  late AuthSecureStorage authSecureStorage;
  late DeviceIdentityService deviceService;
  late DeviceAuthInterceptor authInterceptor;

  setUp(() {
    mockSecureStorage = MockSecureStorage();
    authSecureStorage = AuthSecureStorage(secureStorage: mockSecureStorage);
    deviceService = DeviceIdentityService(secureStorage: mockSecureStorage);
    authInterceptor = DeviceAuthInterceptor(
      deviceService,
      secureStorage: authSecureStorage,
    );
  });

  ApiClient createMockApiClient(
    Future<Response<dynamic>> Function(RequestOptions options) handler,
  ) {
    final customDio = Dio(BaseOptions(baseUrl: 'http://test.invalid:8000'));
    customDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, reqHandler) async {
          try {
            final res = await handler(options);
            reqHandler.resolve(res);
          } on DioException catch (e) {
            reqHandler.reject(e);
          } catch (e) {
            reqHandler.reject(DioException(requestOptions: options, error: e));
          }
        },
      ),
    );

    return ApiClient(
      baseUrl: 'http://test.invalid:8000',
      authInterceptor: authInterceptor,
      customDio: customDio,
    );
  }

  group('AdminRepository - Storage', () {
    test('getStorageAudit requests audit endpoint and parses report', () async {
      final apiClient = createMockApiClient((options) async {
        expect(options.path, equals(ApiEndpoints.storageAudit));
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'storage': {
              'percent': 50.0,
              'used': 500,
              'free': 500,
              'total': 1000,
              'used_str': '500 GB',
              'free_str': '500 GB',
              'total_str': '1 TB',
              'drives': [],
            },
            'audit': {
              'total_orphaned_bytes': 1024,
              'total_orphaned_dirs': 1,
              'total_active_bytes': 2048,
              'total_active_dirs': 1,
              'degraded': false,
              'degraded_reasons': [],
            },
          },
        );
      });

      final repo = AdminRepository(apiClient);
      final report = await repo.getStorageAudit();
      expect(report.storage.percent, 50.0);
      expect(report.audit.totalOrphanedBytes, 1024);
    });

    test('getStorageSettings and updateStorageSettings work as expected', () async {
      final apiClient = createMockApiClient((options) async {
        if (options.method == 'GET') {
          expect(options.path, equals(ApiEndpoints.storageSettings));
          return Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'retention_policy': 'keep',
              'allowed_policies': ['keep', 'archive', 'purge_cache'],
              'archive_dir': '',
            },
          );
        } else {
          expect(options.path, equals(ApiEndpoints.storageSettings));
          expect((options.data as Map)['retention_policy'], 'purge_cache');
          return Response(requestOptions: options, statusCode: 200, data: {'success': true});
        }
      });

      final repo = AdminRepository(apiClient);
      final settings = await repo.getStorageSettings();
      expect(settings.retentionPolicy, 'keep');

      final updated = await repo.updateStorageSettings('purge_cache');
      expect(updated, isTrue);
    });

    test('purgeOrphanedCaches calls purge endpoint with dry_run flag', () async {
      final apiClient = createMockApiClient((options) async {
        expect(options.path, equals(ApiEndpoints.storagePurgeOrphans));
        expect((options.data as Map)['dry_run'], isFalse);
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'success': true,
            'result': {
              'freed_bytes': 4096,
              'purged_count': 2,
              'dry_run': false,
            },
          },
        );
      });

      final repo = AdminRepository(apiClient);
      final result = await repo.purgeOrphanedCaches(dryRun: false);
      expect(result.freedBytes, 4096);
      expect(result.purgedCount, 2);
    });
  });

  group('AdminRepository - Transcodes', () {
    test('getTranscodeDashboard returns full telemetry', () async {
      final apiClient = createMockApiClient((options) async {
        expect(options.path, equals(ApiEndpoints.transcodeDashboard));
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'summary': {
              'active_count': 1,
              'running_count': 1,
              'queued_count': 0,
              'total_current_bytes': 1000,
              'total_current_size_str': '1 KB',
              'total_estimated_bytes': 2000,
              'total_estimated_size_str': '2 KB',
              'overall_eta_seconds': 60.0,
              'overall_eta_str': '1m',
              'hardware_engine': {
                'primary': {'name': 'GPU 1', 'adapter': 1, 'backend': 'AMF', 'status': 'Active'},
                'secondary': {'name': 'GPU 2', 'adapter': 0, 'backend': 'AMF', 'status': 'Idle'},
              },
            },
            'active_jobs': [],
            'recent_jobs': [],
          },
        );
      });

      final repo = AdminRepository(apiClient);
      final data = await repo.getTranscodeDashboard();
      expect(data.summary.activeCount, 1);
      expect(data.summary.hardwareEngine.primary.name, 'GPU 1');
    });

    test('cancelTranscodeJob and sweepStaleTranscodes post to backend', () async {
      final apiClient = createMockApiClient((options) async {
        if (options.path.contains('/cancel')) {
          expect(options.path, contains('test.mkv'));
          return Response(requestOptions: options, statusCode: 200, data: {'success': true});
        } else {
          expect(options.path, equals(ApiEndpoints.transcodeSweep));
          return Response(requestOptions: options, statusCode: 200, data: {'success': true});
        }
      });

      final repo = AdminRepository(apiClient);
      final canceled = await repo.cancelTranscodeJob('test.mkv');
      expect(canceled, isTrue);

      final swept = await repo.sweepStaleTranscodes();
      expect(swept, isTrue);
    });
  });

  group('AdminRepository - Devices', () {
    test('getDevices, renameDevice, deleteDevice succeed', () async {
      final apiClient = createMockApiClient((options) async {
        if (options.method == 'GET') {
          return Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'devices': [
                {
                  'device_id': 'd1',
                  'display_name': 'My Phone',
                  'device_icon': 'phone',
                  'first_seen': '2026-10-01',
                  'last_seen': '2026-10-24',
                  'last_seen_ago': 'now',
                  'is_active': true,
                  'is_current': true,
                }
              ],
              'stats': {
                'total_devices': 1,
                'active_now': 1,
                'offline_count': 0,
                'cloudflare_count': 0,
                'lan_count': 1,
                'localhost_count': 0,
              },
              'current_device_id': 'd1',
            },
          );
        } else if (options.path == ApiEndpoints.deviceRename) {
          expect((options.data as Map)['name'], 'Living Room TV');
          return Response(requestOptions: options, statusCode: 200, data: {'success': true});
        } else {
          expect(options.path, equals(ApiEndpoints.deviceDelete));
          return Response(requestOptions: options, statusCode: 200, data: {'success': true});
        }
      });

      final repo = AdminRepository(apiClient);
      final list = await repo.getDevices();
      expect(list.devices.length, 1);
      expect(list.devices.first.displayName, 'My Phone');

      final renamed = await repo.renameDevice('d1', 'Living Room TV');
      expect(renamed, isTrue);

      final deleted = await repo.deleteDevice('d1');
      expect(deleted, isTrue);
    });
  });

  group('AdminRepository - Library Maintenance & Security', () {
    test('getScanStatus and triggerScan communicate with scan routes', () async {
      final apiClient = createMockApiClient((options) async {
        if (options.method == 'GET') {
          return Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'status': 'idle',
              'busy': false,
              'files_discovered': 20,
              'unindexed_discovered': 0,
              'movies_indexed': 20,
              'orphans_pruned': 0,
              'subtitles_acquired': 15,
              'errors': 0,
            },
          );
        } else {
          return Response(requestOptions: options, statusCode: 200, data: {'started': true});
        }
      });

      final repo = AdminRepository(apiClient);
      final status = await repo.getScanStatus();
      expect(status.moviesIndexed, 20);

      final triggered = await repo.triggerScan();
      expect(triggered, isTrue);
    });

    test('updateAdminPin and getAuditLogs succeed', () async {
      final apiClient = createMockApiClient((options) async {
        if (options.path == ApiEndpoints.adminPin) {
          expect((options.data as Map)['new_pin'], '9999');
          return Response(requestOptions: options, statusCode: 200, data: {'success': true});
        } else {
          return Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'logs': [],
              'total': 0,
              'limit': 50,
              'offset': 0,
            },
          );
        }
      });

      final repo = AdminRepository(apiClient);
      final pinUpdated = await repo.updateAdminPin('0000', '9999');
      expect(pinUpdated, isTrue);

      final logs = await repo.getAuditLogs();
      expect(logs.total, 0);
    });
  });
}
