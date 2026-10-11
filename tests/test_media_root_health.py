"""A misconfigured media root must announce itself at startup.

The deployed service ran with MEDIA_SERVER_MEDIA_ROOT pointing at an empty
C:\\Flicks while .env and the project docs both said D:\\Flicks, and nothing said
so for an unknown period. The library still resolved - get_media_roots() falls back
to UPLOAD_TARGET_DIR, which hardcodes D: when the drive exists - so the failure mode
is a root that is wrong AND appears to work.

media_root_health() is the check that makes it visible. It is diagnostic only:
it never raises, never mutates, and returns problem strings rather than booleans so
the startup log can say what is actually wrong.
"""
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.media_service import media_root_health


class MediaRootHealthTests(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.tmp = Path(self._t.name)

    def tearDown(self):
        self._t.cleanup()

    def _health(self, roots):
        with patch("app.config.get_media_roots", return_value=roots):
            return media_root_health()

    def test_healthy_root_reports_nothing(self):
        root = self.tmp / "library"
        root.mkdir()
        (root / "A.2026.mkv").write_bytes(b"x")
        self.assertEqual(self._health([root]), [])

    def test_missing_root_is_reported(self):
        missing = self.tmp / "not-there"
        problems = self._health([missing])
        self.assertTrue(any("does not exist" in p for p in problems), problems)

    def test_empty_root_is_reported_with_the_reason_it_is_dangerous(self):
        empty = self.tmp / "empty"
        empty.mkdir()
        problems = self._health([empty])
        self.assertTrue(any("EMPTY" in p for p in problems), problems)
        self.assertTrue(any("fallback" in p for p in problems),
                        "must explain why an empty root is dangerous, not just that it is empty")

    def test_file_where_a_directory_belongs_is_reported(self):
        f = self.tmp / "afile"
        f.write_bytes(b"x")
        problems = self._health([f])
        self.assertTrue(any("not a directory" in p for p in problems), problems)

    def test_no_roots_configured_is_reported(self):
        problems = self._health([])
        self.assertTrue(any("no media roots" in p for p in problems), problems)

    def test_one_bad_root_among_good_ones_is_still_reported(self):
        good = self.tmp / "good"
        good.mkdir()
        (good / "A.mkv").write_bytes(b"x")
        bad = self.tmp / "bad"
        problems = self._health([good, bad])
        self.assertTrue(any("does not exist" in p for p in problems), problems)
        self.assertFalse(any("EMPTY" in p for p in problems),
                         "a populated root must not be flagged")

    def test_unreadable_root_does_not_raise(self):
        """A permission problem is reported, never raised - this runs at startup."""
        root = self.tmp / "locked"
        root.mkdir()
        with patch("app.config.get_media_roots", return_value=[root]), \
             patch.object(Path, "iterdir", side_effect=PermissionError("denied")):
            problems = media_root_health()
        self.assertTrue(problems)
        self.assertTrue(any("not readable" in p for p in problems), problems)

    def test_root_enumeration_failure_is_reported_not_raised(self):
        with patch("app.config.get_media_roots", side_effect=RuntimeError("registry gone")):
            problems = media_root_health()
        self.assertTrue(any("unreadable" in p for p in problems), problems)


if __name__ == "__main__":
    unittest.main()
