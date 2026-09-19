import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import app
from app.services.preview_service import (
    preview_dir,
    preview_meta,
    ensure_preview_thumbnail,
)
from app.services.media_service import purge_media


class SeekPreviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._orig_media_root = app.config.MEDIA_ROOT
        cls._orig_database = app.config.DATABASE
        cls.tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        cls.root = Path(cls.tmp.name)
        app.config.MEDIA_ROOT = cls.root
        app.config.DATABASE = cls.root / "media.db"
        app.init_db()
        cls.client = app.app.test_client()

        cls.video_file = cls.root / "TestMovie.2026.mp4"
        cls.video_file.write_bytes(b"dummy video data for testing")

    @classmethod
    def tearDownClass(cls):
        app.config.MEDIA_ROOT = cls._orig_media_root
        app.config.DATABASE = cls._orig_database
        app.init_db()
        cls.tmp.cleanup()

    def test_preview_dir_is_deterministic(self):
        dir1 = preview_dir(self.video_file)
        dir2 = preview_dir(self.video_file)
        self.assertEqual(dir1, dir2)
        self.assertIn("previews", str(dir1))

    def test_preview_meta_returns_correct_sampling(self):
        # Short video: < 1800s -> 5s interval
        with patch("app.services.preview_service.probe_media", return_value={"format": {"duration": "120.0"}}):
            meta = preview_meta(self.video_file)
            self.assertIsNotNone(meta)
            self.assertEqual(meta["duration"], 120.0)
            self.assertEqual(meta["interval"], 5.0)
            self.assertEqual(meta["count"], 24)

        # Medium video: 3600s -> 10s interval
        with patch("app.services.preview_service.probe_media", return_value={"format": {"duration": "3600.0"}}):
            meta = preview_meta(self.video_file)
            self.assertIsNotNone(meta)
            self.assertEqual(meta["interval"], 10.0)
            self.assertEqual(meta["count"], 360)

        # Long video: 7500s -> 15s interval
        with patch("app.services.preview_service.probe_media", return_value={"format": {"duration": "7500.0"}}):
            meta = preview_meta(self.video_file)
            self.assertIsNotNone(meta)
            self.assertEqual(meta["interval"], 15.0)
            self.assertEqual(meta["count"], 500)

    def test_preview_meta_endpoint(self):
        with patch("app.routes.media.preview_meta", return_value={"duration": 60.0, "interval": 5.0, "count": 12, "directory": preview_dir(self.video_file)}):
            res = self.client.get("/api/seek-preview-meta/TestMovie.2026.mp4")
            self.assertEqual(res.status_code, 200)
            data = res.get_json()
            self.assertEqual(data["duration"], 60.0)
            self.assertEqual(data["interval"], 5.0)
            self.assertEqual(data["count"], 12)
            self.assertIn("/seek-preview/TestMovie.2026.mp4", data["base_url"])

    def test_preview_meta_endpoint_404_on_missing(self):
        res = self.client.get("/api/seek-preview-meta/NonExistent.2026.mp4")
        self.assertEqual(res.status_code, 404)

    def test_seek_preview_thumbnail_endpoint(self):
        # Create a mock thumbnail file in the preview directory
        p_dir = preview_dir(self.video_file)
        p_dir.mkdir(parents=True, exist_ok=True)
        thumb_file = p_dir / "thumb_00000.jpg"
        thumb_file.write_bytes(b"\xff\xd8\xff\xe0" + b"\x00" * 30)  # JPEG magic bytes

        with patch("app.services.preview_service.probe_media", return_value={"format": {"duration": "120.0"}}):
            res = self.client.get("/seek-preview/TestMovie.2026.mp4/thumb_00000.jpg")
            self.assertEqual(res.status_code, 200)
            self.assertEqual(res.mimetype, "image/jpeg")

    def test_seek_preview_thumbnail_404_invalid_pattern(self):
        res = self.client.get("/seek-preview/TestMovie.2026.mp4/invalid_thumb.jpg")
        self.assertEqual(res.status_code, 404)

        res = self.client.get("/seek-preview/TestMovie.2026.mp4/thumb_12.jpg")
        self.assertEqual(res.status_code, 404)

    def test_purge_media_removes_preview_cache(self):
        test_file = self.root / "PurgeMovie.2026.mp4"
        test_file.write_bytes(b"sample video")
        p_dir = preview_dir(test_file)
        p_dir.mkdir(parents=True, exist_ok=True)
        (p_dir / "thumb_00001.jpg").write_bytes(b"dummy")
        self.assertTrue(p_dir.exists())

        purge_media(test_file)
        self.assertFalse(p_dir.exists())
