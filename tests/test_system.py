"""Tests for system status telemetry and player fullscreen cursor hiding."""
import unittest
from app import create_app, CSS, PLAYER_HTML
from app.services.system_service import get_system_telemetry


class SystemTelemetryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = create_app()
        cls.client = cls.app.test_client()

    def test_system_telemetry_data(self):
        data = get_system_telemetry()
        self.assertIn('cpu', data)
        self.assertIn('gpu', data)
        self.assertIn('memory', data)
        self.assertIn('disk_io', data)
        self.assertIn('storage', data)
        self.assertIn('network', data)

        # CPU assertions
        self.assertIn('percent', data['cpu'])
        self.assertIn('cores', data['cpu'])
        self.assertEqual(data['cpu']['label'], 'Core Compute')
        self.assertGreaterEqual(data['cpu']['cores'], 1)

        # GPU assertions
        self.assertIn('available', data['gpu'])
        self.assertEqual(data['gpu']['label'], 'Graphics Engine')

        # Memory assertions
        self.assertIn('percent', data['memory'])
        self.assertIn('used', data['memory'])
        self.assertIn('total', data['memory'])
        self.assertEqual(data['memory']['label'], 'Memory Bank')
        self.assertGreater(data['memory']['total'], 0)

        # Storage assertions
        self.assertIn('percent', data['storage'])
        self.assertIn('used', data['storage'])
        self.assertIn('free', data['storage'])
        self.assertEqual(data['storage']['label'], 'Storage Pool')
        self.assertGreater(data['storage']['total'], 0)

        # Disk I/O assertions
        self.assertIn('read_str', data['disk_io'])
        self.assertIn('write_str', data['disk_io'])
        self.assertEqual(data['disk_io']['label'], 'I/O Velocity')

        # Network assertions
        self.assertIn('rx_str', data['network'])
        self.assertIn('tx_str', data['network'])
        self.assertEqual(data['network']['label'], 'Network Stream')

    def test_api_system_status_endpoint(self):
        resp = self.client.get('/api/system-status')
        self.assertEqual(resp.status_code, 200)
        json_data = resp.get_json()
        self.assertIsNotNone(json_data)
        self.assertIn('cpu', json_data)
        self.assertIn('gpu', json_data)
        self.assertIn('memory', json_data)
        self.assertIn('disk_io', json_data)
        self.assertIn('storage', json_data)
        self.assertIn('network', json_data)

    def test_homepage_renders_system_telemetry_section(self):
        resp = self.client.get('/')
        self.assertEqual(resp.status_code, 200)
        html = resp.data.decode()
        self.assertIn('id="systemSection"', html)
        self.assertIn('System Telemetry', html)
        self.assertIn('Core Compute', html)
        self.assertIn('Graphics Engine', html)
        self.assertIn('Memory Bank', html)
        self.assertIn('I/O Velocity', html)
        self.assertIn('Storage Pool', html)
        self.assertIn('Network Stream', html)
        self.assertIn('pollSystemStatus', html)

    def test_player_fullscreen_hide_cursor_styles_and_logic(self):
        self.assertIn('cursor:none!important', CSS)
        self.assertIn('#shell.hide-cursor', CSS)
        self.assertIn('fsCursorTimer', PLAYER_HTML)
        self.assertIn('resetFsCursor', PLAYER_HTML)
        self.assertIn('hide-cursor', PLAYER_HTML)


if __name__ == '__main__':
    unittest.main()
