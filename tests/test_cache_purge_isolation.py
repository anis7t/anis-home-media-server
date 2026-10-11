"""CachePurgeSafetyTests must never purge beyond its own fixtures.

Every test in `CachePurgeSafetyTests` drives a **live** purge (`purge_orphaned_caches(dry_run=False)`),
and a purge deletes every cache directory under the active root that no enumerated media maps to.
While that root was the shared session cache, those purges could delete directories belonging to
*other* tests - reproduced here: a directory planted in the shared root by an unrelated test was
destroyed by `CachePurgeSafetyTests` while the entire suite still reported green.

A green suite is exactly what made this invisible. The planted directory's owner has no assertion
about its own survival, so nothing failed; the only symptom was a fixture quietly vanishing.

These tests pin the blast radius rather than the happy path, because the happy path was already
covered and passing throughout.
"""
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app  # noqa: E402
import test_storage_retention as tsr  # noqa: E402
from app.services.transcode_service import get_cache_dir  # noqa: E402


class CachePurgeIsolationTests(unittest.TestCase):
    """The shared session cache root must be unreachable from these purges."""

    def _shared_root(self):
        return Path(get_cache_dir()).resolve()

    def test_shared_cache_root_is_untouched_by_cache_purge_safety_tests(self):
        """THE regression: run the whole class, then assert the shared root is byte-identical.

        Snapshots the shared root before and after, rather than planting a single directory, so a
        purge that removes more than one thing is caught too.
        """
        shared = self._shared_root()
        hls = shared / "hls"
        hls.mkdir(parents=True, exist_ok=True)

        # A directory owned by nobody in this file - the shape of another test's fixture.
        stranger = hls / "BELONGS_TO_ANOTHER_TEST"
        stranger.mkdir(parents=True, exist_ok=True)
        (stranger / "segment_000000.ts").write_bytes(b"S" * 4096)

        def snapshot():
            out = {}
            for base in ("hls", "previews"):
                root = shared / base
                if not root.is_dir():
                    continue
                for d in sorted(root.iterdir()):
                    if not d.is_dir():
                        continue
                    out[f"{base}/{d.name}"] = sorted(
                        (f.name, f.stat().st_size) for f in d.rglob("*") if f.is_file()
                    )
            return out

        before = snapshot()

        # Drive the class exactly as the suite does: its own setUp/tearDown, real live purges.
        suite = unittest.TestLoader().loadTestsFromTestCase(tsr.CachePurgeSafetyTests)
        result = unittest.TextTestRunner(stream=open(os.devnull, "w"), verbosity=0).run(suite)
        self.assertTrue(result.wasSuccessful(),
                        f"CachePurgeSafetyTests failed: {result.errors + result.failures}")

        after = snapshot()
        self.assertEqual(before, after,
                         "CachePurgeSafetyTests modified the shared session cache root")
        self.assertTrue(stranger.is_dir(),
                        "a live purge deleted a directory it did not create")
        shutil.rmtree(stranger, ignore_errors=True)

    def test_each_test_gets_a_dedicated_root_not_the_shared_one(self):
        """setUp must point the app at a fresh tree and tearDown must restore it."""
        shared = self._shared_root()

        case = tsr.CachePurgeSafetyTests("test_purge_spares_directory_in_active_use")
        case.setUp()
        try:
            dedicated = Path(app.CACHE_DIR).resolve()
            self.assertNotEqual(dedicated, shared,
                                "setUp left the app on the shared session cache root")
            self.assertTrue(tsr._within(dedicated, tempfile.gettempdir()))
            self.assertEqual(Path(app.config.CACHE_DIR).resolve(), dedicated)
            # The tree the class actually purges is beneath the dedicated root.
            self.assertTrue(tsr._within(case.hls_base, dedicated), case.hls_base)
        finally:
            case.tearDown()

        self.assertEqual(Path(app.CACHE_DIR).resolve(), shared,
                         "tearDown did not restore the shared cache root")
        self.assertEqual(Path(app.config.CACHE_DIR).resolve(), shared,
                         "tearDown did not restore config.CACHE_DIR")

    def test_the_dedicated_root_is_removed_after_each_test(self):
        """No temp trees accumulate across a session, and nothing points at a deleted tree."""
        case = tsr.CachePurgeSafetyTests("test_purge_spares_directory_in_active_use")
        case.setUp()
        dedicated = Path(app.CACHE_DIR).resolve()
        self.assertTrue(dedicated.is_dir())
        case.tearDown()
        self.assertFalse(dedicated.exists(), "the dedicated cache root outlived its test")

    def test_a_second_test_gets_a_different_root(self):
        """Two consecutive tests must not share a root, or one can delete the other's fixtures."""
        first = tsr.CachePurgeSafetyTests("test_purge_spares_directory_in_active_use")
        first.setUp()
        root_a = Path(app.CACHE_DIR).resolve()
        first.tearDown()

        second = tsr.CachePurgeSafetyTests("test_purge_spares_directory_in_active_use")
        second.setUp()
        root_b = Path(app.CACHE_DIR).resolve()
        second.tearDown()

        self.assertNotEqual(root_a, root_b, "two tests shared one cache root")


if __name__ == "__main__":
    unittest.main()
