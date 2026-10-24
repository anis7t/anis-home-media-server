import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/admin/domain/models/audit_log_model.dart';
import 'package:media_server_client/features/admin/domain/models/connected_device_model.dart';
import 'package:media_server_client/features/admin/domain/models/library_scan_model.dart';
import 'package:media_server_client/features/admin/domain/models/storage_audit_model.dart';
import 'package:media_server_client/features/admin/domain/models/transcode_dashboard_model.dart';

void main() {
  group('Storage Audit Models', () {
    test('StorageAuditReport parses from JSON correctly', () {
      final json = {
        'storage': {
          'percent': 65.5,
          'used': 500000000,
          'free': 250000000,
          'total': 750000000,
          'used_str': '500 GB',
          'free_str': '250 GB',
          'total_str': '750 GB',
          'drives': [
            {
              'drive': 'D:',
              'label': 'Flicks',
              'percent': 70.0,
              'used': 700000,
              'free': 300000,
              'total': 1000000,
              'used_str': '700 GB',
              'free_str': '300 GB',
              'total_str': '1 TB',
            },
            {
              'drive': 'E:',
              'label': 'MediaServer',
              'percent': 50.0,
              'used': 250000,
              'free': 250000,
              'total': 500000,
              'used_str': '250 GB',
              'free_str': '250 GB',
              'total_str': '500 GB',
            }
          ],
        },
        'audit': {
          'total_orphaned_bytes': 104857600,
          'total_orphaned_dirs': 5,
          'total_active_bytes': 524288000,
          'total_active_dirs': 2,
          'degraded': false,
          'degraded_reasons': <String>[],
        },
      };

      final report = StorageAuditReport.fromJson(json);
      expect(report.storage.percent, 65.5);
      expect(report.storage.drives.length, 2);
      expect(report.storage.drives[0].drive, 'D:');
      expect(report.storage.drives[1].drive, 'E:');
      expect(report.audit.totalOrphanedBytes, 104857600);
      expect(report.audit.totalOrphanedDirs, 5);
      expect(report.audit.totalActiveBytes, 524288000);
      expect(report.audit.totalActiveDirs, 2);
    });

    test('StorageRetentionSettings parses retention policy', () {
      final json = {
        'retention_policy': 'archive',
        'allowed_policies': ['keep', 'archive', 'purge_cache'],
        'archive_dir': 'D:/Flicks/.archive',
      };

      final settings = StorageRetentionSettings.fromJson(json);
      expect(settings.retentionPolicy, 'archive');
      expect(settings.allowedPolicies.length, 3);
      expect(settings.archiveDir, 'D:/Flicks/.archive');
    });

    test('PurgeResult parses freed bytes and count', () {
      final json = {
        'freed_bytes': 204800,
        'purged_count': 3,
        'dry_run': false,
      };

      final result = PurgeResult.fromJson(json);
      expect(result.freedBytes, 204800);
      expect(result.purgedCount, 3);
      expect(result.dryRun, isFalse);
    });
  });

  group('Transcode Dashboard Models', () {
    test('TranscodeDashboardResponse parses summary, active, and recent jobs', () {
      final json = {
        'summary': {
          'active_count': 1,
          'running_count': 1,
          'queued_count': 0,
          'total_current_bytes': 150000000,
          'total_current_size_str': '150 MB',
          'total_estimated_bytes': 500000000,
          'total_estimated_size_str': '500 MB',
          'overall_eta_seconds': 120.0,
          'overall_eta_str': '2m 0s',
          'hardware_engine': {
            'primary': {
              'name': 'AMD Radeon RX 560X',
              'adapter': 1,
              'backend': 'AMF / D3D11VA (Discrete)',
              'status': 'Active Encoding',
            },
            'secondary': {
              'name': 'AMD Radeon Vega 8',
              'adapter': 0,
              'backend': 'AMF / D3D11VA (Integrated)',
              'status': 'Idle / Standby',
            },
          },
        },
        'active_jobs': [
          {
            'id': 101,
            'filename': 'Movie.2024.1080p.mkv',
            'title': 'Movie 2024',
            'year': 2024,
            'runtime': 120,
            'poster_url': '/poster/Movie.2024.1080p.mkv',
            'mode': 'standard',
            'preset_label': '1080p',
            'status': 'running',
            'percent': 45.5,
            'speed_str': '2.4x',
            'fps_str': '58 fps',
            'eta_str': '2m 10s',
            'current_size_str': '150 MB',
            'estimated_total_size_str': '500 MB',
          }
        ],
        'recent_jobs': [
          {
            'id': 99,
            'filename': 'OldMovie.mkv',
            'title': 'Old Movie',
            'status': 'completed',
            'elapsed_str': '4m 12s',
            'updated_at': '2026-10-24T20:00:00Z',
          }
        ],
      };

      final response = TranscodeDashboardResponse.fromJson(json);
      expect(response.summary.activeCount, 1);
      expect(response.summary.hardwareEngine.primary.name, 'AMD Radeon RX 560X');
      expect(response.summary.hardwareEngine.primary.status, 'Active Encoding');
      expect(response.activeJobs.length, 1);
      expect(response.activeJobs.first.title, 'Movie 2024');
      expect(response.activeJobs.first.speedStr, '2.4x');
      expect(response.recentJobs.length, 1);
      expect(response.recentJobs.first.status, 'completed');
    });
  });

  group('Connected Device Models', () {
    test('DeviceListResponse parses devices list and stats', () {
      final json = {
        'devices': [
          {
            'device_id': 'dev-123',
            'custom_name': "Living Room TV",
            'display_name': "Living Room TV",
            'device_type': 'tv',
            'device_icon': 'tv',
            'device_os': 'Android TV 12',
            'client_ip': '192.168.1.105',
            'first_seen': '2026-10-20T10:00:00Z',
            'last_seen': '2026-10-24T21:00:00Z',
            'last_seen_ago': '2 minutes ago',
            'is_active': true,
            'is_current': true,
          }
        ],
        'stats': {
          'total_devices': 5,
          'active_now': 2,
          'offline_count': 3,
          'cloudflare_count': 1,
          'lan_count': 4,
          'localhost_count': 0,
        },
        'current_device_id': 'dev-123',
      };

      final response = DeviceListResponse.fromJson(json);
      expect(response.devices.length, 1);
      expect(response.devices.first.displayName, 'Living Room TV');
      expect(response.devices.first.isActive, isTrue);
      expect(response.devices.first.isCurrent, isTrue);
      expect(response.stats.totalDevices, 5);
      expect(response.stats.activeNow, 2);
      expect(response.currentDeviceId, 'dev-123');
    });
  });

  group('Library Scan Models', () {
    test('LibraryScanStatus detects scanning vs idle', () {
      final idleJson = {
        'status': 'idle',
        'busy': false,
        'files_discovered': 50,
        'unindexed_discovered': 0,
        'movies_indexed': 50,
        'orphans_pruned': 0,
        'subtitles_acquired': 45,
        'errors': 0,
      };
      final idle = LibraryScanStatus.fromJson(idleJson);
      expect(idle.isScanning, isFalse);
      expect(idle.moviesIndexed, 50);

      final busyJson = {
        'status': 'scanning',
        'busy': true,
        'files_discovered': 55,
        'unindexed_discovered': 5,
        'movies_indexed': 50,
        'orphans_pruned': 0,
        'subtitles_acquired': 45,
        'errors': 0,
      };
      final busy = LibraryScanStatus.fromJson(busyJson);
      expect(busy.isScanning, isTrue);
    });
  });

  group('Audit Log Models', () {
    test('AuditLogResponse parses log list and pagination metadata', () {
      final json = {
        'logs': [
          {
            'id': 1,
            'actor_type': 'admin',
            'actor_id': 'admin-session',
            'action': 'pin_change',
            'target_type': 'settings',
            'target_id': 'admin_pin',
            'details': {'success': true},
            'ip_address': '192.168.1.50',
            'created_at': '2026-10-24T21:30:00Z',
          }
        ],
        'total': 1,
        'limit': 50,
        'offset': 0,
      };

      final response = AuditLogResponse.fromJson(json);
      expect(response.logs.length, 1);
      expect(response.logs.first.action, 'pin_change');
      expect(response.logs.first.actorType, 'admin');
      expect(response.total, 1);
    });
  });
}
