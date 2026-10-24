import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_client.dart';
import '../../infrastructure/admin_repository.dart';
import '../controllers/connected_devices_controller.dart';
import '../controllers/library_maintenance_controller.dart';
import '../controllers/storage_controller.dart';
import '../controllers/transcode_dashboard_controller.dart';

/// Central AdminRepository provider.
final adminRepositoryProvider = Provider<AdminRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return AdminRepository(apiClient);
});

/// Currently selected section tab in AdminHubScreen:
/// 0: Storage & Retention
/// 1: Transcodes & Dual-GPU
/// 2: Connected Devices
/// 3: Library & Security
final adminHubTabProvider = NotifierProvider<AdminHubTabNotifier, int>(() {
  return AdminHubTabNotifier();
});

class AdminHubTabNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void selectTab(int index) {
    state = index;
  }
}

/// Provider for storage telemetry and cache retention management.
final storageControllerProvider =
    NotifierProvider<StorageNotifier, StorageState>(() {
  return StorageNotifier();
});

/// Provider for real-time transcode dashboard and dual-GPU telemetry.
final transcodeDashboardControllerProvider =
    NotifierProvider<TranscodeDashboardNotifier, TranscodeDashboardState>(() {
  return TranscodeDashboardNotifier();
});

/// Provider for registered client devices management.
final connectedDevicesControllerProvider =
    NotifierProvider<ConnectedDevicesNotifier, ConnectedDevicesState>(() {
  return ConnectedDevicesNotifier();
});

/// Provider for library scanning, PIN rotation, and security audit logs.
final libraryMaintenanceControllerProvider =
    NotifierProvider<LibraryMaintenanceNotifier, LibraryMaintenanceState>(() {
  return LibraryMaintenanceNotifier();
});
