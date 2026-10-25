import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/storage_audit_model.dart';
import '../../data/admin_repository.dart';
import '../providers/admin_providers.dart';

@immutable
class StorageState {
  final bool isLoading;
  final StorageAuditReport? report;
  final StorageRetentionSettings? settings;
  final bool isPurging;
  final PurgeResult? lastPurgeResult;
  final String? errorMessage;

  const StorageState({
    this.isLoading = false,
    this.report,
    this.settings,
    this.isPurging = false,
    this.lastPurgeResult,
    this.errorMessage,
  });

  StorageState copyWith({
    bool? isLoading,
    StorageAuditReport? report,
    StorageRetentionSettings? settings,
    bool? isPurging,
    PurgeResult? lastPurgeResult,
    String? errorMessage,
  }) {
    return StorageState(
      isLoading: isLoading ?? this.isLoading,
      report: report ?? this.report,
      settings: settings ?? this.settings,
      isPurging: isPurging ?? this.isPurging,
      lastPurgeResult: lastPurgeResult ?? this.lastPurgeResult,
      errorMessage: errorMessage,
    );
  }
}

class StorageNotifier extends Notifier<StorageState> {
  final AdminRepository? _injectedRepository;

  StorageNotifier([this._injectedRepository]);

  AdminRepository get _repo =>
      _injectedRepository ?? ref.read(adminRepositoryProvider);

  @override
  StorageState build() {
    // Initial fetch on mount
    Future.microtask(() => refresh());
    return const StorageState(isLoading: true);
  }

  Future<void> refresh({bool force = false}) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final audit = await _repo.getStorageAudit(force: force);
      final settings = await _repo.getStorageSettings();
      state = state.copyWith(
        isLoading: false,
        report: audit,
        settings: settings,
        errorMessage: null,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: e.toString(),
      );
    }
  }

  Future<bool> setRetentionPolicy(String policy) async {
    try {
      final success = await _repo.updateStorageSettings(policy);
      if (success) {
        await refresh();
        return true;
      }
      return false;
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
      return false;
    }
  }

  Future<PurgeResult?> purgeOrphans({bool dryRun = false}) async {
    state = state.copyWith(isPurging: true, errorMessage: null);
    try {
      final result = await _repo.purgeOrphanedCaches(dryRun: dryRun);
      state = state.copyWith(
        isPurging: false,
        lastPurgeResult: result,
      );
      await refresh();
      return result;
    } catch (e) {
      state = state.copyWith(
        isPurging: false,
        errorMessage: e.toString(),
      );
      return null;
    }
  }
}


