import os
import unittest
from pathlib import Path
from unittest.mock import patch

import app
from app.db import get_setting, set_setting
from app.services.auth_service import Identity, ROLE_ADMIN, ROLE_VIEWER


class ComprehensiveAdminAuthEdgeCaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        app.init_db()
        cls.client = app.app.test_client()
        set_setting('admin_pin', '6361')
        cls.media_root = app.config.MEDIA_ROOT

    def setUp(self):
        # Always restore default PIN before each test
        set_setting('admin_pin', '6361')

    # =========================================================================
    # 1. PIN VERIFY & STATUS ENDPOINTS (EDGE CASES)
    # =========================================================================

    def test_status_endpoint_reports_status(self):
        res = self.client.get('/api/admin/status')
        self.assertEqual(res.status_code, 200)
        data = res.get_json()
        self.assertIn('is_admin', data)
        self.assertTrue(data.get('has_pin'))
        self.assertIsNone(data.get('user'))

    def test_verify_pin_success_variations(self):
        # 1. Exact string
        res = self.client.post('/api/admin/verify', json={'pin': '6361'})
        self.assertEqual(res.status_code, 200)
        self.assertTrue(res.get_json().get('success'))
        self.assertEqual(res.get_json().get('method'), 'pin')

        # 2. Numeric integer in JSON
        res = self.client.post('/api/admin/verify', json={'pin': 6361})
        self.assertEqual(res.status_code, 200)
        self.assertTrue(res.get_json().get('success'))

        # 3. Alternate key 'admin_pin'
        res = self.client.post('/api/admin/verify', json={'admin_pin': '6361'})
        self.assertEqual(res.status_code, 200)
        self.assertTrue(res.get_json().get('success'))

        # 4. Header X-Admin-Pin
        res = self.client.post('/api/admin/verify', headers={'X-Admin-Pin': '6361'})
        self.assertEqual(res.status_code, 200)
        self.assertTrue(res.get_json().get('success'))

        # 5. Header with leading/trailing whitespace
        res = self.client.post('/api/admin/verify', headers={'X-Admin-Pin': '  6361  '})
        self.assertEqual(res.status_code, 200)
        self.assertTrue(res.get_json().get('success'))

    def test_verify_pin_failure_edge_cases(self):
        edge_cases = [
            {'pin': '0000'},
            {'pin': 1234},
            {'pin': ''},
            {'pin': '    '},
            {'pin': None},
            {'pin': '6360'},
            {'pin': '6362'},
            {'pin': '-6361'},
            {'pin': "' OR '1'='1"},
            {'pin': '6361; DROP TABLE settings;'},
            {'pin': '6361' * 500},
            {'pin': True},
            {'admin_pin': False},
            {},
        ]
        for payload in edge_cases:
            res = self.client.post('/api/admin/verify', json=payload)
            self.assertEqual(res.status_code, 401, f"Failed on payload: {payload}")
            self.assertFalse(res.get_json().get('success'))
            self.assertFalse(res.get_json().get('admin'))

    def test_verify_pin_non_json_body(self):
        res = self.client.post('/api/admin/verify', data="random string text", content_type="text/plain")
        self.assertEqual(res.status_code, 401)
        self.assertFalse(res.get_json().get('success'))

    # =========================================================================
    # 2. PIN ROTATION & UPDATE (LIFECYCLE EDGE CASES)
    # =========================================================================

    def test_pin_update_lifecycle_and_validation(self):
        with patch.dict(os.environ, {'PYTEST_CURRENT_TEST': ''}):
            # A. Update without admin auth or PIN -> 403
            res = self.client.post('/api/admin/pin', json={'new_pin': '8888'})
            self.assertEqual(res.status_code, 403)

            # B. Update with short PIN (< 4 digits) -> 400
            res = self.client.post(
                '/api/admin/pin',
                json={'new_pin': '123'},
                headers={'X-Admin-Pin': '6361'}
            )
            self.assertEqual(res.status_code, 400)
            self.assertIn('at least 4 digits', res.get_json().get('error', ''))

            # C. Update with empty PIN -> 400
            res = self.client.post(
                '/api/admin/pin',
                json={'new_pin': ''},
                headers={'X-Admin-Pin': '6361'}
            )
            self.assertEqual(res.status_code, 400)

            # D. Update with valid new PIN -> 200
            res = self.client.post(
                '/api/admin/pin',
                json={'new_pin': '9999'},
                headers={'X-Admin-Pin': '6361'}
            )
            self.assertEqual(res.status_code, 200)
            self.assertTrue(res.get_json().get('success'))

            # E. Verify old PIN '6361' is now rejected
            res_old = self.client.post('/api/admin/verify', json={'pin': '6361'})
            self.assertEqual(res_old.status_code, 401)

            # F. Verify new PIN '9999' is accepted
            res_new = self.client.post('/api/admin/verify', json={'pin': '9999'})
            self.assertEqual(res_new.status_code, 200)

            # G. Restore original PIN '6361' using new PIN
            res_restore = self.client.post(
                '/api/admin/pin',
                json={'new_pin': '6361'},
                headers={'X-Admin-Pin': '9999'}
            )
            self.assertEqual(res_restore.status_code, 200)
            self.assertEqual(get_setting('admin_pin'), '6361')

    # =========================================================================
    # 3. DESTRUCTIVE OPERATIONS AUTHENTICATION & INPUT EDGE CASES
    # =========================================================================

    def test_media_delete_unauthorized_rejections(self):
        with patch.dict(os.environ, {'PYTEST_CURRENT_TEST': ''}):
            targets = [
                'NonExistent.2026.mp4',
                'Folder/NestedMovie.2026.mkv',
                '../../etc/passwd',
                '..\\Windows\\System32\\cmd.exe',
            ]
            for target in targets:
                # DELETE verb without PIN
                res = self.client.delete(f'/api/media/{target}')
                self.assertEqual(res.status_code, 403, f"DELETE should be 403 for {target}")
                self.assertFalse(res.get_json().get('success'))

                # POST /api/media/delete verb without PIN
                res_post = self.client.post(f'/api/media/delete/{target}')
                self.assertEqual(res_post.status_code, 403, f"POST delete should be 403 for {target}")

                # With wrong PIN
                res_wrong = self.client.delete(f'/api/media/{target}', headers={'X-Admin-Pin': '0000'})
                self.assertEqual(res_wrong.status_code, 403)

    def test_media_delete_authorized_with_pin(self):
        with patch.dict(os.environ, {'PYTEST_CURRENT_TEST': ''}):
            # Create a real test media file in MEDIA_ROOT
            test_file = self.media_root / "TestAdminDelete.2026.mp4"
            test_file.write_bytes(b"test video payload")
            self.assertTrue(test_file.is_file())

            try:
                # 1. DELETE with correct PIN in header
                res = self.client.delete(
                    "/api/media/TestAdminDelete.2026.mp4",
                    headers={'X-Admin-Pin': '6361'}
                )
                self.assertEqual(res.status_code, 200)
                self.assertTrue(res.get_json().get('success'))
                self.assertFalse(test_file.exists())
            finally:
                test_file.unlink(missing_ok=True)

    def test_media_delete_nested_subdirectory_authorized(self):
        with patch.dict(os.environ, {'PYTEST_CURRENT_TEST': ''}):
            sub_dir = self.media_root / "AdminTestSubdir"
            sub_dir.mkdir(parents=True, exist_ok=True)
            nested_file = sub_dir / "NestedDelete.2026.mp4"
            nested_file.write_bytes(b"nested video payload")

            try:
                # A nested path must authorise exactly like a top-level one.
                # The PIN travels in the header, not the query string: a secret
                # in a URL lands in Waitress access logs, Cloudflare's edge
                # logs, browser history and Referer headers, so `?pin=` is
                # deliberately not an accepted channel.
                res = self.client.delete(
                    "/api/media/AdminTestSubdir/NestedDelete.2026.mp4",
                    headers={"X-Admin-Pin": "6361"},
                )
                self.assertEqual(res.status_code, 200)
                self.assertTrue(res.get_json().get('success'))
                self.assertFalse(nested_file.exists())
            finally:
                nested_file.unlink(missing_ok=True)
                if sub_dir.exists():
                    sub_dir.rmdir()

    def test_a_pin_is_not_accepted_from_the_query_string(self):
        """
        Regression: the PIN used to be readable from `?pin=`, which put the one
        secret guarding media deletion into four more places to leak it from.
        """
        with patch.dict(os.environ, {'PYTEST_CURRENT_TEST': ''}):
            res = self.client.delete("/api/media/AdminTestSubdir/DoesNotExist.mp4?pin=6361")
            self.assertEqual(res.status_code, 403)

    def test_no_configured_pin_means_no_pin_is_accepted(self):
        """
        Fail-closed invariant, and the reason the hard-coded default was removed.

        This host is reachable from the public internet. A default PIN is not a
        safe fallback for a secret: with one, "no PIN configured" silently meant
        "anyone who guesses the default may delete the library". Unset must mean
        the PIN channel is closed, leaving only a Google admin session.
        """
        from app.db import set_setting
        set_setting('admin_pin', '')

        with patch.dict(os.environ, {'PYTEST_CURRENT_TEST': ''}):
            for attempt in (
                {"headers": {"X-Admin-Pin": "6361"}},
                {"json": {"pin": "6361"}},
                {"json": {"pin": ""}},
            ):
                with self.subTest(attempt=attempt):
                    res = self.client.post('/api/admin/verify', **attempt)
                    self.assertEqual(res.status_code, 401)
                    self.assertFalse(res.get_json().get('admin'))

            # And the destructive route stays shut, not merely the verify probe.
            res = self.client.post('/api/storage/purge-orphans',
                                   headers={"X-Admin-Pin": "6361"})
            self.assertEqual(res.status_code, 403)

    def test_storage_purge_orphans_edge_cases(self):
        with patch.dict(os.environ, {'PYTEST_CURRENT_TEST': ''}):
            # No PIN -> 403
            res = self.client.post('/api/storage/purge-orphans')
            self.assertEqual(res.status_code, 403)

            # Wrong PIN in JSON body -> 403
            res = self.client.post('/api/storage/purge-orphans', json={'pin': 'wrong'})
            self.assertEqual(res.status_code, 403)

            # Correct PIN in JSON body -> 200
            res = self.client.post('/api/storage/purge-orphans', json={'pin': '6361', 'dry_run': True})
            self.assertEqual(res.status_code, 200)
            self.assertIn('result', res.get_json())

            # Correct PIN in header -> 200
            res = self.client.post('/api/storage/purge-orphans?dry_run=1', headers={'X-Admin-Pin': '6361'})
            self.assertEqual(res.status_code, 200)

    def test_storage_settings_edge_cases(self):
        with patch.dict(os.environ, {'PYTEST_CURRENT_TEST': ''}):
            # GET is read-only and open to all (Manage UI loads policy) -> 200
            res_get = self.client.get('/api/storage/settings')
            self.assertEqual(res_get.status_code, 200)
            self.assertIn('retention_policy', res_get.get_json())

            # POST without PIN -> 403
            res_post_no_pin = self.client.post('/api/storage/settings', json={'retention_policy': 'keep'})
            self.assertEqual(res_post_no_pin.status_code, 403)

            # POST with wrong PIN -> 403
            res_post_wrong_pin = self.client.post(
                '/api/storage/settings',
                json={'retention_policy': 'keep'},
                headers={'X-Admin-Pin': '0000'}
            )
            self.assertEqual(res_post_wrong_pin.status_code, 403)

            # POST with correct PIN but invalid policy -> 400
            res_invalid_policy = self.client.post(
                '/api/storage/settings',
                json={'retention_policy': 'destroy_everything_now'},
                headers={'X-Admin-Pin': '6361'}
            )
            self.assertEqual(res_invalid_policy.status_code, 400)
            self.assertFalse(res_invalid_policy.get_json().get('success'))

            # POST with correct PIN and valid policy -> 200
            res_valid_policy = self.client.post(
                '/api/storage/settings',
                json={'retention_policy': 'archive'},
                headers={'X-Admin-Pin': '6361'}
            )
            self.assertEqual(res_valid_policy.status_code, 200)
            self.assertTrue(res_valid_policy.get_json().get('success'))
            self.assertEqual(res_valid_policy.get_json().get('retention_policy'), 'archive')

            # Restore retention_policy to 'keep'
            self.client.post(
                '/api/storage/settings',
                json={'retention_policy': 'keep'},
                headers={'X-Admin-Pin': '6361'}
            )

    def test_storage_archive_endpoint_edge_cases(self):
        with patch.dict(os.environ, {'PYTEST_CURRENT_TEST': ''}):
            # 1. Without PIN -> 403
            res = self.client.post('/api/storage/archive/anyfile.mp4')
            self.assertEqual(res.status_code, 403)

            # 2. With wrong PIN -> 403
            res = self.client.post('/api/storage/archive/anyfile.mp4', headers={'X-Admin-Pin': 'bad'})
            self.assertEqual(res.status_code, 403)

            # 3. With correct PIN but file not found -> 404 (Auth passed!)
            res = self.client.post('/api/storage/archive/nonexistent.mp4', headers={'X-Admin-Pin': '6361'})
            self.assertEqual(res.status_code, 404)
            self.assertFalse(res.get_json().get('success'))

    def test_storage_audit_requires_admin(self):
        with patch.dict(os.environ, {'PYTEST_CURRENT_TEST': ''}):
            # 1. Without PIN -> 403
            res = self.client.get('/api/storage/audit')
            self.assertEqual(res.status_code, 403)

            # 2. With wrong PIN -> 403
            res = self.client.get('/api/storage/audit', headers={'X-Admin-Pin': '0000'})
            self.assertEqual(res.status_code, 403)

            # 3. With correct PIN -> 200
            res = self.client.get('/api/storage/audit', headers={'X-Admin-Pin': '6361'})
            self.assertEqual(res.status_code, 200)
            self.assertIn('storage', res.get_json())
            self.assertIn('audit', res.get_json())

    def test_scan_post_requires_admin(self):
        with patch.dict(os.environ, {'PYTEST_CURRENT_TEST': ''}):
            # 1. POST without PIN -> 403
            res = self.client.post('/api/scan')
            self.assertEqual(res.status_code, 403)

            # 2. POST with wrong PIN -> 403
            res = self.client.post('/api/scan', headers={'X-Admin-Pin': 'wrong'})
            self.assertEqual(res.status_code, 403)

            # 3. POST with correct PIN -> 200
            res = self.client.post('/api/scan', headers={'X-Admin-Pin': '6361'})
            self.assertEqual(res.status_code, 200)

    def test_upload_chunk_init_requires_admin(self):
        with patch.dict(os.environ, {'PYTEST_CURRENT_TEST': ''}):
            # 1. Without PIN -> 403
            res = self.client.post('/api/upload/chunk/init', json={'filename': 'movie.mp4', 'size': 100})
            self.assertEqual(res.status_code, 403)

            # 2. With correct PIN -> passes auth (validation error or 200, not 403)
            res = self.client.post(
                '/api/upload/chunk/init',
                json={'filename': 'movie.mp4', 'size': 100},
                headers={'X-Admin-Pin': '6361'}
            )
            self.assertNotEqual(res.status_code, 403)

    def test_device_privacy_scoping_and_management_auth(self):
        with patch.dict(os.environ, {'PYTEST_CURRENT_TEST': ''}):
            db = app.get_db()
            db.execute(
                "INSERT OR REPLACE INTO devices(device_id, device_name, device_type, device_os, browser, connection_type, client_ip, first_seen, last_seen) "
                "VALUES('dev_other_victim', 'Victim Device', 'Mobile', 'iOS 17', 'Safari', 'Local Network (LAN)', '192.168.1.50', datetime('now'), datetime('now'))"
            )
            db.commit()
            db.close()

            # 1. Non-admin GET /api/devices only sees their own device
            res_anon = self.client.get('/api/devices')
            self.assertEqual(res_anon.status_code, 200)
            data_anon = res_anon.get_json()
            # None of the other devices should be returned
            self.assertTrue(all(d['is_current'] for d in data_anon['devices']))
            self.assertFalse(any(d['device_id'] == 'dev_other_victim' for d in data_anon['devices']))

            # 2. Admin GET /api/devices sees all devices
            res_admin = self.client.get('/api/devices', headers={'X-Admin-Pin': '6361'})
            self.assertEqual(res_admin.status_code, 200)
            data_admin = res_admin.get_json()
            self.assertTrue(any(d['device_id'] == 'dev_other_victim' for d in data_admin['devices']))

            # 3. Non-admin renaming another device -> 403
            res_rename = self.client.post('/api/devices/rename', json={'device_id': 'dev_other_victim', 'name': 'Hacked'})
            self.assertEqual(res_rename.status_code, 403)

            # 4. Non-admin deleting another device -> 403
            res_del = self.client.post('/api/devices/delete', json={'device_id': 'dev_other_victim'})
            self.assertEqual(res_del.status_code, 403)

            # 5. Admin can rename any device
            res_rename_admin = self.client.post(
                '/api/devices/rename',
                json={'device_id': 'dev_other_victim', 'name': 'Admin Renamed'},
                headers={'X-Admin-Pin': '6361'}
            )
            self.assertEqual(res_rename_admin.status_code, 200)

    # =========================================================================
    # 4. IDENTITY & ROLE COMBINATIONS (OAUTH SESSION + BEARER TOKEN)
    # =========================================================================

    def test_identity_with_admin_role_bypasses_pin(self):
        with patch.dict(os.environ, {'PYTEST_CURRENT_TEST': ''}):
            admin_identity = Identity(subject='anis7t@gmail.com', role=ROLE_ADMIN)
            with patch('app.services.auth_service.resolve_identity', return_value=admin_identity):
                # /api/admin/status reports admin = True
                res_status = self.client.get('/api/admin/status')
                self.assertEqual(res_status.status_code, 200)
                self.assertTrue(res_status.get_json().get('is_admin'))
                self.assertEqual(res_status.get_json().get('user'), 'anis7t@gmail.com')

                # /api/admin/verify returns success without pin
                res_verify = self.client.post('/api/admin/verify')
                self.assertEqual(res_verify.status_code, 200)
                self.assertTrue(res_verify.get_json().get('admin'))
                self.assertEqual(res_verify.get_json().get('method'), 'google_session')

                # Destructive operations succeed without passing X-Admin-Pin
                res_purge = self.client.post('/api/storage/purge-orphans?dry_run=1')
                self.assertEqual(res_purge.status_code, 200)

                res_settings = self.client.post('/api/storage/settings', json={'retention_policy': 'keep'})
                self.assertEqual(res_settings.status_code, 200)

    def test_identity_with_viewer_role_requires_pin(self):
        with patch.dict(os.environ, {'PYTEST_CURRENT_TEST': ''}):
            viewer_identity = Identity(subject='guest@example.com', role=ROLE_VIEWER)
            with patch('app.services.auth_service.resolve_identity', return_value=viewer_identity):
                # /api/admin/status reports admin = False
                res_status = self.client.get('/api/admin/status')
                self.assertEqual(res_status.status_code, 200)
                self.assertFalse(res_status.get_json().get('is_admin'))

                # Delete without PIN -> 403
                res_del = self.client.delete('/api/media/some_video.mp4')
                self.assertEqual(res_del.status_code, 403)

                # Delete WITH valid PIN -> passes auth (returns 200 or 404, not 403)
                res_del_pin = self.client.delete(
                    '/api/media/some_video.mp4',
                    headers={'X-Admin-Pin': '6361'}
                )
                self.assertNotEqual(res_del_pin.status_code, 403)

    # =========================================================================
    # 5. FAMILY & TV STREAMING ISOLATION (ZERO-BLOCK GUARANTEE)
    # =========================================================================

    def test_open_streaming_endpoints_are_never_blocked(self):
        """Verify unauthenticated household devices & TVs can browse and stream freely."""
        with patch.dict(os.environ, {'PYTEST_CURRENT_TEST': ''}):
            # Read-only library endpoints
            res_movies = self.client.get('/api/movies')
            self.assertEqual(res_movies.status_code, 200)

            res_telemetry = self.client.get('/api/system-status')
            self.assertEqual(res_telemetry.status_code, 200)

            res_devices = self.client.get('/api/devices')
            self.assertEqual(res_devices.status_code, 200)

            res_heartbeat = self.client.post('/api/devices/heartbeat')
            self.assertEqual(res_heartbeat.status_code, 200)

            res_hints = self.client.post('/api/devices/client-hints', json={'model': 'AFTMM'})
            self.assertEqual(res_hints.status_code, 200)

            # Progress endpoint is open (never 403)
            res_progress_get = self.client.get('/api/progress')
            self.assertNotEqual(res_progress_get.status_code, 403)

            # With a test video file created
            test_vid = self.media_root / "OpenStreamTest.2026.mp4"
            test_vid.write_bytes(b"0123456789")
            try:
                res_progress_valid = self.client.get('/api/progress?filename=OpenStreamTest.2026.mp4')
                self.assertEqual(res_progress_valid.status_code, 200)

                res_progress_post = self.client.post(
                    '/api/progress',
                    json={'filename': 'OpenStreamTest.2026.mp4', 'position': 42.0, 'duration': 3600.0}
                )
                self.assertEqual(res_progress_post.status_code, 200)

                # Direct media route is open
                res_media = self.client.get('/media/OpenStreamTest.2026.mp4')
                self.assertEqual(res_media.status_code, 200)
                res_media.close()
            finally:
                test_vid.unlink(missing_ok=True)


if __name__ == '__main__':
    unittest.main()
