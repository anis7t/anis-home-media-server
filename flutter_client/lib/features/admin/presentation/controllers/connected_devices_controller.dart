import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/connected_device_model.dart';
import '../../infrastructure/admin_repository.dart';
import '../providers/admin_providers.dart';

@immutable
class ConnectedDevicesState {
  final bool isLoading;
  final DeviceListResponse? data;
  final bool isActionInProgress;
  final String? errorMessage;

  const ConnectedDevicesState({
    this.isLoading = false,
    this.data,
    this.isActionInProgress = false,
    this.errorMessage,
  });

  ConnectedDevicesState copyWith({
    bool? isLoading,
    DeviceListResponse? data,
    bool? isActionInProgress,
    String? errorMessage,
  }) {
    return ConnectedDevicesState(
      isLoading: isLoading ?? this.isLoading,
      data: data ?? this.data,
      isActionInProgress: isActionInProgress ?? this.isActionInProgress,
      errorMessage: errorMessage,
    );
  }
}

class ConnectedDevicesNotifier extends Notifier<ConnectedDevicesState> {
  final AdminRepository? _injectedRepository;

  ConnectedDevicesNotifier([this._injectedRepository]);

  AdminRepository get _repo =>
      _injectedRepository ?? ref.read(adminRepositoryProvider);

  @override
  ConnectedDevicesState build() {
    Future.microtask(() => refresh());
    return const ConnectedDevicesState(isLoading: true);
  }

  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final res = await _repo.getDevices();
      state = state.copyWith(
        isLoading: false,
        data: res,
        errorMessage: null,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: e.toString(),
      );
    }
  }

  Future<bool> renameDevice(String deviceId, String newName) async {
    state = state.copyWith(isActionInProgress: true, errorMessage: null);
    try {
      final success = await _repo.renameDevice(deviceId, newName);
      state = state.copyWith(isActionInProgress: false);
      if (success) {
        await refresh();
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

  Future<bool> deleteDevice(String deviceId) async {
    state = state.copyWith(isActionInProgress: true, errorMessage: null);
    try {
      final success = await _repo.deleteDevice(deviceId);
      state = state.copyWith(isActionInProgress: false);
      if (success) {
        await refresh();
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


