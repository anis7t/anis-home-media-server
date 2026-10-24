import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/transcode_dashboard_model.dart';
import '../../infrastructure/admin_repository.dart';
import '../providers/admin_providers.dart';

@immutable
class TranscodeDashboardState {
  final bool isLoading;
  final TranscodeDashboardResponse? data;
  final bool isActionInProgress;
  final String? errorMessage;

  const TranscodeDashboardState({
    this.isLoading = false,
    this.data,
    this.isActionInProgress = false,
    this.errorMessage,
  });

  TranscodeDashboardState copyWith({
    bool? isLoading,
    TranscodeDashboardResponse? data,
    bool? isActionInProgress,
    String? errorMessage,
  }) {
    return TranscodeDashboardState(
      isLoading: isLoading ?? this.isLoading,
      data: data ?? this.data,
      isActionInProgress: isActionInProgress ?? this.isActionInProgress,
      errorMessage: errorMessage,
    );
  }
}

class TranscodeDashboardNotifier extends Notifier<TranscodeDashboardState> {
  final AdminRepository? _injectedRepository;
  Timer? _pollingTimer;

  TranscodeDashboardNotifier([this._injectedRepository]);

  AdminRepository get _repo =>
      _injectedRepository ?? ref.read(adminRepositoryProvider);

  @override
  TranscodeDashboardState build() {
    ref.onDispose(() {
      _stopPolling();
    });

    Future.microtask(() => refresh());
    return const TranscodeDashboardState(isLoading: true);
  }

  void _stopPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  void _startPollingIfNeeded(TranscodeDashboardResponse response) {
    if (response.summary.activeCount > 0) {
      if (_pollingTimer == null || !_pollingTimer!.isActive) {
        _pollingTimer = Timer.periodic(const Duration(seconds: 2), (_) {
          refresh(silent: true);
        });
      }
    } else {
      _stopPolling();
    }
  }

  Future<void> refresh({bool silent = false}) async {
    if (!silent) {
      state = state.copyWith(isLoading: true, errorMessage: null);
    }
    try {
      final res = await _repo.getTranscodeDashboard();
      state = state.copyWith(
        isLoading: false,
        data: res,
        errorMessage: null,
      );
      _startPollingIfNeeded(res);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: e.toString(),
      );
    }
  }

  Future<bool> cancelJob(String filename) async {
    state = state.copyWith(isActionInProgress: true, errorMessage: null);
    try {
      final success = await _repo.cancelTranscodeJob(filename);
      state = state.copyWith(isActionInProgress: false);
      if (success) {
        await refresh(silent: true);
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

  Future<bool> sweepStaleJobs() async {
    state = state.copyWith(isActionInProgress: true, errorMessage: null);
    try {
      final success = await _repo.sweepStaleTranscodes();
      state = state.copyWith(isActionInProgress: false);
      if (success) {
        await refresh(silent: true);
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


