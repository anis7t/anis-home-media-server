"""Tests for Android multi-channel update server routes and publish tooling."""
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

import app
from app import config
from scripts.publish_update import publish_release, calculate_sha256, load_registry


class AppUpdateRouteTests(unittest.TestCase):
    def setUp(self):
        import shutil
        self.client = app.app.test_client()
        self.updates_dir = config.UPDATES_DIR
        for channel in ("production", "developer"):
            cdir = self.updates_dir / channel
            shutil.rmtree(cdir, ignore_errors=True)
            cdir.mkdir(parents=True, exist_ok=True)
        reg_file = self.updates_dir / "version_registry.json"
        reg_file.unlink(missing_ok=True)

    def test_update_endpoint_rejects_invalid_channel(self):
        res = self.client.get('/api/app/update')
        self.assertEqual(res.status_code, 400)
        self.assertIn("Invalid channel", res.get_json()["error"])

        res = self.client.get('/api/app/update?channel=beta')
        self.assertEqual(res.status_code, 400)
        self.assertIn("Invalid channel", res.get_json()["error"])

    def test_update_endpoint_404_when_missing(self):
        res = self.client.get('/api/app/update?channel=production')
        self.assertEqual(res.status_code, 404)
        self.assertIn("No update manifest found", res.get_json()["error"])

    def test_download_endpoint_rejects_invalid_channel(self):
        res = self.client.get('/api/app/download?channel=unknown')
        self.assertEqual(res.status_code, 400)

    def test_download_endpoint_404_when_missing(self):
        res = self.client.get('/api/app/download?channel=developer')
        self.assertEqual(res.status_code, 404)
        self.assertIn("APK artifact not found", res.get_json()["error"])

    def test_publish_release_and_serve_manifest_with_channel_isolation(self):
        # Create a mock APK binary
        with tempfile.NamedTemporaryFile(suffix=".apk", delete=False) as f:
            f.write(b"PK\x03\x04mock-apk-payload-1234567890-test")
            dummy_apk = Path(f.name)

        try:
            manifest = publish_release(
                channel="developer",
                version="1.1.0-dev.101",
                apk_path=dummy_apk,
                notes="• Added test feature",
                updates_dir=self.updates_dir,
                explicit_version_code=101,
            )
            self.assertEqual(manifest["channel"], "developer")
            self.assertEqual(manifest["versionCode"], 101)
            self.assertEqual(manifest["version"], "1.1.0-dev.101")
            self.assertEqual(manifest["packageId"], "in.anisparvez.media_server_client")
            self.assertEqual(len(manifest["sha256"]), 64)

            # Query developer channel
            res_dev = self.client.get('/api/app/update?channel=developer')
            self.assertEqual(res_dev.status_code, 200)
            data_dev = res_dev.get_json()
            self.assertEqual(data_dev["versionCode"], 101)
            self.assertEqual(data_dev["channel"], "developer")
            self.assertEqual(res_dev.headers.get("Cache-Control"), "no-cache, no-store, must-revalidate")

            # Strict channel isolation: production query MUST return 404
            res_prod = self.client.get('/api/app/update?channel=production')
            self.assertEqual(res_prod.status_code, 404)

            # Test download endpoint
            dl_res = self.client.get('/api/app/download?channel=developer')
            self.assertEqual(dl_res.status_code, 200)
            self.assertEqual(dl_res.data, b"PK\x03\x04mock-apk-payload-1234567890-test")
            self.assertEqual(dl_res.headers.get("Content-Type"), "application/vnd.android.package-archive")

            # Test byte-range request on download endpoint
            range_res = self.client.get('/api/app/download?channel=developer', headers={"Range": "bytes=0-3"})
            self.assertEqual(range_res.status_code, 206)
            self.assertEqual(range_res.data, b"PK\x03\x04")

        finally:
            dummy_apk.unlink(missing_ok=True)

    def test_monotonic_version_code_enforcement(self):
        with tempfile.NamedTemporaryFile(suffix=".apk", delete=False) as f:
            f.write(b"mock-apk-binary-data")
            dummy_apk = Path(f.name)

        try:
            # First publish at code 105
            publish_release(
                channel="developer",
                version="1.1.0-dev.105",
                apk_path=dummy_apk,
                explicit_version_code=105,
                updates_dir=self.updates_dir,
            )

            # Attempting publish at code 105 or lower must fail
            with self.assertRaises(ValueError) as ctx:
                publish_release(
                    channel="production",
                    version="1.0.0",
                    apk_path=dummy_apk,
                    explicit_version_code=105,
                    updates_dir=self.updates_dir,
                )
            self.assertIn("violates global monotonicity", str(ctx.exception))

            with self.assertRaises(ValueError) as ctx:
                publish_release(
                    channel="production",
                    version="1.0.0",
                    apk_path=dummy_apk,
                    explicit_version_code=104,
                    updates_dir=self.updates_dir,
                )
            self.assertIn("violates global monotonicity", str(ctx.exception))

            # Auto-incrementing publish allocates 106
            manifest_auto = publish_release(
                channel="production",
                version="1.1.0",
                apk_path=dummy_apk,
                updates_dir=self.updates_dir,
            )
            self.assertEqual(manifest_auto["versionCode"], 106)
            self.assertEqual(manifest_auto["channel"], "production")

        finally:
            dummy_apk.unlink(missing_ok=True)

    def test_malformed_manifest_returns_500(self):
        bad_manifest = self.updates_dir / "production" / "manifest.json"
        bad_manifest.write_text("{this-is-not-valid-json", encoding="utf-8")

        res = self.client.get('/api/app/update?channel=production')
        self.assertEqual(res.status_code, 500)
        self.assertIn("Malformed update manifest", res.get_json()["error"])


if __name__ == '__main__':
    unittest.main()
