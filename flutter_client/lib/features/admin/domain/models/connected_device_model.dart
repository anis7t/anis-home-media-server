import 'package:flutter/foundation.dart';

/// One registered client device on the server.
@immutable
class ConnectedDevice {
  final String deviceId;
  final String? customName;
  final String? deviceName;
  final String? deviceModel;
  final String displayName;
  final String? deviceType;
  final String deviceIcon;
  final String? deviceOs;
  final String? browser;
  final String? connectionType;
  final String? clientIp;
  final String? publicIp;
  final String firstSeen;
  final String lastSeen;
  final String lastSeenAgo;
  final bool isActive;
  final bool isCurrent;

  const ConnectedDevice({
    required this.deviceId,
    this.customName,
    this.deviceName,
    this.deviceModel,
    required this.displayName,
    this.deviceType,
    required this.deviceIcon,
    this.deviceOs,
    this.browser,
    this.connectionType,
    this.clientIp,
    this.publicIp,
    required this.firstSeen,
    required this.lastSeen,
    required this.lastSeenAgo,
    required this.isActive,
    required this.isCurrent,
  });

  factory ConnectedDevice.fromJson(Map<String, dynamic> json) {
    return ConnectedDevice(
      deviceId: (json['device_id'] as String?) ?? '',
      customName: json['custom_name'] as String?,
      deviceName: json['device_name'] as String?,
      deviceModel: json['device_model'] as String?,
      displayName: (json['display_name'] as String?) ?? 'Unknown Device',
      deviceType: json['device_type'] as String?,
      deviceIcon: (json['device_icon'] as String?) ?? 'generic',
      deviceOs: json['device_os'] as String?,
      browser: json['browser'] as String?,
      connectionType: json['connection_type'] as String?,
      clientIp: json['client_ip'] as String?,
      publicIp: json['public_ip'] as String?,
      firstSeen: (json['first_seen'] as String?) ?? '',
      lastSeen: (json['last_seen'] as String?) ?? '',
      lastSeenAgo: (json['last_seen_ago'] as String?) ?? 'recently',
      isActive: (json['is_active'] as bool?) ?? false,
      isCurrent: (json['is_current'] as bool?) ?? false,
    );
  }
}

/// Statistics across all registered devices.
@immutable
class DeviceRegistryStats {
  final int totalDevices;
  final int activeNow;
  final int offlineCount;
  final int cloudflareCount;
  final int lanCount;
  final int localhostCount;

  const DeviceRegistryStats({
    required this.totalDevices,
    required this.activeNow,
    required this.offlineCount,
    required this.cloudflareCount,
    required this.lanCount,
    required this.localhostCount,
  });

  factory DeviceRegistryStats.fromJson(Map<String, dynamic> json) {
    return DeviceRegistryStats(
      totalDevices: (json['total_devices'] as num?)?.toInt() ?? 0,
      activeNow: (json['active_now'] as num?)?.toInt() ?? 0,
      offlineCount: (json['offline_count'] as num?)?.toInt() ?? 0,
      cloudflareCount: (json['cloudflare_count'] as num?)?.toInt() ?? 0,
      lanCount: (json['lan_count'] as num?)?.toInt() ?? 0,
      localhostCount: (json['localhost_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Full response from `GET /api/devices`.
@immutable
class DeviceListResponse {
  final List<ConnectedDevice> devices;
  final DeviceRegistryStats stats;
  final String currentDeviceId;

  const DeviceListResponse({
    required this.devices,
    required this.stats,
    required this.currentDeviceId,
  });

  factory DeviceListResponse.fromJson(Map<String, dynamic> json) {
    final devList = (json['devices'] as List<dynamic>?)
            ?.map((e) => ConnectedDevice.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    return DeviceListResponse(
      devices: devList,
      stats: DeviceRegistryStats.fromJson(
        (json['stats'] as Map<String, dynamic>?) ?? {},
      ),
      currentDeviceId: (json['current_device_id'] as String?) ?? '',
    );
  }
}
