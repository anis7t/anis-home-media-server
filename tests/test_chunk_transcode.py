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
import app.services.chunk_transcode_service as chunk_mod
from app.services.chunk_transcode_service import (
    DualGPUTranscodeJob,
    plan_chunks,
    reconcile_hls_playlist_discontinuities,
    start_dual_gpu_transcode,
)
from app.services.transcode_service import clear_video_duration_cache, source_video_duration




def write_segments(hls_dir, indexes):
    """Write the fixture segments and mark the layout.

    An unmarked cache that already holds segments is treated as a legacy dense cache and cleared
    for re-render, so fixtures must declare the strided layout they are built with.
    """
    hls_dir.mkdir(parents=True, exist_ok=True)
    (hls_dir / ".seg_layout").write_text("stride32", encoding="utf-8")
    for i in indexes:
        (hls_dir / f"segment_{i:06d}.ts").write_bytes(b"MOCK_TS")


def strided_segments(duration=120.0, chunk_ids=(0, 1), per_chunk=None):
    """Segment indices for the given chunks under the strided (collision-proof) layout.

    Indices are chunk_id * SEGMENTS_PER_CHUNK_STRIDE, never dense: a chunk whose render emits one
    segment more than planned used to land on the next chunk's first index and destroy ~1.25s of
    video at every chunk boundary.
    """
    plan = {c['chunk_id']: c for c in chunk_mod.plan_chunks(duration)}
    indices = []
    for cid in chunk_ids:
        c = plan[cid]
        count = c['expected_segs'] if per_chunk is None else per_chunk
        indices.extend(range(c['start_seg'], c['start_seg'] + count))
    return indices

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
        self.assertEqual(chunks[1]['start_seg'], chunk_mod.SEGMENTS_PER_CHUNK_STRIDE)
        self.assertEqual(chunks[1]['expected_segs'], 15)

        # Chunk 2: 120s to 150s
        self.assertEqual(chunks[2]['chunk_id'], 2)
        self.assertEqual(chunks[2]['start_time'], 120.0)
        self.assertEqual(chunks[2]['duration'], 30.0)
        self.assertEqual(chunks[2]['start_seg'], 2 * chunk_mod.SEGMENTS_PER_CHUNK_STRIDE)
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
        self.assertIn("#EXT-X-PLAYLIST-TYPE:EVENT", text)
        self.assertIn("#EXT-X-START:TIME-OFFSET=0", text)
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

    def test_parse_chunk_segment_durations(self):
        job = DualGPUTranscodeJob("test.mkv", self.media_path, self.hls_dir, self.playlist)
        chunk_m3u8 = self.hls_dir / "chunk_0.m3u8"
        chunk_m3u8.write_text(
            "#EXTM3U\n"
            "#EXT-X-VERSION:3\n"
            "#EXT-X-TARGETDURATION:5\n"
            "#EXTINF:3.842000,\n"
            "segment_000000.ts\n"
            "#EXTINF:4.120000,\n"
            "segment_000001.ts\n"
            "#EXT-X-ENDLIST\n"
        )
        durations = job._parse_chunk_segment_durations(0)
        self.assertIn("segment_000000.ts", durations)
        self.assertEqual(durations["segment_000000.ts"], 3.842)
        self.assertEqual(durations["segment_000001.ts"], 4.120)

    def test_job_active_pids_and_terminate(self):
        job = DualGPUTranscodeJob("test.mkv", self.media_path, self.hls_dir, self.playlist)
        mock_proc1 = MagicMock()
        mock_proc1.pid = 9911
        mock_proc1.poll.return_value = None
        mock_proc2 = MagicMock()
        mock_proc2.pid = 9922
        mock_proc2.poll.return_value = 0

        job._active_procs.add(mock_proc1)
        job._active_procs.add(mock_proc2)

        pids = job.get_active_pids()
        self.assertEqual(pids, [9911])

        job.terminate()
        self.assertTrue(job._cancelled.is_set())
        mock_proc1.terminate.assert_called_once()
        self.assertEqual(job.poll(), -1)

    @patch("app.services.chunk_transcode_service.probe_media")
    @patch("app.services.transcode_service.chunk_content_deficits", return_value=[])
    def test_run_pipeline_all_cached(self, _mock_deficits, mock_probe):
        mock_probe.return_value = {"format": {"duration": "120.0"}}
        # Pre-create all expected segments for 120s (both chunks, strided indices)
        indices = strided_segments(120.0)
        write_segments(self.hls_dir, indices)

        job = DualGPUTranscodeJob("test.mkv", self.media_path, self.hls_dir, self.playlist)
        job._run_pipeline()

        self.assertEqual(job.poll(), 0)
        self.assertTrue(self.playlist.is_file())
        text = self.playlist.read_text()
        self.assertIn("#EXT-X-ENDLIST", text)
        self.assertIn(f"segment_{max(indices):06d}.ts", text)

    def test_execute_chunk_cancelled_returns_false(self):
        job = DualGPUTranscodeJob("test.mkv", self.media_path, self.hls_dir, self.playlist)
        job._cancelled.set()
        worker = GPUWorkerConfig(1, "Discrete", "amf", True)
        chunk = {'chunk_id': 0, 'start_time': 0.0, 'duration': 60.0, 'start_seg': 0, 'expected_segs': 15}
        success = job._execute_chunk(chunk, worker)
        self.assertFalse(success)

    def test_update_master_playlist_discontinuity(self):
        job = DualGPUTranscodeJob("test.mkv", self.media_path, self.hls_dir, self.playlist)
        job.total_duration = 120.0  # 2 chunks, strided indices

        # Create segments across the chunk boundary
        plan = chunk_mod.plan_chunks(120.0)
        second_start = plan[1]['start_seg']
        first_name = f"segment_{second_start:06d}.ts"
        write_segments(self.hls_dir, strided_segments(120.0, chunk_ids=(0,))
                             + [second_start, second_start + 1])

        job._update_master_playlist(is_complete=False)
        text = self.playlist.read_text(encoding="utf-8")
        self.assertIn("#EXT-X-DISCONTINUITY", text)
        lines = text.splitlines()
        disc_idx = lines.index("#EXT-X-DISCONTINUITY")
        # Ensure #EXT-X-DISCONTINUITY comes right before #EXTINF for segment_000015.ts
        self.assertTrue(lines[disc_idx + 1].startswith("#EXTINF:"))
        self.assertEqual(lines[disc_idx + 2], first_name)

    def test_reconcile_hls_playlist_discontinuities(self):
        # Create a playlist without discontinuities
        text_without = (
            "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n"
            "#EXTINF:4.000000,\nsegment_000014.ts\n"
            "#EXTINF:4.000000,\nsegment_000015.ts\n"
            "#EXT-X-ENDLIST\n"
        )
        self.playlist.write_text(text_without, encoding="utf-8")

        # Create chunk_1.m3u8 indicating chunk 1 begins at segment_000015.ts
        chunk1 = self.hls_dir / "chunk_1.m3u8"
        chunk1.write_text("#EXTM3U\n#EXTINF:4.0,\nsegment_000015.ts\n", encoding="utf-8")

        # Run reconciliation
        repaired = reconcile_hls_playlist_discontinuities(self.hls_dir)
        self.assertTrue(repaired)

        repaired_text = self.playlist.read_text(encoding="utf-8")
        self.assertIn("#EXT-X-DISCONTINUITY", repaired_text)
        lines = repaired_text.splitlines()
        disc_idx = lines.index("#EXT-X-DISCONTINUITY")
        self.assertTrue(lines[disc_idx + 1].startswith("#EXTINF:"))
        self.assertEqual(lines[disc_idx + 2], "segment_000015.ts")

        # Second run should be a no-op
        self.assertFalse(reconcile_hls_playlist_discontinuities(self.hls_dir))


