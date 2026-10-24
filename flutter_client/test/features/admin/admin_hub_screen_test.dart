import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/core/device/infrastructure/device_capability_service.dart';
import 'package:media_server_client/features/admin/domain/models/audit_log_model.dart';
import 'package:media_server_client/features/admin/domain/models/connected_device_model.dart';
import 'package:media_server_client/features/admin/domain/models/library_scan_model.dart';
import 'package:media_server_client/features/admin/domain/models/storage_audit_model.dart';
import 'package:media_server_client/features/admin/domain/models/transcode_dashboard_model.dart';
import 'package:media_server_client/features/admin/data/admin_repository.dart';
import 'package:media_server_client/features/admin/presentation/controllers/connected_devices_controller.dart';
import 'package:media_server_client/features/admin/presentation/controllers/library_maintenance_controller.dart';
import 'package:media_server_client/features/admin/presentation/controllers/storage_controller.dart';
import 'package:media_server_client/features/admin/presentation/controllers/transcode_dashboard_controller.dart';
import 'package:media_server_client/features/admin/presentation/providers/admin_providers.dart';
import 'package:media_server_client/features/admin/presentation/screens/admin_hub_screen.dart';

class _FakeAdminRepository extends Fake implements AdminRepository {
  @override
  Future<StorageAuditReport> getStorageAudit({bool force = false}) async {
    return const StorageAuditReport(
      storage: ServerStorageInfo(
        percent: 60.0,
        used: 600,
        free: 400,
        total: 1000,
        usedStr: '600 GB',
        freeStr: '400 GB',
        totalStr: '1 TB',
        drives: [
          StorageDriveInfo(
            drive: 'D:',
            label: 'Flicks',
            percent: 60.0,
            used: 600,
            free: 400,
            total: 1000,
            usedStr: '600 GB',
            freeStr: '400 GB',
            totalStr: '1 TB',
          ),
        ],
      ),
      audit: CacheAuditData(
        totalOrphanedBytes: 0,
        totalOrphanedDirs: 0,
        totalActiveBytes: 1024,
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
  Future<TranscodeDashboardResponse> getTranscodeDashboard() async {
    return const TranscodeDashboardResponse(
      summary: TranscodeDashboardSummary(
        activeCount: 0,
        runningCount: 0,
        queuedCount: 0,
        totalCurrentBytes: 0,
        totalCurrentSizeStr: '0 B',
        totalEstimatedBytes: 0,
        totalEstimatedSizeStr: '0 B',
        overallEtaSeconds: 0,
        overallEtaStr: '0s',
        hardwareEngine: DualGpuHardwareInfo(
          primary: GpuEngineStatus(name: 'RX 560X', adapter: 1, backend: 'AMF', status: 'Idle'),
          secondary: GpuEngineStatus(name: 'Vega 8', adapter: 0, backend: 'AMF', status: 'Idle'),
        ),
      ),
      activeJobs: [],
      recentJobs: [],
    );
  }

  @override
  Future<DeviceListResponse> getDevices() async {
    return const DeviceListResponse(
      devices: [],
      stats: DeviceRegistryStats(
        totalDevices: 0,
        activeNow: 0,
        offlineCount: 0,
        cloudflareCount: 0,
        lanCount: 0,
        localhostCount: 0,
      ),
      currentDeviceId: 'test-dev',
    );
  }

  @override
  Future<LibraryScanStatus> getScanStatus() async {
    return const LibraryScanStatus(
      status: 'idle',
      busy: false,
      filesDiscovered: 0,
      unindexedDiscovered: 0,
      moviesIndexed: 0,
      orphansPruned: 0,
      subtitlesAcquired: 0,
      errors: 0,
    );
  }

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

  Widget buildTestableWidget({bool isTv = false}) {
    return ProviderScope(
      overrides: [
        isTvModeProvider.overrideWithValue(isTv),
        storageControllerProvider.overrideWith(() => StorageNotifier(fakeRepo)),
        transcodeDashboardControllerProvider.overrideWith(() => TranscodeDashboardNotifier(fakeRepo)),
        connectedDevicesControllerProvider.overrideWith(() => ConnectedDevicesNotifier(fakeRepo)),
        libraryMaintenanceControllerProvider.overrideWith(() => LibraryMaintenanceNotifier(fakeRepo)),
      ],
      child: const MaterialApp(
        home: AdminHubScreen(),
      ),
    );
  }

  testWidgets('AdminHubScreen renders Mobile layout and switches tabs on pill tap', (tester) async {
    await tester.pumpWidget(buildTestableWidget(isTv: false));
    await tester.pumpAndSettle();

    // Verify title and segmented pill chips
    expect(find.text('Admin Management Hub'), findsOneWidget);
    expect(find.text('Storage & Retention'), findsOneWidget);
    expect(find.text('Transcodes & Dual-GPU'), findsOneWidget);
    expect(find.text('Connected Devices'), findsOneWidget);
    expect(find.text('Library & Security'), findsOneWidget);

    // Initial tab 0 is Storage & Retention
    expect(find.text('Storage Pool Telemetry'), findsOneWidget);

    // Tap Tab 1: Transcodes
    await tester.ensureVisible(find.text('Transcodes & Dual-GPU'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transcodes & Dual-GPU'));
    await tester.pumpAndSettle();
    expect(find.text('Dual-GPU Hardware Engines'), findsOneWidget);

    // Tap Tab 2: Connected Devices
    await tester.ensureVisible(find.text('Connected Devices'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connected Devices'));
    await tester.pumpAndSettle();
    expect(find.text('Total Devices'), findsOneWidget);

    // Tap Tab 3: Library & Security
    await tester.ensureVisible(find.text('Library & Security'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Library & Security'));
    await tester.pumpAndSettle();
    expect(find.text('TMDb Library Scanner'), findsOneWidget);
  });

  testWidgets('AdminHubScreen renders TV layout with left navigation rail', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(buildTestableWidget(isTv: true));
    await tester.pumpAndSettle();

    expect(find.text('Admin Hub'), findsOneWidget);
    expect(find.text('Server Management'), findsOneWidget);
    expect(find.text('Storage & Retention'), findsOneWidget);
    expect(find.text('Transcodes & Dual-GPU'), findsOneWidget);

    // Default tab 0 Storage Pool Telemetry visible in right pane
    expect(find.text('Storage Pool Telemetry'), findsOneWidget);
  });
}
