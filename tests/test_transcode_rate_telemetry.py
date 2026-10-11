"""Transcode speed/ETA telemetry must reflect the job's CURRENT rate.

Three defects lived here:

1. `_initial_cached_sec` walked segment indices densely from 0. On the strided
   layout that stops at the first inter-chunk gap, so a resumed cache holding
   2447s reported 60s - "newly encoded" became the whole cache and speed read
   16.84x on a job actually running near 2x.
2. Speed was a lifetime average since job start, which cannot represent a resume
   or a stall.
3. No ETA was emitted, so the API divided the remainder by an instantaneous value.

The rule the number must satisfy: it is the rate over a trailing window, and it
is withheld entirely until that window is long enough to mean something.
"""
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import app.services.chunk_transcode_service as cts


def _job(tmp: Path):
    hls = tmp / "hls"
    hls.mkdir(parents=True, exist_ok=True)
    media = tmp / "movie.mkv"
    media.write_bytes(b"x" * 1024)
    return cts.DualGPUTranscodeJob("movie.mkv", media, hls, hls / "playlist.m3u8")


class RateWindowTests(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.tmp = Path(self._t.name)
        self.job = _job(self.tmp)
        self.job.total_duration = 3600.0

    def tearDown(self):
        self._t.cleanup()

    def test_withholds_speed_until_window_is_long_enough(self):
        """A two-sample rate over a fraction of a second must not be published."""
        speed, span, eta = self.job._recent_rate_and_eta(100.0, False)
        self.assertEqual(speed, 0.0, "speed must be withheld before the window is credible")
        self.assertIsNone(eta, "no rate means no ETA, not a guess")

    def test_speed_appears_once_the_window_is_credible(self):
        # 120s of content over a 60s wall span = 2.0x
        base = time.time() - 60.0
        self.job._rate_samples.extend([(base, 0.0), (time.time(), 120.0)])
        speed, span, eta = self.job._recent_rate_and_eta(120.0, False)
        self.assertGreater(span, cts.MIN_RATE_WINDOW_S)
        self.assertAlmostEqual(speed, 2.0, delta=0.5)
        self.assertIsNotNone(eta)

    def test_rate_is_recent_not_lifetime(self):
        """A job that raced early then slowed must report the SLOW current rate.

        Samples must span MORE than RATE_WINDOW_S, otherwise the window cannot
        truncate and the whole history is legitimately the window.
        """
        now = time.time()
        # 300s rendered early, then only 60s over the most recent stretch.
        self.job._rate_samples.extend([
            (now - 200.0, 0.0),     # job start
            (now - 100.0, 300.0),   # raced: 300s in the first 100s
            (now - 60.0, 300.0),    # stalled: nothing new for 40s
            (now, 360.0),           # recent: 60s in the last 60s -> ~1x
        ])
        speed, _, _ = self.job._recent_rate_and_eta(360.0, False)
        lifetime = 360.0 / 200.0
        self.assertAlmostEqual(speed, 1.0, delta=0.3,
                               msg="the trailing window should see the recent ~1x")
        self.assertLess(speed, lifetime * 0.7,
                        f"reported {speed}x vs lifetime {lifetime:.2f}x - the lifetime "
                        f"average is leaking through the window")

    def test_zero_progress_yields_no_rate(self):
        """A stalled job must report no speed, not a division by a stalled delta."""
        now = time.time()
        self.job._rate_samples.extend([(now - 60.0, 100.0), (now, 100.0)])
        speed, _, eta = self.job._recent_rate_and_eta(100.0, False)
        self.assertEqual(speed, 0.0)
        self.assertIsNone(eta)

    def test_complete_reports_zero_eta(self):
        self.job._rate_samples.extend([(time.time() - 60.0, 0.0), (time.time(), 100.0)])
        speed, _, eta = self.job._recent_rate_and_eta(100.0, True)
        self.assertEqual(speed, 0.0)
        self.assertEqual(eta, 0.0)

    def test_sample_buffer_is_bounded(self):
        for i in range(500):
            self.job._recent_rate_and_eta(float(i), False)
        self.assertLessEqual(len(self.job._rate_samples), 300,
                             "the sample buffer must not grow without bound")

    def test_eta_uses_total_duration_not_container(self):
        now = time.time()
        self.job._rate_samples.extend([(now - 60.0, 0.0), (now, 60.0)])
        _, _, eta = self.job._recent_rate_and_eta(60.0, False)
        # 3600s total, 60s done, ~1x -> ~3540s left
        self.assertAlmostEqual(eta, 3540.0, delta=120.0)


class InitialCacheAccountingTests(unittest.TestCase):
    """The dense-walk bug: a strided cache must not be counted as 60 seconds."""

    def test_strided_cache_is_counted_in_full(self):
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as td:
            tmp = Path(td)
            job = _job(tmp)
            # Strided layout: chunk 0 owns 0..14, chunk 1 owns 32..46.
            for i in list(range(0, 15)) + list(range(32, 47)):
                (job.hls_dir / f"segment_{i:06d}.ts").write_bytes(b"x" * 16)

            dense = 0
            while (job.hls_dir / f"segment_{dense:06d}.ts").is_file():
                dense += 1
            self.assertEqual(dense, 15, "precondition: the dense walk stops at the first gap")

            actual = len(list(job.hls_dir.glob("segment_*.ts")))
            self.assertEqual(actual, 30)
            # What the job must use:
            self.assertAlmostEqual(
                actual * cts.SEGMENT_TARGET_DURATION,
                120.0,
                delta=0.1,
                msg="a 30-segment strided cache is 120s, not the 60s a dense walk reports")


class ProgressFileTests(unittest.TestCase):
    def test_progress_file_carries_eta_and_window(self):
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as td:
            tmp = Path(td)
            job = _job(tmp)
            job.total_duration = 3600.0
            now = time.time()
            job._rate_samples.extend([(now - 60.0, 0.0), (now, 120.0)])

            job._write_progress_file(120.0, False)
            text = (job.hls_dir / "hls.progress").read_text()
            values = dict(
                line.split("=", 1) for line in text.splitlines() if "=" in line
            )
            self.assertIn("speed", values)
            self.assertIn("eta_s", values)
            self.assertIn("rate_window_s", values)
            self.assertNotEqual(values["eta_s"], "", "a credible rate must publish an ETA")


if __name__ == "__main__":
    unittest.main()
