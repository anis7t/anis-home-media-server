"""Tests for storage retention policies, orphaned cache auditing, and safe cache purging."""
import json
import os
import shutil
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

import app
from app.db import get_db, get_setting, init_db, set_setting
from app.services.transcode_service import (
    apply_post_transcode_policy,
    audit_orphaned_caches,
    get_cache_dir,
    hls_cache_dir,
    purge_orphaned_caches,
    purge_transcode_caches_for_media,
)


class StorageRetentionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        init_db()
        cls.client = app.app.test_client()

    def test_settings_db_table_and_get_set(self):
        """Verify settings table persists and retrieves key-value configuration."""
        # Default value for unset key
        self.assertEqual(get_setting('non_existent_key_1234', 'fallback'), 'fallback')
        self.assertIsNone(get_setting('another_unset_key_1234'))

        # Set and get
        set_setting('retention_policy', 'archive')
        self.assertEqual(get_setting('retention_policy'), 'archive')

        set_setting('retention_policy', 'keep')
        self.assertEqual(get_setting('retention_policy'), 'keep')

        set_setting('retention_policy', 'purge_cache')
        self.assertEqual(get_setting('retention_policy'), 'purge_cache')

        # Reset to default keep
        set_setting('retention_policy', 'keep')

    def test_audit_and_purge_orphaned_caches(self):
        """Verify audit distinguishes active vs orphaned directories, and purge cleans orphans."""
        cache_base = get_cache_dir()
        hls_base = cache_base / 'hls'
        previews_base = cache_base / 'previews'
        hls_base.mkdir(parents=True, exist_ok=True)
        previews_base.mkdir(parents=True, exist_ok=True)

        # 1. Create a dummy active movie
        active_movie = app.config.MEDIA_ROOT / "TestActiveMovie.2026.mkv"
        active_movie.write_bytes(b"dummy active video content")
        app._paths = (0, [])

        active_hls = hls_cache_dir(active_movie)
        active_hls.mkdir(parents=True, exist_ok=True)
        (active_hls / "playlist.m3u8").write_text("#EXTM3U\n#EXT-X-ENDLIST\n")
        (active_hls / "segment_000000.ts").write_bytes(b"12345")

        # 2. Create orphaned directories
        orphan_hls_1 = hls_base / "orphan_hls_fakehash1"
        orphan_hls_1.mkdir(parents=True, exist_ok=True)
        (orphan_hls_1 / "segment_000000.ts").write_bytes(b"A" * 1000)

        orphan_hls_2 = hls_base / "orphan_hls_fakehash2"
        orphan_hls_2.mkdir(parents=True, exist_ok=True)
        (orphan_hls_2 / "segment_000000.ts").write_bytes(b"B" * 2000)

        orphan_preview = previews_base / "orphan_prev_fakehash1"
        orphan_preview.mkdir(parents=True, exist_ok=True)
        (orphan_preview / "thumb_0000.jpg").write_bytes(b"C" * 500)

        try:
            # 3. Audit should discover the orphans
            audit = audit_orphaned_caches()
            orphaned_hls_names = [o['name'] for o in audit['orphaned_hls']]
            orphaned_prev_names = [o['name'] for o in audit['orphaned_previews']]
            active_hls_names = [a['name'] for a in audit['active_hls']]

            self.assertIn("orphan_hls_fakehash1", orphaned_hls_names)
            self.assertIn("orphan_hls_fakehash2", orphaned_hls_names)
            self.assertIn("orphan_prev_fakehash1", orphaned_prev_names)
            self.assertIn(active_hls.name, active_hls_names)
            self.assertGreaterEqual(audit['total_orphaned_bytes'], 3500)

            # 4. Dry run purge should report what will be cleaned without deleting
            dry_run_res = purge_orphaned_caches(dry_run=True)
            self.assertTrue(dry_run_res['dry_run'])
            self.assertGreaterEqual(dry_run_res['purged_count'], 3)
            self.assertTrue(orphan_hls_1.exists())
            self.assertTrue(orphan_preview.exists())

            # 5. Live purge should safely delete orphaned directories
            live_res = purge_orphaned_caches(dry_run=False)
            self.assertFalse(live_res['dry_run'])
            self.assertGreaterEqual(live_res['purged_count'], 3)
            self.assertFalse(orphan_hls_1.exists())
            self.assertFalse(orphan_hls_2.exists())
            self.assertFalse(orphan_preview.exists())

            # Active transcode cache must remain completely untouched!
            self.assertTrue(active_hls.exists())
            self.assertTrue((active_hls / "segment_000000.ts").exists())

        finally:
            # Cleanup test movie and active cache
            active_movie.unlink(missing_ok=True)
            shutil.rmtree(active_hls, ignore_errors=True)
            shutil.rmtree(orphan_hls_1, ignore_errors=True)
            shutil.rmtree(orphan_hls_2, ignore_errors=True)
            shutil.rmtree(orphan_preview, ignore_errors=True)
            app._paths = (0, [])

    def test_apply_post_transcode_policy_keep(self):
        """Policy 'keep' leaves source file and cache intact."""
        test_file = app.config.MEDIA_ROOT / "PolicyKeepTest.2026.mkv"
        test_file.write_bytes(b"content for keep policy")
        hls_dir = hls_cache_dir(test_file)
        hls_dir.mkdir(parents=True, exist_ok=True)
        pl = hls_dir / "playlist.m3u8"
        pl.write_text("#EXTM3U\n#EXT-X-ENDLIST\n")

        with patch("app.services.transcode_service._is_hls_truly_complete", return_value=True):
            res = apply_post_transcode_policy(test_file, policy="keep")
            self.assertEqual(res["status"], "kept")
            self.assertEqual(res["policy"], "keep")
            self.assertTrue(test_file.exists())
            self.assertTrue(hls_dir.exists())

        test_file.unlink(missing_ok=True)
        shutil.rmtree(hls_dir, ignore_errors=True)

    def test_apply_post_transcode_policy_archive(self):
        """Policy 'archive' moves source file to ARCHIVE_DIR preserving relative path."""
        test_file = app.config.MEDIA_ROOT / "PolicyArchiveTest.2026.mkv"
        test_file.write_bytes(b"content for archive policy")
        hls_dir = hls_cache_dir(test_file)
        hls_dir.mkdir(parents=True, exist_ok=True)
        pl = hls_dir / "playlist.m3u8"
        pl.write_text("#EXTM3U\n#EXT-X-ENDLIST\n")

        expected_archive = app.config.ARCHIVE_DIR / "PolicyArchiveTest.2026.mkv"
        expected_archive.unlink(missing_ok=True)

        with patch("app.services.transcode_service._is_hls_truly_complete", return_value=True):
            res = apply_post_transcode_policy(test_file, policy="archive")
            self.assertEqual(res["status"], "archived")
            self.assertEqual(res["policy"], "archive")
            self.assertFalse(test_file.exists())
            self.assertTrue(expected_archive.exists())
            self.assertTrue(hls_dir.exists())

        expected_archive.unlink(missing_ok=True)
        shutil.rmtree(hls_dir, ignore_errors=True)

    def test_apply_post_transcode_policy_purge_cache(self):
        """Policy 'purge_cache' purges HLS directory while keeping original source."""
        test_file = app.config.MEDIA_ROOT / "PolicyPurgeCacheTest.2026.mkv"
        test_file.write_bytes(b"content for purge_cache policy")
        hls_dir = hls_cache_dir(test_file)
        hls_dir.mkdir(parents=True, exist_ok=True)
        pl = hls_dir / "playlist.m3u8"
        pl.write_text("#EXTM3U\n#EXT-X-ENDLIST\n")
        (hls_dir / "segment_000000.ts").write_bytes(b"abc")

        with patch("app.services.transcode_service._is_hls_truly_complete", return_value=True):
            res = apply_post_transcode_policy(test_file, policy="purge_cache")
            self.assertEqual(res["status"], "cache_purged")
            self.assertEqual(res["policy"], "purge_cache")
            self.assertTrue(test_file.exists())
            self.assertFalse(hls_dir.exists())

        test_file.unlink(missing_ok=True)
        shutil.rmtree(hls_dir, ignore_errors=True)

    def test_apply_post_transcode_policy_delete_source(self):
        """Policy 'delete_source' truncates original source to 0 bytes while keeping HLS cache intact."""
        test_file = app.config.MEDIA_ROOT / "PolicyDeleteSourceTest.2026.mkv"
        test_file.write_bytes(b"large raw multi-gigabyte source data")
        self.assertGreater(test_file.stat().st_size, 0)

        hls_dir = hls_cache_dir(test_file)
        hls_dir.mkdir(parents=True, exist_ok=True)
        pl = hls_dir / "playlist.m3u8"
        pl.write_text("#EXTM3U\n#EXT-X-ENDLIST\n")
        (hls_dir / "segment_000000.ts").write_bytes(b"hls_video_segment")

        with patch("app.services.transcode_service._is_hls_truly_complete", return_value=True):
            res = apply_post_transcode_policy(test_file, policy="delete_source")
            self.assertEqual(res["status"], "source_deleted")
            self.assertEqual(res["policy"], "delete_source")
            self.assertTrue(test_file.exists())
            self.assertEqual(test_file.stat().st_size, 0)
            self.assertTrue(hls_dir.exists())
            self.assertTrue((hls_dir / "playlist.m3u8").exists())

        test_file.unlink(missing_ok=True)
        shutil.rmtree(hls_dir, ignore_errors=True)

    def test_api_storage_endpoints(self):
        """Test /api/storage/audit, /api/storage/settings, and /api/storage/purge-orphans."""
        # 1. GET /api/storage/audit
        res = self.client.get("/api/storage/audit")
        self.assertEqual(res.status_code, 200)
        data = res.get_json()
        self.assertIn("storage", data)
        self.assertIn("audit", data)
        self.assertIn("total_orphaned_dirs", data["audit"])

        # 2. GET /api/storage/settings
        res = self.client.get("/api/storage/settings")
        self.assertEqual(res.status_code, 200)
        data = res.get_json()
        self.assertIn("retention_policy", data)
        self.assertIn("allowed_policies", data)

        # 3. POST /api/storage/settings (valid)
        res = self.client.post("/api/storage/settings", json={"retention_policy": "archive"})
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.get_json()["retention_policy"], "archive")
        self.assertEqual(get_setting("retention_policy"), "archive")

        # 4. POST /api/storage/settings (invalid policy)
        res = self.client.post("/api/storage/settings", json={"retention_policy": "invalid_policy"})
        self.assertEqual(res.status_code, 400)
        self.assertFalse(res.get_json()["success"])

        # Reset policy
        self.client.post("/api/storage/settings", json={"retention_policy": "keep"})

        # 5. POST /api/storage/purge-orphans (dry-run)
        res = self.client.post("/api/storage/purge-orphans?dry_run=true")
        self.assertEqual(res.status_code, 200)
        data = res.get_json()
        self.assertTrue(data["success"])
        self.assertTrue(data["result"]["dry_run"])

    def test_manage_page_storage_governance_render(self):
        """Verify /manage and /library render storage governance UI without template errors."""
        res = self.client.get("/manage")
        self.assertEqual(res.status_code, 200)
        html = res.data.decode("utf-8")
        self.assertIn("Storage Retention & Transcode Cache Governance", html)
        self.assertIn("Host Storage Pool", html)
        self.assertIn("Post-Transcode Retention Policy", html)
        self.assertIn("Orphaned Transcode Caches", html)
        self.assertIn("cleanOrphansModal", html)
    def test_multi_root_media_resolution_and_archive(self):
        """Verify safe_path and video_paths discover files on secondary roots and archive keeps them accessible."""
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp_archive_dir:
            archive_path = Path(tmp_archive_dir)
            with patch.object(app.config, 'ARCHIVE_DIR', archive_path):
                # 1. Create file in archive root
                archived_movie = archive_path / "ArchivedMovie.2026.mkv"
                archived_movie.write_bytes(b"archived movie contents")

                # Invalidate paths cache
                app._paths = (0, [])

                # 2. Test safe_path finds archived file
                from app.utils.filesystem import safe_path
                resolved = safe_path("ArchivedMovie.2026.mkv")
                self.assertEqual(resolved.resolve(), archived_movie.resolve())

                # 3. Test video_paths discovers it
                from app.services.media_service import video_paths
                paths = video_paths()
                self.assertIn(archived_movie.resolve(), [p.resolve() for p in paths])

                # 4. Clean up
                app._paths = (0, [])


if __name__ == "__main__":
    unittest.main()
