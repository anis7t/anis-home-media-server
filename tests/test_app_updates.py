"""Tests for Android multi-channel update server routes and publish tooling."""
import io
import json
import os
import re
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import app
from app import config
from scripts.publish_update import (
    ApkIdentityError,
    calculate_sha256,
    find_aapt2,
    load_registry,
    parse_badging,
    publish_release,
    read_apk_identity,
)

PACKAGE_ID = "in.anisparvez.media_server_client"


def stub_apk_identity(
    version_code: int,
    version_name: str,
    min_sdk: int = 24,
    target_sdk: int = 36,
    package_id: str = PACKAGE_ID,
) -> dict:
    """Stand-in for what aapt2 reports for a real APK (unit tests cannot build one)."""
    return {
        "packageId": package_id,
        "versionCode": str(version_code),
        "versionName": version_name,
        "minSdk": str(min_sdk),
        "targetSdk": str(target_sdk),
    }


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
            with mock.patch(
                "scripts.publish_update.read_apk_identity",
                return_value=stub_apk_identity(101, "1.1.0-dev.101"),
            ):
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
            # SDK levels come from the APK, not from a hardcoded default in the publisher
            self.assertEqual(manifest["minAndroidSdk"], 24)
            self.assertEqual(manifest["targetAndroidSdk"], 36)

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
            with mock.patch(
                "scripts.publish_update.read_apk_identity",
                side_effect=[
                    stub_apk_identity(105, "1.1.0-dev.105"),
                    stub_apk_identity(106, "1.1.0"),
                ],
            ):
                # First publish at code 105
                publish_release(
                    channel="developer",
                    version="1.1.0-dev.105",
                    apk_path=dummy_apk,
                    explicit_version_code=105,
                    updates_dir=self.updates_dir,
                )

                # Attempting publish at code 105 or lower must fail (before the APK is even read)
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


