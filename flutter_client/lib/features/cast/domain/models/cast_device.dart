import 'package:flutter/material.dart';

/// A playback device on the LAN that the server can cast to.
///
/// Discovery and control live on the server (it can send SSDP and mDNS, a phone
/// cannot), so this is a view of `/api/cast/devices` and nothing more.
class CastDevice {
  final String id;
  final String name;

  /// `dlna` for a UPnP renderer, `cast` for a Chromecast.
  final String kind;
  final String model;
  final String host;

  const CastDevice({
    required this.id,
    required this.name,
    required this.kind,
    this.model = '',
    this.host = '',
  });

  bool get isChromecast => kind == 'cast';

  /// Protocol label shown in the picker.
  String get protocolLabel => isChromecast ? 'Chromecast' : 'DLNA';

  IconData get icon => isChromecast ? Icons.cast : Icons.tv_rounded;

  factory CastDevice.fromJson(Map<String, dynamic> json) => CastDevice(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? 'Device').toString(),
        kind: (json['kind'] ?? '').toString(),
        model: (json['model'] ?? '').toString(),
        host: (json['host'] ?? '').toString(),
      );

  @override
  bool operator ==(Object other) => other is CastDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// What a device is playing right now, as reported by `/api/cast/status`.
class CastPlaybackStatus {
  final String state;
  final Duration position;
  final Duration duration;
  final String? filename;

  /// Set when the device refused the media (unsupported codec, unreachable host).
  final String? lastError;

  const CastPlaybackStatus({
    required this.state,
    required this.position,
    required this.duration,
    this.filename,
    this.lastError,
  });

  bool get isPlaying => state == 'playing';
  bool get isPaused => state == 'paused';

  factory CastPlaybackStatus.fromJson(Map<String, dynamic> json) => CastPlaybackStatus(
        state: (json['state'] ?? 'unknown').toString(),
        position: Duration(milliseconds: (((json['position'] as num?) ?? 0) * 1000).round()),
        duration: Duration(milliseconds: (((json['duration'] as num?) ?? 0) * 1000).round()),
        filename: json['filename']?.toString(),
        lastError: json['last_error']?.toString(),
      );
}

/// Result of one discovery call: the devices seen so far, and whether the server
/// is still scanning (in which case the caller polls again).
class CastDiscovery {
  final List<CastDevice> devices;
  final bool scanning;
  final Map<String, String> errors;

  const CastDiscovery({required this.devices, required this.scanning, this.errors = const {}});

  factory CastDiscovery.fromJson(Map<String, dynamic> json) => CastDiscovery(
        devices: ((json['devices'] as List?) ?? const [])
            .whereType<Map>()
            .map((raw) => CastDevice.fromJson(raw.cast<String, dynamic>()))
            .where((device) => device.id.isNotEmpty)
            .toList(growable: false),
        scanning: json['scanning'] == true,
        errors: ((json['errors'] as Map?) ?? const {})
            .map((key, value) => MapEntry(key.toString(), value.toString())),
      );
}
