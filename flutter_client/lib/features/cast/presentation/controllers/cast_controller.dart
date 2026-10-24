import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/errors/app_exception.dart';
import '../../data/models/cast_device.dart';
import '../../data/repositories/cast_repository.dart';

/// The cast session: what was discovered, what is being cast, and how it is going.
@immutable
class CastState {
  final List<CastDevice> devices;
  final bool scanning;
  final CastDevice? activeDevice;
  final String? mediaFilename;
  final String playbackState;
  final Duration position;
  final Duration duration;
  final String? error;
  final bool busy;

  const CastState({
    this.devices = const [],
    this.scanning = false,
    this.activeDevice,
    this.mediaFilename,
    this.playbackState = 'unknown',
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.error,
    this.busy = false,
  });

  bool get isCasting => activeDevice != null;

  CastState copyWith({
    List<CastDevice>? devices,
    bool? scanning,
    CastDevice? activeDevice,
    bool clearActiveDevice = false,
    String? mediaFilename,
    String? playbackState,
    Duration? position,
    Duration? duration,
    String? error,
    bool clearError = false,
    bool? busy,
  }) {
    return CastState(
      devices: devices ?? this.devices,
      scanning: scanning ?? this.scanning,
      activeDevice: clearActiveDevice ? null : (activeDevice ?? this.activeDevice),
      mediaFilename: mediaFilename ?? this.mediaFilename,
      playbackState: playbackState ?? this.playbackState,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      error: clearError ? null : (error ?? this.error),
      busy: busy ?? this.busy,
    );
  }
}

/// Drives the cast UI. All protocol work happens on the server; this keeps the
/// device list, the active session and a light status poll.
class CastController extends Notifier<CastState> {
  @override
  CastState build() => const CastState();

  CastRepository get _repository => ref.read(castRepositoryProvider);

  /// Lists devices. The server scans in the background, so while it reports
  /// `scanning` this polls until the list settles.
  Future<void> discover({bool refresh = false}) async {
    state = state.copyWith(scanning: true, clearError: true);
    try {
      var discovery = await _repository.discover(refresh: refresh);
      state = state.copyWith(
        devices: discovery.devices,
        scanning: discovery.scanning,
        error: _scanError(discovery),
      );
      for (var attempt = 0; discovery.scanning && attempt < 12; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        discovery = await _repository.discover();
        state = state.copyWith(
          devices: discovery.devices,
          scanning: discovery.scanning,
          error: _scanError(discovery),
        );
      }
      state = state.copyWith(scanning: false);
    } catch (error) {
      state = state.copyWith(scanning: false, error: _message(error));
    }
  }

  /// Starts playback on [device]. Returns null on success, or the reason it failed
  /// (the server's message is the actionable part, e.g. an unsupported container).
  Future<String?> castTo(CastDevice device, String filename, {Duration? position}) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _repository.play(deviceId: device.id, filename: filename, position: position);
      state = state.copyWith(
        busy: false,
        activeDevice: device,
        mediaFilename: filename,
        playbackState: 'buffering',
        position: Duration.zero,
      );
      return null;
    } catch (error) {
      final message = _message(error);
      state = state.copyWith(busy: false, error: message);
      return message;
    }
  }

  Future<void> sendControl(String action, {double? value}) async {
    final device = state.activeDevice;
    if (device == null) return;
    try {
      await _repository.control(deviceId: device.id, action: action, value: value);
      if (action == 'stop') {
        state = state.copyWith(clearActiveDevice: true, playbackState: 'stopped', position: Duration.zero);
      } else if (action == 'seek' && value != null) {
        // Reflect the scrub at once so the phone's bar moves with the finger; the status
        // poll then corrects any drift the receiver adds of its own accord.
        state = state.copyWith(position: Duration(milliseconds: (value * 1000).round()));
      } else if (action == 'play' || action == 'pause') {
        state = state.copyWith(playbackState: action == 'play' ? 'playing' : 'paused');
      }
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  /// Refreshes the transport state; called on a timer while casting.
  Future<void> pollStatus() async {
    final device = state.activeDevice;
    if (device == null) return;
    final status = await _repository.status(device.id);
    if (status == null) return;
    state = state.copyWith(
      playbackState: status.state,
      position: status.position,
      duration: status.duration,
      mediaFilename: status.filename ?? state.mediaFilename,
      error: status.lastError,
    );
  }

  void clearError() => state = state.copyWith(clearError: true);

  String? _scanError(CastDiscovery discovery) {
    if (discovery.errors.isEmpty) return null;
    return discovery.errors.entries.map((e) => '${e.key}: ${e.value}').join(' · ');
  }

  String _message(Object error) {
    if (error is AppException && error.message.isNotEmpty) return error.message;
    return error.toString();
  }
}

final castControllerProvider = NotifierProvider<CastController, CastState>(CastController.new);
