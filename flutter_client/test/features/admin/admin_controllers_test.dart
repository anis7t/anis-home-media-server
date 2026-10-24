import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/admin/domain/models/audit_log_model.dart';
import 'package:media_server_client/features/admin/domain/models/connected_device_model.dart';
import 'package:media_server_client/features/admin/domain/models/library_scan_model.dart';
import 'package:media_server_client/features/admin/domain/models/storage_audit_model.dart';
import 'package:media_server_client/features/admin/domain/models/transcode_dashboard_model.dart';
import 'package:media_server_client/features/admin/infrastructure/admin_repository.dart';
import 'package:media_server_client/features/admin/presentation/controllers/connected_devices_controller.dart';
import 'package:media_server_client/features/admin/presentation/controllers/library_maintenance_controller.dart';
import 'package:media_server_client/features/admin/presentation/controllers/storage_controller.dart';
import 'package:media_server_client/features/admin/presentation/controllers/transcode_dashboard_controller.dart';
import 'package:media_server_client/features/admin/presentation/providers/admin_providers.dart';

class _FakeAdminRepository extends Fake implements AdminRepository {
  @override
  Future<StorageAuditReport> getStorageAudit({bool force = false}) async {
    return const StorageAuditReport(
      storage: ServerStorageInfo(
        percent: 50.0,
        used: 500,
        free: 500,
        total: 1000,
        usedStr: '500 GB',
        freeStr: '500 GB',
        totalStr: '1 TB',
        drives: [],
      ),
      audit: CacheAuditData(
        totalOrphanedBytes: 1024,
        totalOrphanedDirs: 1,
        totalActiveBytes: 2048,
        totalActiveDirs: 1,
        degraded: false,
        degradedReasons: [],
      ),
    );
  }

  @override
  Future<StorageRetentionSettings> getStorageSettings() async {
    return const StorageRetentionSettings(
      retentionPolicy: 'keep',
      allowedPolicies: ['keep', 'archive', 'purge_cache'],
      archiveDir: '',
    );
  }

  @override
  Future<bool> updateStorageSettings(String policy, {String? adminPin}) async {
    return true;
  }

  @override
  Future<PurgeResult> purgeOrphanedCaches({bool dryRun = false, String? adminPin}) async {
    return const PurgeResult(freedBytes: 1024, purgedCount: 1, dryRun: false);
  }

  @override
  Future<TranscodeDashboardResponse> getTranscodeDashboard() async {
    return const TranscodeDashboardResponse(
      summary: TranscodeDashboardSummary(
        activeCount: 1,
        runningCount: 1,
        queuedCount: 0,
        totalCurrentBytes: 100,
        totalCurrentSizeStr: '100 B',
        totalEstimatedBytes: 200,
        totalEstimatedSizeStr: '200 B',
        overallEtaSeconds: 60,
        overallEtaStr: '1m',
        hardwareEngine: DualGpuHardwareInfo(
          primary: GpuEngineStatus(name: 'GPU 1', adapter: 1, backend: 'AMF', status: 'Active'),
          secondary: GpuEngineStatus(name: 'GPU 2', adapter: 0, backend: 'AMF', status: 'Idle'),
        ),
      ),
      activeJobs: [],
      recentJobs: [],
    );
  }

  @override
  Future<bool> cancelTranscodeJob(String filename) async => true;

  @override
  Future<bool> sweepStaleTranscodes() async => true;

  @override
  Future<DeviceListResponse> getDevices() async {
    return const DeviceListResponse(
      devices: [
        ConnectedDevice(
          deviceId: 'd1',
          displayName: 'Phone',
          deviceIcon: 'phone',
          firstSeen: '2026-10-01',
          lastSeen: '2026-10-24',
          lastSeenAgo: 'now',
          isActive: true,
          isCurrent: true,
        ),
      ],
      stats: DeviceRegistryStats(
        totalDevices: 1,
        activeNow: 1,
        offlineCount: 0,
        cloudflareCount: 0,
        lanCount: 1,
        localhostCount: 0,
      ),
      currentDeviceId: 'd1',
    );
  }

  @override
  Future<bool> renameDevice(String deviceId, String name) async => true;

  @override
  Future<bool> deleteDevice(String deviceId) async => true;

