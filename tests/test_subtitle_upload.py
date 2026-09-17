"""Integration tests for POST /api/upload-subtitle/<path:filename>."""
import io
import os
import tempfile
import unittest
from unittest import mock
from pathlib import Path

# ── Env setup MUST happen before importing app ────────────────────────────────
if "MEDIA_SERVER_MEDIA_ROOT" not in os.environ:
    _TMP = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
    os.environ["MEDIA_SERVER_MEDIA_ROOT"] = _TMP.name
    os.environ["MEDIA_SERVER_DATABASE"] = str(Path(_TMP.name) / "media.db")

import app  # noqa: E402
from app import config  # noqa: E402


class SubtitleUploadRouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Use the authoritative MEDIA_ROOT from the loaded config,
        # which may have been set by another test module in the same pytest run.
        cls.root = config.MEDIA_ROOT
        cls.media = cls.root / "Moana.2016.mp4"
        cls.media.write_bytes(b"0" * 20)
        app.init_db()
        cls.client = app.app.test_client()

    @classmethod
    def tearDownClass(cls):
        cls.media.unlink(missing_ok=True)

    # ── helpers ───────────────────────────────────────────────────────────────

    def _upload(self, filename, content, upload_name):
        data = {"subtitle": (io.BytesIO(content), upload_name)}
        return self.client.post(
            f"/api/upload-subtitle/{filename}",
            data=data,
            content_type="multipart/form-data",
        )

    # ── Happy path: English .srt ──────────────────────────────────────────────
    def test_upload_srt_en_creates_named_file(self):
        srt_content = (
            "1\n00:00:01,000 --> 00:00:04,000\n"
            "This is an English subtitle test for the upload feature.\n"
        ).encode("utf-8")
        resp = self._upload("Moana.2016.mp4", srt_content, "input.srt")
        self.assertEqual(resp.status_code, 200)
        body = resp.get_json()
        self.assertTrue(body["success"])
        self.assertEqual(body["language"], "en")
        self.assertTrue(body["filename"].startswith("moana_en_"))
        self.assertTrue(body["filename"].endswith(".srt"))
        saved = self.root / body["filename"]
        self.assertTrue(saved.is_file())
        saved.unlink()

    # ── Happy path: .vtt file ─────────────────────────────────────────────────
    def test_upload_vtt_creates_named_file(self):
        vtt_content = (
            "WEBVTT\n\n"
            "1\n00:00:01.000 --> 00:00:04.000\n"
            "Bonjour, je suis un sous-titre pour ce film.\n"
        ).encode("utf-8")
        resp = self._upload("Moana.2016.mp4", vtt_content, "french.vtt")
        self.assertEqual(resp.status_code, 200)
        body = resp.get_json()
        self.assertTrue(body["success"])
        self.assertTrue(body["filename"].endswith(".vtt"))
        saved = self.root / body["filename"]
        self.assertTrue(saved.is_file())
        saved.unlink()

    # ── Counter increments on collision ───────────────────────────────────────
    def test_counter_increments_on_collision(self):
        preexisting = self.root / "moana_en_1.srt"
        preexisting.write_text("dummy", encoding="utf-8")
        try:
            srt_content = (
                "1\n00:00:01,000 --> 00:00:03,000\n"
                "Another English subtitle to force counter increment.\n"
            ).encode("utf-8")
            resp = self._upload("Moana.2016.mp4", srt_content, "en2.srt")
            self.assertEqual(resp.status_code, 200)
            body = resp.get_json()
            self.assertTrue(body["success"])
            counter = int(body["filename"].rsplit("_", 1)[-1].split(".")[0])
            self.assertGreaterEqual(counter, 2)
            (self.root / body["filename"]).unlink(missing_ok=True)
        finally:
            preexisting.unlink(missing_ok=True)

    # ── 404 for non-existent media ────────────────────────────────────────────
    def test_404_when_media_not_found(self):
        resp = self._upload("definitely_nonexistent_xyz_1234.mp4", b"dummy", "en.srt")
        self.assertEqual(resp.status_code, 404)
        body = resp.get_json()
        if body is not None:
            self.assertFalse(body["success"])

    # ── 400 when no subtitle field ────────────────────────────────────────────
    def test_400_when_no_file_provided(self):
        resp = self.client.post(
            "/api/upload-subtitle/Moana.2016.mp4",
            data={},
            content_type="multipart/form-data",
        )
        self.assertEqual(resp.status_code, 400)
        self.assertFalse(resp.get_json()["success"])

    # ── 415 for unsupported extension ─────────────────────────────────────────
    def test_415_for_unsupported_extension(self):
        resp = self._upload("Moana.2016.mp4", b"[Script Info]\n", "movie.ass")
        self.assertEqual(resp.status_code, 415)
        body = resp.get_json()
        self.assertFalse(body["success"])
        self.assertIn(".ass", body["error"])

    # ── Cross-root mirror subtitle discovery & delivery ──────────────────────
    def test_cross_root_mirror_subtitle_discovery_and_delivery(self):
        """Test that archived media in subdirectories discovers sidecar subtitles in mirror directories."""
        from app.services.subtitles_service import tracks
        import shutil

        sub_dir_name = "www.TestFolder.org - Test.Movie.2026"
        mirror_folder = self.root / sub_dir_name
        mirror_folder.mkdir(parents=True, exist_ok=True)
        sidecar_sub = mirror_folder / "Test.Movie.2026.srt"
        sidecar_sub.write_text("1\n00:00:01,000 --> 00:00:04,000\nHello from original folder\n", encoding="utf-8")

        archive_folder = self.root / ".archive" / sub_dir_name
        archive_folder.mkdir(parents=True, exist_ok=True)
        video = archive_folder / "Test.Movie.2026.mp4"
        video.write_bytes(b"0" * 20)

        try:
            with mock.patch.object(config, "get_media_roots", return_value=[self.root, self.root / ".archive"]):
                trk_list = tracks(video)
                sidecar_matches = [t for t in trk_list if t.get("name") == "Test.Movie.2026.srt"]
                self.assertEqual(len(sidecar_matches), 1)
                self.assertEqual(sidecar_matches[0]["lang"], "en")

                # Test delivery route
                resp = self.client.get(sidecar_matches[0]["src"])
                self.assertEqual(resp.status_code, 200)
                self.assertIn(b"WEBVTT", resp.data)
                self.assertIn(b"Hello from original folder", resp.data)
        finally:
            shutil.rmtree(mirror_folder, ignore_errors=True)
            shutil.rmtree(archive_folder, ignore_errors=True)



if __name__ == "__main__":
    unittest.main()