class PublishApkIdentityTests(unittest.TestCase):
    """The APK is the source of truth: a manifest may never disagree with the artifact it ships.

    Regression context: the installed build carried versionCode 103 while a plain
    `flutter build apk --release` stamped pubspec's versionCode 1, so the published version and
    the installed version could disagree. Every one of these tests fails closed.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.updates_dir = Path(self._tmp.name) / "updates"
        self.apk_path = Path(self._tmp.name) / "app-release.apk"
        self.apk_path.write_bytes(b"PK\x03\x04mock-apk-payload")

    def _publish(self, identity, **overrides):
        kwargs = {
            "channel": "developer",
            "version": identity["versionName"],
            "apk_path": self.apk_path,
            "explicit_version_code": int(identity["versionCode"]),
            "updates_dir": self.updates_dir,
        }
        kwargs.update(overrides)
        with mock.patch("scripts.publish_update.read_apk_identity", return_value=identity):
            return publish_release(**kwargs)

    def test_matching_identity_publishes_with_the_apk_values(self):
        manifest = self._publish(stub_apk_identity(110, "1.0.4-dev.110"))
        self.assertEqual(manifest["versionCode"], 110)
        self.assertEqual(manifest["version"], "1.0.4-dev.110")
        self.assertEqual(manifest["minAndroidSdk"], 24)
        self.assertEqual(manifest["targetAndroidSdk"], 36)

    def test_min_supported_version_code_is_written_into_the_manifest(self):
        manifest = self._publish(stub_apk_identity(111, "1.0.4-dev.111"), min_supported_version_code=100)
        self.assertEqual(manifest["minSupportedVersionCode"], 100)

    def test_the_reported_drift_is_now_refused(self):
        """The exact drift that was found: registry at 103, APK built as versionCode 1."""
        self.updates_dir.mkdir(parents=True, exist_ok=True)
        (self.updates_dir / "version_registry.json").write_text(
            json.dumps({"lastVersionCode": 103}), encoding="utf-8"
        )
        with self.assertRaises(ApkIdentityError) as ctx:
            self._publish(
                stub_apk_identity(1, "1.0.4-dev.104"),
                version="1.0.4-dev.104",
                explicit_version_code=None,
            )
        self.assertIn("APK versionCode 1 != allocated versionCode 104", str(ctx.exception))

    def test_version_name_drift_is_refused(self):
        with self.assertRaises(ApkIdentityError) as ctx:
            self._publish(stub_apk_identity(104, "1.0.3"), version="1.0.4-dev.104")
        self.assertIn("versionName '1.0.3'", str(ctx.exception))
        self.assertIn("1.0.4-dev.104", str(ctx.exception))

    def test_foreign_package_id_is_refused(self):
        with self.assertRaises(ApkIdentityError) as ctx:
            self._publish(stub_apk_identity(104, "1.0.4-dev.104", package_id="com.example.other"))
        self.assertIn("com.example.other", str(ctx.exception))

    def test_cli_sdk_override_that_contradicts_the_apk_is_refused(self):
        with self.assertRaises(ApkIdentityError):
            self._publish(stub_apk_identity(105, "1.0.4-dev.105", min_sdk=24), min_android_sdk=26)

    def test_aapt2_output_is_parsed_for_every_identity_field(self):
        # Exactly what build-tools 36 aapt2 prints for the installed build (note the
        # `minSdkVersion:` spelling; the legacy aapt name `sdkVersion:` is accepted too).
        badging = (
            "package: name='in.anisparvez.media_server_client' versionCode='103' versionName='1.0.3' "
            "platformBuildVersionName='16' platformBuildVersionCode='36' compileSdkVersion='36' "
            "compileSdkVersionCodename='16'\r\n"
            "minSdkVersion:'24'\r\n"
            "targetSdkVersion:'36'\r\n"
            "application-label:'media_server_client'\r\n"
        )
        self.assertEqual(
            parse_badging(badging),
            {
                "packageId": PACKAGE_ID,
                "versionCode": "103",
                "versionName": "1.0.3",
                "minSdk": "24",
                "targetSdk": "36",
            },
        )

    def test_legacy_sdk_version_spelling_is_parsed_too(self):
        identity = parse_badging("package: name='x' versionCode='1' versionName='1'\nsdkVersion:'26'\n")
        self.assertEqual(identity["minSdk"], "26")

    def test_missing_aapt2_fails_closed(self):
        with mock.patch("scripts.publish_update.find_aapt2", return_value=None):
            with self.assertRaises(ApkIdentityError) as ctx:
                read_apk_identity(self.apk_path)
        self.assertIn("aapt2 not found", str(ctx.exception))

    @unittest.skipUnless(find_aapt2(), "aapt2 is not available on this host")
    def test_real_apk_identity_round_trip(self):
        """When a real release APK exists, aapt2 must read its identity back correctly."""
        built = (
            Path(__file__).resolve().parent.parent
            / "flutter_client" / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
        )
        if not built.is_file():
            self.skipTest(f"no release APK has been built yet ({built})")
        identity = read_apk_identity(built)
        self.assertEqual(identity["packageId"], PACKAGE_ID)
        self.assertGreater(int(identity["versionCode"]), 0)


class ReleaseToolingTests(unittest.TestCase):
    """scripts/release_android.py must allocate the very code the publisher will then verify."""

    def test_allocates_next_code_and_rejects_non_increasing_ones(self):
        from scripts.release_android import next_version_code

        with tempfile.TemporaryDirectory() as tmp:
            registry_path = Path(tmp) / "version_registry.json"
            registry_path.write_text(json.dumps({"lastVersionCode": 103}), encoding="utf-8")
            self.assertEqual(next_version_code(registry_path, None), 104)
            self.assertEqual(next_version_code(registry_path, 110), 110)
            with self.assertRaises(SystemExit):
                next_version_code(registry_path, 103)

    def test_pubspec_build_number_cannot_outrun_the_published_registry(self):
        """A plain `flutter build apk --release` must never look newer than the published release."""
        repo_root = Path(__file__).resolve().parent.parent
        pubspec = (repo_root / "flutter_client" / "pubspec.yaml").read_text(encoding="utf-8")
        match = re.search(r"^version:\s*[0-9]+\.[0-9]+\.[0-9]+\+([0-9]+)\s*$", pubspec, re.M)
        self.assertIsNotNone(match, "pubspec.yaml must declare `version: X.Y.Z+buildNumber`")
        if match is None:  # narrows the type for static analysis; the assertion above already failed
            return

        registry_path = repo_root / "updates" / "version_registry.json"
        if not registry_path.is_file():
            self.skipTest("this checkout has no published version registry")
        published = int(load_registry(registry_path).get("lastVersionCode", 100))
        self.assertLessEqual(
            int(match.group(1)),
            published,
            "a plain `flutter build apk --release` must never stamp a build number above the published one",
        )


if __name__ == '__main__':
    unittest.main()
