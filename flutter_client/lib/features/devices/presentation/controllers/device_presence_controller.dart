import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_client.dart';
import '../../../../core/storage/settings_service.dart';
import '../../data/repositories/device_repository.dart';

/// Keeps this device registered in the server's Connected Devices dashboard.
///
/// Mirrors the web client's contract (`templates/library.html`): one immediate
/// ping when tracking starts, then one every [heartbeatInterval] while the app
/// is in the foreground, plus an immediate ping when it returns to the
/// foreground. Nothing is sent while the app is backgrounded, the timer is
/// cancelled on dispose, and a ping is never allowed to overlap the previous
/// one - so the cadence costs at most one small POST per interval.
class DevicePresenceController extends Notifier<DateTime?> {
  /// Same cadence as the web client's `setInterval(pingHeartbeat, 45000)`.
  static const Duration heartbeatInterval = Duration(seconds: 45);

  Timer? _timer;
  bool _inFlight = false;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  @override
  DateTime? build() {
    ref.onDispose(_stopTimer);
    Future.microtask(start);
    return null;
  }

  DeviceRepository get _repository => ref.read(deviceRepositoryProvider);

  /// Whether periodic pings are currently scheduled.
  bool get isTracking => _timer != null;

  /// Starts presence tracking (idempotent): schedules the periodic ping and
  /// sends the registration ping immediately.
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(heartbeatInterval, (_) => _ping());
    _ping();
  }

  /// Stops the periodic ping without disposing the controller.
  void stop() => _stopTimer();

  /// Foreground/background transitions: tracking only runs while resumed.
  void handleLifecycle(AppLifecycleState state) {
    _lifecycle = state;
    if (state == AppLifecycleState.resumed) {
      start();
      // Immediate ping on foreground (deduped while a ping is in flight).
      _ping();
    } else {
      _stopTimer();
    }
  }

  /// Sends one ping now (manual refresh / tests).
  Future<void> pingNow() => _ping();

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _ping() async {
    if (_inFlight) return;
    if (_lifecycle != AppLifecycleState.resumed) return;

    _inFlight = true;
    try {
      final acknowledged = await _repository.sendHeartbeat();
      if (acknowledged) {
        state = DateTime.now();
      }
    } finally {
      _inFlight = false;
    }
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final deviceRepositoryProvider = Provider<DeviceRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final settingsService = ref.watch(settingsServiceProvider);
  return DeviceRepository(apiClient, settingsService);
});

/// Last successful heartbeat timestamp (`null` until the first acknowledgement).
final devicePresenceControllerProvider =
    NotifierProvider<DevicePresenceController, DateTime?>(
  DevicePresenceController.new,
);
