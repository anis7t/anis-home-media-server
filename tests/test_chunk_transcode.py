"""Tests for multi-GPU chunked transcoding and GPU discovery services."""
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from app.services.gpu_service import (
    GPUWorkerConfig,
    detect_available_gpus,
    get_gpu_workers,
    is_dual_gpu_enabled,
)
from app.services.chunk_transcode_service import (
    DualGPUTranscodeJob,
    plan_chunks,
    start_dual_gpu_transcode,
)


class TestChunkPlanner(unittest.TestCase):
    def test_plan_chunks_empty_or_zero_duration(self):
        self.assertEqual(plan_chunks(0.0), [])
        self.assertEqual(plan_chunks(-10.0), [])

    def test_plan_chunks_short_duration(self):
        chunks = plan_chunks(30.0, chunk_duration=60.0)
        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0]['chunk_id'], 0)
        self.assertEqual(chunks[0]['start_time'], 0.0)
        self.assertEqual(chunks[0]['duration'], 30.0)
        self.assertEqual(chunks[0]['start_seg'], 0)
        self.assertEqual(chunks[0]['expected_segs'], 8)  # 30 / 4 = 7.5 -> 8

    def test_plan_chunks_multi_chunk(self):
        chunks = plan_chunks(150.0, chunk_duration=60.0)
        self.assertEqual(len(chunks), 3)

        # Chunk 0: 0s to 60s
        self.assertEqual(chunks[0]['chunk_id'], 0)
        self.assertEqual(chunks[0]['start_time'], 0.0)
        self.assertEqual(chunks[0]['duration'], 60.0)
        self.assertEqual(chunks[0]['start_seg'], 0)
        self.assertEqual(chunks[0]['expected_segs'], 15)

        # Chunk 1: 60s to 120s
        self.assertEqual(chunks[1]['chunk_id'], 1)
        self.assertEqual(chunks[1]['start_time'], 60.0)
        self.assertEqual(chunks[1]['duration'], 60.0)
        self.assertEqual(chunks[1]['start_seg'], 15)
        self.assertEqual(chunks[1]['expected_segs'], 15)

        # Chunk 2: 120s to 150s
        self.assertEqual(chunks[2]['chunk_id'], 2)
        self.assertEqual(chunks[2]['start_time'], 120.0)
        self.assertEqual(chunks[2]['duration'], 30.0)
        self.assertEqual(chunks[2]['start_seg'], 30)
        self.assertEqual(chunks[2]['expected_segs'], 8)


class TestGpuService(unittest.TestCase):
    def test_gpu_worker_config_args_amf(self):
        cfg = GPUWorkerConfig(adapter_id=1, name="Radeon RX 560X", backend="amf", is_discrete=True)
        init_args = cfg.get_ffmpeg_init_args()
        self.assertIn("d3d11va=dx11:1", init_args)
        self.assertIn("amf=amf@dx11", init_args)

        video_args = cfg.get_ffmpeg_video_args()
        self.assertIn("h264_amf", video_args)
        self.assertIn("-quality", video_args)
        self.assertIn("speed", video_args)

    def test_gpu_worker_config_args_cpu(self):
        cfg = GPUWorkerConfig(adapter_id=0, name="CPU", backend="cpu", is_discrete=False)
        self.assertEqual(cfg.get_ffmpeg_init_args(), [])
        video_args = cfg.get_ffmpeg_video_args()
        self.assertIn("libx264", video_args)

    @patch("app.services.gpu_service._probe_d3d11_adapter")
    def test_detect_available_gpus_sorting_discrete_first(self, mock_probe):
        def probe_side_effect(idx):
            if idx == 0:
                return GPUWorkerConfig(adapter_id=0, name="AMD Radeon Vega 8", backend="amf", is_discrete=False)
            elif idx == 1:
                return GPUWorkerConfig(adapter_id=1, name="Radeon RX 560X Series", backend="amf", is_discrete=True)
            return None

        mock_probe.side_effect = probe_side_effect
        with patch("os.name", "nt"):
            gpus = detect_available_gpus(force_refresh=True)

        self.assertEqual(len(gpus), 2)
        # Discrete RX 560X must be first
        self.assertTrue(gpus[0].is_discrete)
        self.assertEqual(gpus[0].adapter_id, 1)
        self.assertFalse(gpus[1].is_discrete)
        self.assertEqual(gpus[1].adapter_id, 0)

    @patch("app.services.gpu_service.detect_available_gpus")
    def test_is_dual_gpu_enabled(self, mock_detect):
        gpu1 = GPUWorkerConfig(1, "RX 560X", "amf", True)
        gpu2 = GPUWorkerConfig(0, "Vega 8", "amf", False)

        mock_detect.return_value = [gpu1, gpu2]
        with patch.dict(os.environ, {"MEDIA_SERVER_ENABLE_DUAL_GPU": "1"}):
            self.assertTrue(is_dual_gpu_enabled())

        with patch.dict(os.environ, {"MEDIA_SERVER_ENABLE_DUAL_GPU": "0"}):
            self.assertFalse(is_dual_gpu_enabled())

        mock_detect.return_value = [gpu1]
        with patch.dict(os.environ, {"MEDIA_SERVER_ENABLE_DUAL_GPU": "1"}):
            self.assertFalse(is_dual_gpu_enabled())

    @patch("app.services.gpu_service.detect_available_gpus", return_value=[])
    def test_get_gpu_workers_fallback_cpu(self, mock_detect):
        workers = get_gpu_workers()
        self.assertEqual(len(workers), 1)
        self.assertEqual(workers[0].backend, "cpu")


