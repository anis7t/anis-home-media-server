"""Tests for the per-source transcode strategy and worker sizing.

The adaptive strategy changes the filter chain for 8-bit sources and runs more
chunk workers than there are GPUs, so the two properties that must hold are:

1. the direct (no-vpp_amf) path is only ever selected for a source that
   genuinely needs neither a resize nor a depth conversion, and
2. duplicated workers never share a name, because the chunk scheduler retires
   a GPU for a whole job by name.

Anything unprobed must fall back to the historical pipeline.
"""
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services import gpu_service
from app.services.gpu_service import (
    GPUWorkerConfig,
    HLS_MAX_HEIGHT,
    adaptive_strategy_enabled,
    expand_workers,
    select_amf_strategy,
)

RX = GPUWorkerConfig(adapter_id=1, name="Radeon RX 560X Series", backend="amf", is_discrete=True)
VEGA = GPUWorkerConfig(adapter_id=0, name="AMD Radeon(TM) Vega 8 Graphics", backend="amf", is_discrete=False)


class TenBitDetectionTests(unittest.TestCase):
    def test_ten_bit_formats(self):
        for pf in ("yuv420p10le", "p010le", "YUV420P10LE", "yuv422p10le"):
            with self.subTest(pix_fmt=pf):
                self.assertTrue(gpu_service._is_ten_bit(pf))

    def test_eight_bit_formats(self):
        for pf in ("yuv420p", "nv12", "yuv444p", "", None):
            with self.subTest(pix_fmt=pf):
                self.assertFalse(gpu_service._is_ten_bit(pf))


class StrategySelectionTests(unittest.TestCase):
    """select_amf_strategy -> (use_vpp_amf, worker_count)"""

    def test_ten_bit_requires_vpp(self):
        use_vpp, _ = select_amf_strategy({"height": 1040, "pix_fmt": "yuv420p10le"})
        self.assertTrue(use_vpp, "10-bit needs vpp_amf: h264_amf cannot encode it")

    def test_ten_bit_4k_requires_vpp(self):
        use_vpp, _ = select_amf_strategy({"height": 2160, "pix_fmt": "yuv420p10le"})
        self.assertTrue(use_vpp)

    def test_eight_bit_over_profile_height_requires_vpp(self):
        # 4K 8-bit still has to be downscaled to the 1080p profile.
        use_vpp, _ = select_amf_strategy({"height": 2160, "pix_fmt": "yuv420p"})
        self.assertTrue(use_vpp)

    def test_eight_bit_within_profile_skips_vpp(self):
        for h in (480, 720, 800, 804, 1040, HLS_MAX_HEIGHT):
            with self.subTest(height=h):
                use_vpp, _ = select_amf_strategy({"height": h, "pix_fmt": "yuv420p"})
                self.assertFalse(use_vpp, f"8-bit {h}p needs no resize and no depth change")

    def test_unprobed_source_fails_safe(self):
        """Missing data must never select the direct path."""
        for stream in (None, {}, {"pix_fmt": "yuv420p"}, {"height": 0, "pix_fmt": "yuv420p"},
                       {"height": None, "pix_fmt": None}, {"height": "abc", "pix_fmt": "yuv420p"}):
            with self.subTest(stream=stream):
                use_vpp, count = select_amf_strategy(stream)
                self.assertTrue(use_vpp, "unprobed source must keep the historical pipeline")
                self.assertGreaterEqual(count, 1)

    def test_worker_counts_are_per_class(self):
        _, main10 = select_amf_strategy({"height": 1040, "pix_fmt": "yuv420p10le"})
        _, eight_bit = select_amf_strategy({"height": 800, "pix_fmt": "yuv420p"})
        self.assertEqual(main10, 3)
        self.assertEqual(eight_bit, 2)

    def test_worker_counts_are_overridable(self):
        with patch.dict(os.environ, {"MEDIA_SERVER_TRANSCODE_WORKERS_MAIN10": "5",
                                      "MEDIA_SERVER_TRANSCODE_WORKERS_8BIT": "4"}):
            _, main10 = select_amf_strategy({"height": 1040, "pix_fmt": "yuv420p10le"})
            _, eight_bit = select_amf_strategy({"height": 800, "pix_fmt": "yuv420p"})
        self.assertEqual(main10, 5)
        self.assertEqual(eight_bit, 4)

    def test_worker_count_never_below_one(self):
        with patch.dict(os.environ, {"MEDIA_SERVER_TRANSCODE_WORKERS_8BIT": "0"}):
            _, count = select_amf_strategy({"height": 800, "pix_fmt": "yuv420p"})
        self.assertEqual(count, 1)


