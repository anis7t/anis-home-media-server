"""Frame-accounting measurement must never report "unknown" as "empty".

`measure_segment_frame_count` deliberately refuses to probe a segment written less
than _SEGMENT_PROBE_FRESH_SECONDS ago, because the 1 Hz progress updater would
otherwise read a half-written file. That refusal used to return 0 - a genuine zero
frame count - so a chunk re-rendered by the serial repair measured its own
brand-new segments as empty, ENDLIST was refused, and the cache sat "incomplete"
while measuring complete minutes later.

These tests pin the distinction at the boundary it was lost at.
"""
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services import transcode_service as ts
from app.services.chunk_transcode_service import expected_frames_for_window


class FreshSegmentIsUnknownTests(unittest.TestCase):
    """A segment inside the freshness window must measure as -1, not 0."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.dir = Path(self._tmp.name)
        self.seg = self.dir / "segment_000000.ts"
        self.seg.write_bytes(b"x" * 4096)

    def tearDown(self):
        self._tmp.cleanup()

    def test_recently_written_segment_is_unknown(self):
        age = time.time() - self.seg.stat().st_mtime
        self.assertLess(age, ts._SEGMENT_PROBE_FRESH_SECONDS,
                        "precondition: segment must be inside the freshness window")
        ts.clear_segment_probe_cache()
        self.assertEqual(ts.measure_segment_frame_count(self.seg), -1)

    def test_zero_byte_segment_is_unknown(self):
        empty = self.dir / "segment_000001.ts"
        empty.touch()
        ts.clear_segment_probe_cache()
        self.assertEqual(ts.measure_segment_frame_count(empty), -1)

    def test_missing_file_is_unknown(self):
        ts.clear_segment_probe_cache()
        self.assertEqual(ts.measure_segment_frame_count(self.dir / "nope.ts"), -1)

    def test_aged_segment_is_actually_measured(self):
        """The guard must expire: an old, readable segment is probed, not skipped."""
        mtime = time.time() - (ts._SEGMENT_PROBE_FRESH_SECONDS + 10)
        os.utime(self.seg, (mtime, mtime))
        ts.clear_segment_probe_cache()
        self.assertIsNotNone(ts._segment_cache_key(self.seg),
                             "precondition: aged segment must be probeable")
        with patch.object(ts, '_ffprobe_bin', return_value=None):
            # No ffprobe available is itself 'unknown', never a silent zero.
            self.assertEqual(ts.measure_segment_frame_count(self.seg), -1)

    def test_never_returns_zero_without_a_successful_read(self):
        """0 is reserved for a segment ffprobe actually read and found empty."""
        mtime = time.time() - (ts._SEGMENT_PROBE_FRESH_SECONDS + 10)
        os.utime(self.seg, (mtime, mtime))
        ts.clear_segment_probe_cache()

        class _Fail:
            returncode = 1
            stdout = ""

        with patch.object(ts, '_ffprobe_bin', return_value='ffprobe'), \
             patch.object(ts.subprocess, 'run', return_value=_Fail()):
            self.assertEqual(ts.measure_segment_frame_count(self.seg), -1)

        class _EmptyOk:
            returncode = 0
            stdout = "0\n"

        ts.clear_segment_probe_cache()
        with patch.object(ts, '_ffprobe_bin', return_value='ffprobe'), \
             patch.object(ts.subprocess, 'run', return_value=_EmptyOk()):
            self.assertEqual(ts.measure_segment_frame_count(self.seg), 0,
                             "a genuine, successfully-read empty segment IS zero")


class ChunkAccountingSkipsUnmeasurableTests(unittest.TestCase):
    """An unmeasurable chunk must be skipped, never reported as deficient.

    plan_chunks / expected_frames_for_window / cache_uses_strided_layout are
    imported *inside* chunk_content_deficits(), so they must be patched at their
    source module or the patch never takes effect.
    """

    def setUp(self):
        stub = tempfile.NamedTemporaryFile(suffix=".mkv", delete=False)
        stub.close()
        self.addCleanup(lambda: os.unlink(stub.name))
        self.seg_stub = stub.name

    def _run(self, counts, per_seg):
        import app.services.chunk_transcode_service as cts
        tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.addCleanup(tmp.cleanup)
        hls = Path(tmp.name)
        chunk = {'chunk_id': 0, 'start_time': 0.0, 'duration': 60.0,
                 'start_seg': 0, 'expected_segs': 15}
        for i in range(15):
            (hls / f"segment_{i:06d}.ts").write_bytes(b"x" * 1024)
        with patch.object(cts, 'plan_chunks', return_value=[chunk]), \
             patch.object(cts, 'cache_uses_strided_layout', return_value=True), \
             patch.object(cts, 'expected_frames_for_window', return_value=len(counts) * per_seg), \
             patch.object(ts, 'source_frame_rate', return_value=24.0), \
             patch.object(ts, 'measure_segment_frame_count', side_effect=counts):
            return ts.chunk_content_deficits(str(hls), 60.0,
                                              source_path=str(self.seg_stub))

    def test_chunk_with_unmeasurable_segment_is_skipped(self):
        per_seg = expected_frames_for_window(0, 4.0, 24.0)
        deficits = self._run([120] * 14 + [-1], per_seg)
        self.assertEqual(deficits, [],
                         "one unmeasurable segment must make the whole chunk unjudgeable, "
                         "not deficient")

    def test_chunk_with_one_short_segment_is_still_flagged(self):
        """Guarding unknown must not blunt the real check."""
        per_seg = expected_frames_for_window(0, 4.0, 24.0)
        deficits = self._run([per_seg] * 14 + [per_seg // 2], per_seg)
        self.assertEqual(len(deficits), 1, "a genuinely short segment must still be flagged")
        self.assertGreater(deficits[0]['missing_frames'], 0)


if __name__ == "__main__":
    unittest.main()
