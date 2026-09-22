"""Regression tests: /api/media/delete must never delete files outside the media roots.

Live verification before the fix: POST /api/media/delete/..%5C..%5C..%5CMediaServer%5C<file>
returned {"file_deleted": true} and removed the target, and the absolute-path variant removed
C:\\Windows\\System32\\drivers\\etc\\hosts (the service runs as LocalSystem).
"""
import tempfile
import unittest
from pathlib import Path

from app import config
from app.services.media_service import purge_media, _is_within_media_roots


class MediaDeletePathSafetyTests(unittest.TestCase):
    def setUp(self):
        self.outside = Path(tempfile.mkdtemp(prefix="outside_roots_"))
        self.probe = self.outside / "probe_target.txt"
        self.probe.write_text("must not be deleted\n")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.outside, ignore_errors=True)

    def test_absolute_path_outside_roots_is_refused(self):
        res = purge_media(str(self.probe))
        self.assertFalse(res.get("success"))
        self.assertIn("unsafe", res.get("error", "").lower())
        self.assertTrue(self.probe.exists(), "a file outside the media roots must survive")

    def test_relative_traversal_out_of_media_root_is_refused(self):
        # Walk up from MEDIA_ROOT and back down into the temp dir holding the probe.
        media_root = Path(config.MEDIA_ROOT).resolve()
        up = len(media_root.parts) - 1
        traversal = "\\".join([".."] * up) + str(self.probe)[2:]
        res = purge_media(traversal)
        self.assertFalse(res.get("success"))
        self.assertTrue(self.probe.exists(), "traversal must not delete outside the library")

    def test_legitimate_media_deletion_still_works(self):
        legit = Path(config.MEDIA_ROOT) / "Legit.Delete.Me.2026.mkv"
        legit.parent.mkdir(parents=True, exist_ok=True)
        legit.write_bytes(b"media")
        res = purge_media(legit.name)
        self.assertTrue(res.get("success"), res)
        self.assertFalse(legit.exists())

    def test_within_media_roots_helper(self):
        self.assertFalse(_is_within_media_roots(self.probe))
        self.assertTrue(_is_within_media_roots(Path(config.MEDIA_ROOT) / "Some.Movie.mkv"))
        self.assertFalse(_is_within_media_roots(Path(config.MEDIA_ROOT) / ".." / ".." / "escape.txt"))


if __name__ == "__main__":
    unittest.main()