class FlagTests(unittest.TestCase):
    def test_defaults_to_legacy(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("MEDIA_SERVER_TRANSCODE_STRATEGY", None)
            self.assertFalse(adaptive_strategy_enabled())

    def test_adaptive_opt_in(self):
        with patch.dict(os.environ, {"MEDIA_SERVER_TRANSCODE_STRATEGY": "adaptive"}):
            self.assertTrue(adaptive_strategy_enabled())
        with patch.dict(os.environ, {"MEDIA_SERVER_TRANSCODE_STRATEGY": "legacy"}):
            self.assertFalse(adaptive_strategy_enabled())


class WorkerExpansionTests(unittest.TestCase):
    def test_names_are_unique(self):
        """The scheduler retires a GPU by name; duplicates must not collide."""
        for count in range(1, 9):
            with self.subTest(count=count):
                workers = expand_workers([RX, VEGA], count)
                self.assertEqual(len(workers), count)
                names = [w.name for w in workers]
                self.assertEqual(len(names), len(set(names)), f"duplicate names at count={count}: {names}")

    def test_discrete_gpu_takes_the_remainder(self):
        workers = expand_workers([RX, VEGA], 3)
        self.assertEqual([w.adapter_id for w in workers], [0, 1, 1])
        self.assertEqual(sum(1 for w in workers if w.is_discrete), 2)

    def test_single_worker_is_unchanged(self):
        workers = expand_workers([RX, VEGA], 1)
        self.assertEqual(len(workers), 1)
        self.assertFalse(workers[0].name.endswith("#2"))

    def test_worker_identity_preserved(self):
        for w in expand_workers([RX, VEGA], 4):
            with self.subTest(name=w.name):
                self.assertIn(w.name.split("#")[0], {RX.name, VEGA.name})
                self.assertEqual(w.backend, "amf")

    def test_empty_input_is_safe(self):
        self.assertEqual(expand_workers([], 4), [])

    def test_integrated_only_still_expands(self):
        workers = expand_workers([VEGA], 3)
        self.assertEqual(len(workers), 3)
        self.assertEqual(len({w.name for w in workers}), 3)


class VideoArgsTests(unittest.TestCase):
    def test_vpp_amf_present_by_default(self):
        args = RX.get_ffmpeg_video_args()
        self.assertIn("vpp_amf=h='min(1080,ih)':w=-2:format=nv12", args)
        self.assertIn("h264_amf", args)

    def test_direct_path_drops_vpp_amf(self):
        args = RX.get_ffmpeg_video_args(use_vpp_amf=False)
        joined = " ".join(args)
        self.assertNotIn("vpp_amf", joined)
        self.assertIn("h264_amf", args, "encoder must stay on the GPU")

    def test_cpu_backend_ignores_the_flag(self):
        cpu = GPUWorkerConfig(adapter_id=0, name="CPU Encoder", backend="cpu", is_discrete=False)
        self.assertIn("libx264", cpu.get_ffmpeg_video_args(use_vpp_amf=False))


class RealSourceSelectionTests(unittest.TestCase):
    """The classifier must agree with the actual library, using real probes."""

    CASES = [
        ("yuv420p10le", 2160, True, "4K HEVC Main10"),
        ("yuv420p10le", 1040, True, "1080p HEVC Main10 letterbox"),
        ("yuv420p", 804, False, "1080p HEVC Main 8bit"),
        ("yuv420p", 800, False, "1080p H.264 8bit"),
        ("yuv420p", 2160, True, "4K 8-bit still needs the downscale"),
    ]

    def test_matrix(self):
        for pix_fmt, height, expect_vpp, label in self.CASES:
            with self.subTest(label=label):
                use_vpp, _ = select_amf_strategy({"pix_fmt": pix_fmt, "height": height})
                self.assertEqual(use_vpp, expect_vpp)


if __name__ == "__main__":
    unittest.main()