if __name__ == '__main__':
    unittest.main()

class TestVideoDurationAndValidation(unittest.TestCase):
    """Regression coverage for the "complete transcode reported as 83.9% incomplete" bug.

    A WEBRip may carry audio/subtitle packets far past the last video frame (video 8254.6s inside
    a 9839.1s container). Planning and validation must use the *video* end, and a job that fails
    validation must never write #EXT-X-ENDLIST, because that marker is what the rest of the app
    reads as "this cache is finished".
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.root = Path(self.tmp.name)
        self.hls_dir = self.root / "hls"
        self.hls_dir.mkdir(parents=True, exist_ok=True)
        self.playlist = self.hls_dir / "playlist.m3u8"
        self.media_path = self.root / "test.mkv"
        self.media_path.write_bytes(b"dummy media content")
        clear_video_duration_cache()
        chunk_mod._VALIDATION_FAILURES.clear()

    def tearDown(self):
        chunk_mod._VALIDATION_FAILURES.clear()
        clear_video_duration_cache()
        self.tmp.cleanup()

    def _packets(self, stdout):
        fake = MagicMock()
        fake.stdout = stdout
        return fake

    def test_source_video_duration_uses_video_stream_end(self):
        stdout = "8254.396000,0.041000\n8254.479000,0.041000\n8254.563000,0.041000\n"
        with patch("app.services.transcode_service._ffprobe_bin", return_value="ffprobe"), \
             patch("app.services.transcode_service.subprocess.run", return_value=self._packets(stdout)) as run:
            measured = source_video_duration(self.media_path, fallback=9839.072)

        self.assertAlmostEqual(measured, 8254.604, places=3)
        cmd = run.call_args[0][0]
        self.assertIn("-select_streams", cmd)
        self.assertIn("v:0", cmd)
        # Fast path: seek to the container midpoint instead of scanning every video packet.
        self.assertIn("-read_intervals", cmd)
        self.assertIn("4919.536%+99999", cmd)

    def test_source_video_duration_result_is_cached(self):
        stdout = "8254.563000,0.041000\n"
        with patch("app.services.transcode_service._ffprobe_bin", return_value="ffprobe"), \
             patch("app.services.transcode_service.subprocess.run", return_value=self._packets(stdout)):
            source_video_duration(self.media_path, fallback=9839.072)

        with patch("app.services.transcode_service._ffprobe_bin", return_value="ffprobe"), \
             patch("app.services.transcode_service.subprocess.run", return_value=self._packets(stdout)) as run:
            again = source_video_duration(self.media_path, fallback=9839.072)

        self.assertEqual(run.call_count, 0)
        self.assertAlmostEqual(again, 8254.604, places=3)

    def test_source_video_duration_falls_back_without_ffprobe(self):
        with patch("app.services.transcode_service._ffprobe_bin", return_value=None):
            measured = source_video_duration(self.media_path, fallback=9839.072)
        self.assertEqual(measured, 9839.072)

    def test_source_video_duration_falls_back_when_probe_returns_nothing(self):
        with patch("app.services.transcode_service._ffprobe_bin", return_value="ffprobe"), \
             patch("app.services.transcode_service.subprocess.run", return_value=self._packets("")):
            measured = source_video_duration(self.media_path, fallback=9839.072)
        self.assertEqual(measured, 9839.072)

    def test_chunk_output_ok_rejects_zero_duration_chunk(self):
        job = DualGPUTranscodeJob("test.mkv", self.media_path, self.hls_dir, self.playlist)
        chunk = {"chunk_id": 138, "start_time": 8280.0, "duration": 60.0, "start_seg": 2070, "expected_segs": 15}

        # Exactly what a misbehaving AMF adapter produces: one zero-length segment, exit code 0.
        (self.hls_dir / "chunk_138.m3u8").write_text(
            "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:0\n"
            "#EXTINF:0.000000,\nsegment_002070.ts\n#EXT-X-ENDLIST\n",
            encoding="utf-8",
        )
        self.assertFalse(job._chunk_output_ok(chunk))

        healthy = "#EXTM3U\n#EXT-X-VERSION:3\n" + "".join(
            f"#EXTINF:4.000000,\nsegment_{2070 + i:06d}.ts\n" for i in range(15)
        )
        (self.hls_dir / "chunk_138.m3u8").write_text(healthy, encoding="utf-8")
        self.assertTrue(job._chunk_output_ok(chunk))

    def test_missing_chunk_playlist_is_not_usable_output(self):
        job = DualGPUTranscodeJob("test.mkv", self.media_path, self.hls_dir, self.playlist)
        chunk = {"chunk_id": 7, "start_time": 420.0, "duration": 60.0, "start_seg": 105, "expected_segs": 15}
        self.assertFalse(job._chunk_output_ok(chunk))

    def test_unhealthy_workers_are_excluded_from_retry(self):
        job = DualGPUTranscodeJob("test.mkv", self.media_path, self.hls_dir, self.playlist)
        worker_a = GPUWorkerConfig(1, "Discrete", "amf", True)
        worker_b = GPUWorkerConfig(0, "Integrated", "amf", False)
        job.workers = [worker_a, worker_b]

        self.assertEqual(job._next_healthy_worker().name, "Discrete")
        job._mark_worker_unhealthy(worker_a)
        self.assertEqual(job._next_healthy_worker().name, "Integrated")
        self.assertIsNone(job._next_healthy_worker(exclude=worker_b))
        job._mark_worker_unhealthy(worker_b)
        self.assertIsNone(job._next_healthy_worker())

    def _write_segments(self, indexes):
        write_segments(self.hls_dir, indexes)

    @patch("app.services.chunk_transcode_service.probe_media")
    @patch("app.services.transcode_service.source_video_duration", return_value=120.0)
    def test_pipeline_does_not_write_endlist_on_short_coverage(self, _mock_video, mock_probe):
        mock_probe.return_value = {"format": {"duration": "120.0"}}
        # Both chunks look "cached" to pending detection, but only chunk 0 has all of its
        # segments, so coverage is 50%.
        write_segments(self.hls_dir, strided_segments(120.0, chunk_ids=(0,)))
        write_segments(self.hls_dir, strided_segments(120.0, chunk_ids=(1,), per_chunk=1))

        job = DualGPUTranscodeJob("test.mkv", self.media_path, self.hls_dir, self.playlist)
        job._run_pipeline()

        self.assertEqual(job.poll(), 1)
        text = self.playlist.read_text(encoding="utf-8")
        self.assertNotIn("#EXT-X-ENDLIST", text)
        self.assertIn("#EXT-X-PLAYLIST-TYPE:EVENT", text)
        self.assertIn("progress=error", (self.hls_dir / "hls.progress").read_text(encoding="utf-8"))

    @patch("app.services.chunk_transcode_service.probe_media")
    @patch("app.services.transcode_service.source_video_duration", return_value=120.0)
    def test_repeated_validation_failures_settle_with_error(self, _mock_video, mock_probe):
        mock_probe.return_value = {"format": {"duration": "120.0"}}
        write_segments(self.hls_dir, range(15))
        write_segments(self.hls_dir, [15, 29])

        for _ in range(chunk_mod.MAX_VALIDATION_ATTEMPTS):
            job = DualGPUTranscodeJob("test.mkv", self.media_path, self.hls_dir, self.playlist)
            job._run_pipeline()

        # Bounded retries: the failure stays visible in the progress file, but an under-covered
        # cache must NOT be marked complete - ENDLIST is authoritative, so writing it here would
        # permanently hide the missing seconds and block every later repair.
        self.assertNotIn("#EXT-X-ENDLIST", self.playlist.read_text(encoding="utf-8"))
        progress = (self.hls_dir / "hls.progress").read_text(encoding="utf-8")
        self.assertIn("progress=error", progress)
        self.assertIn(f"attempt {chunk_mod.MAX_VALIDATION_ATTEMPTS}/{chunk_mod.MAX_VALIDATION_ATTEMPTS}", progress)
        # ...and the next attempt is told to re-render the tail instead of trusting the cache
        self.assertTrue(chunk_mod._FORCE_TAIL_RERENDER.get(str(self.hls_dir)))
        chunk_mod._FORCE_TAIL_RERENDER.pop(str(self.hls_dir), None)
        chunk_mod._VALIDATION_FAILURES.pop(str(self.hls_dir), None)
        chunk_mod._TAIL_REPAIR_ATTEMPTS.pop(str(self.hls_dir), None)

    # Content verification has its own tests (test_hls_worker_guards.py): these fixtures are
    # synthetic non-media files, so frame accounting must be neutralised here.
    @patch("app.services.transcode_service.chunk_content_deficits", return_value=[])
    @patch("app.services.chunk_transcode_service.probe_media")
    @patch("app.services.transcode_service.source_video_duration", return_value=120.0)
    def test_full_coverage_still_writes_endlist(self, _mock_video, mock_probe, _mock_deficits):
        mock_probe.return_value = {"format": {"duration": "120.0"}}
        write_segments(self.hls_dir, strided_segments(120.0))

        job = DualGPUTranscodeJob("test.mkv", self.media_path, self.hls_dir, self.playlist)
        job._run_pipeline()

        self.assertEqual(job.poll(), 0)
        self.assertIn("#EXT-X-ENDLIST", self.playlist.read_text(encoding="utf-8"))
        self.assertNotIn("progress=error", (self.hls_dir / "hls.progress").read_text(encoding="utf-8"))

