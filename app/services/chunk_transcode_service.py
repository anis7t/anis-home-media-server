"""Dynamic Multi-GPU Chunked Transcoding Service.

Distributes movie HLS transcoding across multiple GPUs (e.g. Discrete RX 560X + Integrated Vega 8)
by assigning keyframe-aware sequential chunks concurrently and continuously assembling the master HLS playlist.
"""
import logging
import math
import os
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Dict, List, Optional, Set

from app import config
from app.services.gpu_service import GPUWorkerConfig, get_gpu_workers, is_dual_gpu_enabled
from app.services.media_service import probe_media

logger = logging.getLogger(__name__)

DEFAULT_CHUNK_DURATION = 60.0  # seconds per transcode chunk
SEGMENT_TARGET_DURATION = 4.0   # seconds per HLS segment


def plan_chunks(total_duration: float, chunk_duration: float = DEFAULT_CHUNK_DURATION) -> List[Dict]:
    """Divide media duration into contiguous chunk specifications."""
    if total_duration <= 0:
        return []

    chunks = []
    chunk_id = 0
    current_time = 0.0

    while current_time < total_duration:
        dur = min(chunk_duration, total_duration - current_time)
        start_seg = int(round(current_time / SEGMENT_TARGET_DURATION))
        expected_segs = max(1, int(round(dur / SEGMENT_TARGET_DURATION)))
        chunks.append({
            'chunk_id': chunk_id,
            'start_time': current_time,
            'duration': dur,
            'start_seg': start_seg,
            'expected_segs': expected_segs,
        })
        chunk_id += 1
        current_time += dur

    return chunks


