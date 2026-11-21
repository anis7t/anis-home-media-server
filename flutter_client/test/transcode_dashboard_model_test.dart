import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/admin/domain/models/transcode_dashboard_model.dart';

void main() {
  group('TranscodeDashboardModel - GPU Telemetry', () {
    test('GpuEngineStatus parses temperature_c and utilization_pct when present', () {
      final json = {
        'name': 'Radeon RX 560X',
        'adapter': 1,
        'backend': 'D3D11VA (dx11:1)',
        'status': 'Active (Transcoding)',
        'temperature_c': 88.0,
        'utilization_pct': 61.3,
      };

      final status = GpuEngineStatus.fromJson(json);

      expect(status.name, equals('Radeon RX 560X'));
      expect(status.adapter, equals(1));
      expect(status.backend, equals('D3D11VA (dx11:1)'));
      expect(status.status, equals('Active (Transcoding)'));
      expect(status.temperatureC, equals(88.0));
      expect(status.utilizationPct, equals(61.3));
    });

    test('GpuEngineStatus handles null or absent temperature and utilization', () {
      final json = {
        'name': 'Radeon Vega 8',
        'adapter': 0,
        'backend': 'D3D11VA (dx11:0)',
        'status': 'Idle / Standby',
      };

      final status = GpuEngineStatus.fromJson(json);

      expect(status.name, equals('Radeon Vega 8'));
      expect(status.temperatureC, isNull);
      expect(status.utilizationPct, isNull);
    });

    test('DualGpuHardwareInfo correctly parses nested primary and secondary telemetry', () {
      final json = {
        'primary': {
          'name': 'Radeon RX 560X',
          'adapter': 1,
          'backend': 'D3D11VA (dx11:1)',
          'status': 'Active (Transcoding)',
          'temperature_c': 84.5,
          'utilization_pct': 72.1,
        },
        'secondary': {
          'name': 'Radeon Vega 8',
          'adapter': 0,
          'backend': 'D3D11VA (dx11:0)',
          'status': 'Idle / Standby',
          'temperature_c': 65.0,
          'utilization_pct': 0.0,
        },
      };

      final dualGpu = DualGpuHardwareInfo.fromJson(json);

      expect(dualGpu.primary.temperatureC, equals(84.5));
      expect(dualGpu.primary.utilizationPct, equals(72.1));
      expect(dualGpu.secondary.temperatureC, equals(65.0));
      expect(dualGpu.secondary.utilizationPct, equals(0.0));
    });

    test('TranscodeRecentJob correctly parses error field and thermal pause', () {
      final json = {
        'id': 1150,
        'filename': 'The Odyssey.mkv',
        'title': 'The Odyssey',
        'status': 'failed',
        'error': '[THERMAL_PAUSE] Critical GPU temperature reached on Radeon RX 560X',
        'elapsed_str': '52m 14s',
        'updated_at': '2026-11-21T18:46:58Z',
      };

      final job = TranscodeRecentJob.fromJson(json);

      expect(job.id, equals(1150));
      expect(job.status, equals('failed'));
      expect(job.error, contains('[THERMAL_PAUSE]'));
    });
  });
}
