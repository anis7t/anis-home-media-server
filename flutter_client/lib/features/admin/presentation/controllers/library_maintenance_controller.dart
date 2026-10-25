import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/audit_log_model.dart';
import '../../domain/models/library_scan_model.dart';
import '../../data/admin_repository.dart';
import '../providers/admin_providers.dart';

@immutable
class LibraryMaintenanceState {
  final bool isLoading;
  final LibraryScanStatus? scanStatus;
  final AuditLogResponse? auditLogs;
  final bool isActionInProgress;
  final String? errorMessage;

  const LibraryMaintenanceState({
    this.isLoading = false,
    this.scanStatus,
    this.auditLogs,
    this.isActionInProgress = false,
    this.errorMessage,
  });

  bool get isScanning => scanStatus?.isScanning ?? false;

  LibraryMaintenanceState copyWith({
    bool? isLoading,
    LibraryScanStatus? scanStatus,
    AuditLogResponse? auditLogs,
    bool? isActionInProgress,
    String? errorMessage,
  }) {
    return LibraryMaintenanceState(
      isLoading: isLoading ?? this.isLoading,
      scanStatus: scanStatus ?? this.scanStatus,
      auditLogs: auditLogs ?? this.auditLogs,
      isActionInProgress: isActionInProgress ?? this.isActionInProgress,
      errorMessage: errorMessage,
    );
  }
}

class LibraryMaintenanceNotifier extends Notifier<LibraryMaintenanceState> {
  final AdminRepository? _injectedRepository;
  Timer? _scanPollTimer;

  LibraryMaintenanceNotifier([this._injectedRepository]);

  AdminRepository get _repo =>
      _injectedRepository ?? ref.read(adminRepositoryProvider);

  @override
  LibraryMaintenanceState build() {
    ref.onDispose(() {
      _stopPolling();
    });

    Future.microtask(() => refresh());
    return const LibraryMaintenanceState(isLoading: true);
  }

  void _stopPolling() {
    _scanPollTimer?.cancel();
    _scanPollTimer = null;
  }

  void _startPollingIfNeeded(LibraryScanStatus status) {
    if (status.isScanning) {
      if (_scanPollTimer == null || !_scanPollTimer!.isActive) {
        _scanPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
          refreshScanStatus();
        });
      }
    } else {
      _stopPolling();
    }
  }

  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final scanStatus = await _repo.getScanStatus();
      final logs = await _repo.getAuditLogs();
      state = state.copyWith(
        isLoading: false,
        scanStatus: scanStatus,
        auditLogs: logs,
        errorMessage: null,
      );
      _startPollingIfNeeded(scanStatus);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> refreshScanStatus() async {
    try {
      final scanStatus = await _repo.getScanStatus();
      state = state.copyWith(scanStatus: scanStatus);
      _startPollingIfNeeded(scanStatus);
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  Future<bool> triggerScan() async {
    state = state.copyWith(isActionInProgress: true, errorMessage: null);
    try {
      final success = await _repo.triggerScan();
      state = state.copyWith(isActionInProgress: false);
      if (success) {
        await refreshScanStatus();
        return true;
      }
      return false;
    } catch (e) {
      state = state.copyWith(
        isActionInProgress: false,
        errorMessage: e.toString(),
      );
      return false;
    }
  }

  Future<bool> changeAdminPin(String currentPin, String newPin) async {
    state = state.copyWith(isActionInProgress: true, errorMessage: null);
    try {
      final success = await _repo.updateAdminPin(currentPin, newPin);
      state = state.copyWith(isActionInProgress: false);
      if (success) {
        final logs = await _repo.getAuditLogs();
        state = state.copyWith(auditLogs: logs);
        return true;
      }
      return false;
    } catch (e) {
      state = state.copyWith(
        isActionInProgress: false,
        errorMessage: e.toString(),
      );
      return false;
    }
  }
}