class TestDualGPUTranscodeJob(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.root = Path(self.tmp.name)
        self.hls_dir = self.root / "hls"
        self.hls_dir.mkdir(parents=True, exist_ok=True)
        self.playlist = self.hls_dir / "playlist.m3u8"
        self.media_path = self.root / "test.mkv"
        self.media_path.write_bytes(b"dummy media content")

    def tearDown(self):
        self.tmp.cleanup()

    def test_job_initialization_and_poll(self):
        job = DualGPUTranscodeJob("test.mkv", self.media_path, self.hls_dir, self.playlist)
        self.assertEqual(job.poll(), None)
        self.assertEqual(job.pid, 0)

        job.kill()
        self.assertEqual(job.poll(), -1)
        self.assertTrue(job._cancelled.is_set())

    def test_update_master_playlist_incremental(self):
        job = DualGPUTranscodeJob("test.mkv", self.media_path, self.hls_dir, self.playlist)

        # Create two dummy segments
        seg0 = self.hls_dir / "segment_000000.ts"
        seg1 = self.hls_dir / "segment_000001.ts"
        seg0.write_bytes(b"TS_DATA_0")
        seg1.write_bytes(b"TS_DATA_1")

        # Update while active (not complete)
        job._update_master_playlist(is_complete=False)
        self.assertTrue(self.playlist.is_file())
        text = self.playlist.read_text()
        self.assertIn("#EXTM3U", text)
        self.assertIn("segment_000000.ts", text)
        self.assertIn("segment_000001.ts", text)
        self.assertNotIn("#EXT-X-ENDLIST", text)

        # Verify progress file was written
        progress_file = self.hls_dir / "hls.progress"
        self.assertTrue(progress_file.is_file())
        prog_text = progress_file.read_text()
        self.assertIn("progress=continue", prog_text)

        # Update when complete
        job._update_master_playlist(is_complete=True)
        text_complete = self.playlist.read_text()
        self.assertIn("#EXT-X-ENDLIST", text_complete)
        prog_complete = progress_file.read_text()
        self.assertIn("progress=end", prog_complete)

    @patch("app.services.chunk_transcode_service.probe_media")
    def test_run_pipeline_all_cached(self, mock_probe):
        mock_probe.return_value = {"format": {"duration": "120.0"}}
        # Pre-create all expected segments for 120s (30 segments)
        for i in range(30):
            (self.hls_dir / f"segment_{i:06d}.ts").write_bytes(b"MOCK_TS")

        job = DualGPUTranscodeJob("test.mkv", self.media_path, self.hls_dir, self.playlist)
        job._run_pipeline()

        self.assertEqual(job.poll(), 0)
        self.assertTrue(self.playlist.is_file())
        text = self.playlist.read_text()
        self.assertIn("#EXT-X-ENDLIST", text)
        self.assertIn("segment_000029.ts", text)

    def test_execute_chunk_cancelled_returns_false(self):
        job = DualGPUTranscodeJob("test.mkv", self.media_path, self.hls_dir, self.playlist)
        job._cancelled.set()
        worker = GPUWorkerConfig(1, "Discrete", "amf", True)
        chunk = {'chunk_id': 0, 'start_time': 0.0, 'duration': 60.0, 'start_seg': 0, 'expected_segs': 15}
        success = job._execute_chunk(chunk, worker)
        self.assertFalse(success)


if __name__ == '__main__':
    unittest.main()