  @override
  Future<LibraryScanStatus> getScanStatus() async {
    return const LibraryScanStatus(
      status: 'idle',
      busy: false,
      filesDiscovered: 10,
      unindexedDiscovered: 0,
      moviesIndexed: 10,
      orphansPruned: 0,
      subtitlesAcquired: 10,
      errors: 0,
    );
  }

  @override
  Future<bool> triggerScan({String? adminPin}) async => true;

  @override
  Future<bool> updateAdminPin(String currentPin, String newPin) async => true;

  @override
  Future<AuditLogResponse> getAuditLogs({int limit = 50, int offset = 0, String? action}) async {
    return const AuditLogResponse(logs: [], total: 0, limit: 50, offset: 0);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAdminRepository fakeRepo;

  setUp(() {
    fakeRepo = _FakeAdminRepository();
  });

  test('StorageNotifier loads report, updates retention, and purges orphans', () async {
    final container = ProviderContainer(
      overrides: [
        storageControllerProvider.overrideWith(() => StorageNotifier(fakeRepo)),
      ],
    );
    addTearDown(container.dispose);

    // Initial load
    await container.read(storageControllerProvider.notifier).refresh();
    final state = container.read(storageControllerProvider);
    expect(state.isLoading, isFalse);
    expect(state.report?.storage.percent, 50.0);
    expect(state.settings?.retentionPolicy, 'keep');

    // Update retention
    final updated = await container.read(storageControllerProvider.notifier).setRetentionPolicy('purge_cache');
    expect(updated, isTrue);

    // Purge orphans
    final purgeResult = await container.read(storageControllerProvider.notifier).purgeOrphans();
    expect(purgeResult?.freedBytes, 1024);
  });

  test('TranscodeDashboardNotifier loads dashboard and cancels job', () async {
    final container = ProviderContainer(
      overrides: [
        transcodeDashboardControllerProvider.overrideWith(() => TranscodeDashboardNotifier(fakeRepo)),
      ],
    );
    addTearDown(container.dispose);

    await container.read(transcodeDashboardControllerProvider.notifier).refresh();
    final state = container.read(transcodeDashboardControllerProvider);
    expect(state.data?.summary.activeCount, 1);

    final canceled = await container.read(transcodeDashboardControllerProvider.notifier).cancelJob('movie.mkv');
    expect(canceled, isTrue);

    final swept = await container.read(transcodeDashboardControllerProvider.notifier).sweepStaleJobs();
    expect(swept, isTrue);
  });

  test('ConnectedDevicesNotifier renames and deletes device', () async {
    final container = ProviderContainer(
      overrides: [
        connectedDevicesControllerProvider.overrideWith(() => ConnectedDevicesNotifier(fakeRepo)),
      ],
    );
    addTearDown(container.dispose);

    await container.read(connectedDevicesControllerProvider.notifier).refresh();
    final state = container.read(connectedDevicesControllerProvider);
    expect(state.data?.devices.length, 1);

    final renamed = await container.read(connectedDevicesControllerProvider.notifier).renameDevice('d1', 'Living Room');
    expect(renamed, isTrue);

    final deleted = await container.read(connectedDevicesControllerProvider.notifier).deleteDevice('d1');
    expect(deleted, isTrue);
  });

  test('LibraryMaintenanceNotifier triggers scan and rotates PIN', () async {
    final container = ProviderContainer(
      overrides: [
        libraryMaintenanceControllerProvider.overrideWith(() => LibraryMaintenanceNotifier(fakeRepo)),
      ],
    );
    addTearDown(container.dispose);

    await container.read(libraryMaintenanceControllerProvider.notifier).refresh();
    final state = container.read(libraryMaintenanceControllerProvider);
    expect(state.scanStatus?.moviesIndexed, 10);

    final triggered = await container.read(libraryMaintenanceControllerProvider.notifier).triggerScan();
    expect(triggered, isTrue);

    final pinRotated = await container.read(libraryMaintenanceControllerProvider.notifier).changeAdminPin('0000', '1234');
    expect(pinRotated, isTrue);
  });

  test('AdminHubTabNotifier selects tabs cleanly', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(adminHubTabProvider), 0);
    container.read(adminHubTabProvider.notifier).selectTab(2);
    expect(container.read(adminHubTabProvider), 2);
  });
}