class DualGPUTranscodeJob:
    """Coordinates parallel multi-GPU transcoding and emulates a subprocess ProcessProxy."""

    def __init__(self, filename: str, path: Path, hls_dir: Path, playlist: Path):
        self.filename = filename
        self.path = Path(path)
        self.hls_dir = Path(hls_dir)
        self.playlist = Path(playlist)
        self.progress_file = self.hls_dir / 'hls.progress'
        self.workers = get_gpu_workers()

        self._cancelled = threading.Event()
        self._finished = threading.Event()
        self._returncode: Optional[int] = None
        self._active_procs: Set[subprocess.Popen] = set()
        self._proc_lock = threading.Lock()
        self._thread: Optional[threading.Thread] = None

        self.total_duration = 0.0
        self.encoded_duration = 0.0
        self._start_wall_time = time.time()
        self._initial_cached_sec = 0.0

    @property
    def pid(self) -> int:
        """Return PID of an active chunk FFmpeg process, or 0 if none active."""
        with self._proc_lock:
            for p in self._active_procs:
                if getattr(p, "pid", None):
                    return p.pid
        return 0

    def poll(self) -> Optional[int]:
        """ProcessProxy emulation: returns None if still running, returncode if done."""
        if self._finished.is_set():
            return self._returncode or 0
        return None

    def wait(self, timeout: Optional[float] = None) -> Optional[int]:
        """Block until the job finishes or timeout occurs."""
        self._finished.wait(timeout=timeout)
        return self._returncode

    def kill(self):
        """Terminate all active FFmpeg chunk workers immediately."""
        self._cancelled.set()
        with self._proc_lock:
            for proc in list(self._active_procs):
                try:
                    proc.kill()
                except Exception:
                    pass
            self._active_procs.clear()
        self._returncode = -1
        self._finished.set()

    def start(self):
        """Launch the dual-GPU transcoding pipeline in a background coordinator thread."""
        self._thread = threading.Thread(
            target=self._run_pipeline,
            name=f"dual-gpu-transcode-{self.filename}",
            daemon=True,
        )
        self._thread.start()

    def _execute_chunk(self, chunk: Dict, worker: GPUWorkerConfig) -> bool:
        """Run FFmpeg to transcode a single chunk using the assigned GPU worker."""
        if self._cancelled.is_set():
            return False

        chunk_id = chunk['chunk_id']
        start_time = chunk['start_time']
        duration = chunk['duration']
        start_seg = chunk['start_seg']

        ffmpeg = shutil.which("ffmpeg") or "ffmpeg"
        init_args = worker.get_ffmpeg_init_args()
        video_args = worker.get_ffmpeg_video_args()

        # Probe media audio codec to select copy vs aac encode
        streams = probe_media(self.path).get('streams', [])
        audio = next((s for s in streams if s.get('codec_type') == 'audio'), {})
        audio_args = (
            ['-c:a', 'copy']
            if (audio.get('codec_name') == 'aac' and audio.get('channels', 2) <= 2)
            else ['-c:a', 'aac', '-ac', '2', '-b:a', '192k', '-af', 'aresample=async=1:first_pts=0']
        )

        chunk_pl = self.hls_dir / f"chunk_{chunk_id}.m3u8"
        cmd = (
            [ffmpeg, '-y', '-hide_banner', '-loglevel', 'error']
            + init_args
            + ['-ss', f"{start_time:.3f}"]
            + ['-i', str(self.path)]
            + ['-t', f"{duration:.3f}"]
            + ['-map', '0:v:0', '-map', '0:a:0?']
            + video_args
            + audio_args
            + [
                '-avoid_negative_ts', 'make_zero',
                '-muxdelay', '0',
                '-force_key_frames', 'expr:gte(t,n_forced*4)',
                '-f', 'hls',
                '-hls_time', str(SEGMENT_TARGET_DURATION),
                '-hls_list_size', '0',
                '-hls_flags', 'independent_segments',
                '-start_number', str(start_seg),
                '-hls_segment_filename', str(self.hls_dir / 'segment_%06d.ts'),
                '-nostats', str(chunk_pl)
            ]
        )

        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
            with self._proc_lock:
                if self._cancelled.is_set():
                    proc.kill()
                    return False
                self._active_procs.add(proc)

            stdout, stderr = proc.communicate()

            with self._proc_lock:
                self._active_procs.discard(proc)

            if proc.returncode != 0 and not self._cancelled.is_set():
                err_lines = [l.strip() for l in (stderr or '').splitlines() if l.strip()]
                last_err = err_lines[-1] if err_lines else f"exit code {proc.returncode}"
                logger.warning(f"Chunk {chunk_id} FFmpeg error on {worker.name}: {last_err}")
                return False

            return proc.returncode == 0
        except Exception as e:
            logger.error(f"Error executing chunk {chunk_id} on worker {worker.name}: {e}")
            return False

    def _update_master_playlist(self, is_complete: bool = False):
        """Reconstruct master playlist.m3u8 from contiguous segment files on disk."""
        disk_segs = []
        idx = 0
        while True:
            seg = self.hls_dir / f"segment_{idx:06d}.ts"
            if not seg.is_file() or seg.stat().st_size == 0:
                break
            disk_segs.append(seg)
            idx += 1

        if not disk_segs:
            return

        lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            f"#EXT-X-TARGETDURATION:{int(SEGMENT_TARGET_DURATION)}",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]

        total_sec = 0.0
        for seg in disk_segs:
            dur = SEGMENT_TARGET_DURATION
            lines.append(f"#EXTINF:{dur:.6f},")
            lines.append(seg.name)
            total_sec += dur

        if is_complete:
            lines.append("#EXT-X-ENDLIST")

        text = "\n".join(lines) + "\n"
        self.playlist.write_text(text)
        try:
            (self.hls_dir / "playlist.m3u8.bak").write_text(text)
        except OSError:
            pass

        self.encoded_duration = total_sec
        elapsed = max(0.5, time.time() - self._start_wall_time)
        newly_encoded = max(0.0, total_sec - self._initial_cached_sec)
        speed = round(newly_encoded / elapsed, 2) if (newly_encoded > 0 and elapsed > 0.5) else 0.0

        # Write progress report for UI telemetry
        try:
            self.progress_file.write_text(
                f"out_time_us={int(total_sec * 1_000_000)}\n"
                f"out_time_ms={int(total_sec * 1_000_000)}\n"
                f"speed={speed:.2f}x\n"
                f"progress={'end' if is_complete else 'continue'}\n"
            )
        except OSError:
            pass

    def _run_pipeline(self):
        """Main coordinator thread executing chunks in prioritized parallel order."""
        try:
            info = probe_media(self.path)
            self.total_duration = float(info.get('format', {}).get('duration') or 0.0)
            if self.total_duration <= 0:
                # Probe failed or zero length
                self._returncode = 1
                self._finished.set()
                return

            all_chunks = plan_chunks(self.total_duration)
            if not all_chunks:
                self._returncode = 0
                self._finished.set()
                return

            self.hls_dir.mkdir(parents=True, exist_ok=True)

            # Check existing completed segments for resume
            pending_chunks = []
            for c in all_chunks:
                first_seg = self.hls_dir / f"segment_{c['start_seg']:06d}.ts"
                last_seg = self.hls_dir / f"segment_{c['start_seg'] + c['expected_segs'] - 1:06d}.ts"
                if first_seg.is_file() and first_seg.stat().st_size > 0 and last_seg.is_file() and last_seg.stat().st_size > 0:
                    continue  # Chunk already fully rendered
                pending_chunks.append(c)

            if not pending_chunks:
                logger.info(f"All {len(all_chunks)} chunks for {self.filename} already cached.")
                self._update_master_playlist(is_complete=True)
                self._returncode = 0
                self._finished.set()
                return

            init_segs = 0
            while (self.hls_dir / f"segment_{init_segs:06d}.ts").is_file():
                init_segs += 1
            self._initial_cached_sec = init_segs * SEGMENT_TARGET_DURATION
            self._start_wall_time = time.time()

            logger.info(f"Starting Multi-GPU Transcoding for {self.filename} ({len(pending_chunks)} chunks remaining)")

            # Multi-GPU worker assignment:
            # Worker 0 (Discrete RX 560X) gets chunk 0 for fastest immediate playback start
            worker_discrete = self.workers[0]
            worker_integrated = self.workers[1] if len(self.workers) > 1 else self.workers[0]

            chunk_lock = threading.Lock()
            queue = list(pending_chunks)

            def worker_loop(assigned_worker: GPUWorkerConfig):
                while not self._cancelled.is_set():
                    current_chunk = None
                    with chunk_lock:
                        if queue:
                            current_chunk = queue.pop(0)
                    if not current_chunk:
                        break

                    success = self._execute_chunk(current_chunk, assigned_worker)
                    if not success and not self._cancelled.is_set():
                        # Retry on discrete worker if integrated worker failed
                        if assigned_worker != worker_discrete:
                            logger.warning(f"Chunk {current_chunk['chunk_id']} failed on {assigned_worker.name}; retrying on {worker_discrete.name}")
                            self._execute_chunk(current_chunk, worker_discrete)

                    self._update_master_playlist(is_complete=False)

            threads = [
                threading.Thread(target=worker_loop, args=(worker_discrete,), name=f"gpu-worker-discrete-{self.filename}"),
                threading.Thread(target=worker_loop, args=(worker_integrated,), name=f"gpu-worker-integrated-{self.filename}"),
            ]

            def progress_updater_loop():
                while not self._cancelled.is_set() and any(t.is_alive() for t in threads):
                    time.sleep(1.0)
                    self._update_master_playlist(is_complete=False)

            updater_thread = threading.Thread(
                target=progress_updater_loop,
                name=f"gpu-progress-updater-{self.filename}",
                daemon=True,
            )

            for t in threads:
                t.start()
            updater_thread.start()

            for t in threads:
                t.join()

            updater_thread.join(timeout=2.0)

            if not self._cancelled.is_set():
                self._update_master_playlist(is_complete=True)
                self._returncode = 0
                logger.info(f"Dual-GPU Transcoding for {self.filename} completed successfully!")
            else:
                self._returncode = -1
        except Exception as e:
            logger.error(f"Multi-GPU pipeline error for {self.filename}: {e}", exc_info=True)
            self._returncode = 1
        finally:
            self._finished.set()


def start_dual_gpu_transcode(filename: str, path: Path, hls_dir: Path, playlist: Path) -> DualGPUTranscodeJob:
    """Create, register, and start a dual-GPU chunked transcoding job."""
    job = DualGPUTranscodeJob(filename, path, hls_dir, playlist)
    job.start()
    return job
