"""Dynamic Multi-GPU Chunked Transcoding Service.

Distributes movie HLS transcoding across multiple GPUs (e.g. Discrete RX 560X + Integrated Vega 8)
by assigning keyframe-aware sequential chunks concurrently and continuously assembling the master HLS playlist.
"""
import logging
import math
import os
import re
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

    def get_active_pids(self) -> List[int]:
        """Return list of PIDs of all active chunk FFmpeg processes."""
        with self._proc_lock:
            return [p.pid for p in self._active_procs if getattr(p, "pid", None) and p.poll() is None]

    def terminate(self):
        """ProcessProxy compatibility: terminate all active chunk workers and stop job."""
        self._cancelled.set()
        with self._proc_lock:
            for proc in list(self._active_procs):
                try:
                    proc.terminate()
                except Exception:
                    try:
                        proc.kill()
                    except Exception:
                        pass
            self._active_procs.clear()
        self._returncode = -1
        self._finished.set()

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
                '-output_ts_offset', f"{start_time:.3f}",
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

    def _parse_chunk_segment_durations(self, chunk_id: Optional[int] = None) -> Dict[str, float]:
        """Parse real segment durations from chunk playlist files generated by FFmpeg."""
        pattern = f"chunk_{chunk_id}.m3u8" if chunk_id is not None else "chunk_*.m3u8"
        durations = {}
        for pl_file in self.hls_dir.glob(pattern):
            try:
                text = pl_file.read_text(encoding="utf-8", errors="replace")
                for m in re.finditer(r'#EXTINF:([\d.]+)[^\n]*\n([^\n#]+\.ts)', text):
                    durations[m.group(2).strip()] = float(m.group(1))
            except Exception:
                pass
        return durations

    def _update_master_playlist(self, is_complete: bool = False):
        """Reconstruct master playlist.m3u8 from contiguous segment files on disk with RFC 8216 discontinuities."""
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
            "#EXT-X-START:TIME-OFFSET=0",
        ]
        if not is_complete:
            lines.append("#EXT-X-PLAYLIST-TYPE:EVENT")

        # Determine chunk boundary segments for #EXT-X-DISCONTINUITY tags
        chunk_start_segs = set()
        if getattr(self, 'total_duration', 0.0) > 0:
            chunk_start_segs = {c['start_seg'] for c in plan_chunks(self.total_duration) if c['chunk_id'] > 0}
        else:
            for pl_file in self.hls_dir.glob("chunk_*.m3u8"):
                m = re.match(r"chunk_(\d+)\.m3u8", pl_file.name)
                if m and int(m.group(1)) > 0:
                    try:
                        text = pl_file.read_text(encoding="utf-8", errors="replace")
                        first_seg = next((l.strip() for l in text.splitlines() if l.strip().endswith('.ts')), None)
                        if first_seg:
                            m_seg = re.search(r"segment_(\d+)\.ts", first_seg)
                            if m_seg:
                                chunk_start_segs.add(int(m_seg.group(1)))
                    except Exception:
                        pass

        durations_map = self._parse_chunk_segment_durations()
        total_sec = 0.0
        for seg in disk_segs:
            dur = durations_map.get(seg.name, SEGMENT_TARGET_DURATION)
            seg_match = re.search(r"segment_(\d+)\.ts", seg.name)
            if seg_match and int(seg_match.group(1)) in chunk_start_segs:
                lines.append("#EXT-X-DISCONTINUITY")
            lines.append(f"#EXTINF:{dur:.6f},")
            lines.append(seg.name)
            total_sec += dur

        if is_complete:
            lines.append("#EXT-X-ENDLIST")

        text = "\n".join(lines) + "\n"
        self.playlist.write_text(text, encoding="utf-8")
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
            # Primary worker (discrete RX 560X or first capable GPU) handles chunk 0
            primary_worker = self.workers[0]
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
                        # Retry on primary worker if secondary worker failed
                        if assigned_worker != primary_worker:
                            logger.warning(f"Chunk {current_chunk['chunk_id']} failed on {assigned_worker.name}; retrying on {primary_worker.name}")
                            self._execute_chunk(current_chunk, primary_worker)

                    self._update_master_playlist(is_complete=False)

            threads = [
                threading.Thread(target=worker_loop, args=(w,), name=f"gpu-worker-{w.adapter_id}-{self.filename}")
                for w in self.workers
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
                # Never report success merely because the worker threads exited.
                # Every FFmpeg chunk can fail independently, so validate that the
                # assembled HLS actually covers the source before marking the job done.
                self._update_master_playlist(is_complete=False)
                playlist_text = ""
                try:
                    playlist_text = self.playlist.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    pass

                rendered_duration = sum(
                    float(m.group(1))
                    for m in re.finditer(r'^#EXTINF:([\\d.]+)', playlist_text, re.MULTILINE)
                )
                has_segments = any(self.hls_dir.glob("segment_*.ts"))
                coverage = (rendered_duration / self.total_duration) if self.total_duration else 0.0

                if has_segments and "#EXT-X-ENDLIST" not in playlist_text and coverage < 0.95:
                    self._returncode = 1
                    try:
                        self.progress_file.write_text(
                            f"out_time_us={int(rendered_duration * 1_000_000)}\\n"
                            f"out_time_ms={int(rendered_duration * 1_000_000)}\\n"
                            f"speed=0.00x\\n"
                            "progress=error\\n"
                            "error=HLS transcode did not produce complete output\\n"
                        )
                    except OSError:
                        pass
                    logger.error(
                        "Dual-GPU transcoding failed for %s: only %.1f%% of source duration was rendered",
                        self.filename,
                        coverage * 100,
                    )
                else:
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


def reconcile_hls_playlist_discontinuities(hls_dir: Path, source_path: Optional[Path] = None) -> bool:
    """Ensure multi-chunk HLS master playlist contains RFC 8216 #EXT-X-DISCONTINUITY tags across chunk boundaries.

    Returns True if the playlist was repaired, False otherwise.
    """
    hls_dir = Path(hls_dir)
    playlist = hls_dir / 'playlist.m3u8'
    if not playlist.is_file():
        return False

    try:
        text = playlist.read_text(encoding='utf-8', errors='replace')
    except OSError:
        return False

    if '#EXT-X-DISCONTINUITY' in text:
        return False  # Already contains discontinuity tags

    # Find chunk boundary segment indices from chunk_*.m3u8 files or source duration
    chunk_start_segs = set()
    for pl_file in hls_dir.glob("chunk_*.m3u8"):
        m = re.match(r"chunk_(\d+)\.m3u8", pl_file.name)
        if m and int(m.group(1)) > 0:
            try:
                first_seg = next(
                    (l.strip() for l in pl_file.read_text(encoding="utf-8", errors="replace").splitlines() if l.strip().endswith('.ts')),
                    None
                )
                if first_seg:
                    m_seg = re.search(r"segment_(\d+)\.ts", first_seg)
                    if m_seg:
                        chunk_start_segs.add(int(m_seg.group(1)))
            except Exception:
                pass

    if not chunk_start_segs and source_path:
        try:
            info = probe_media(Path(source_path))
            total_dur = float(info.get('format', {}).get('duration') or 0.0)
            if total_dur > 0:
                chunk_start_segs = {c['start_seg'] for c in plan_chunks(total_dur) if c['chunk_id'] > 0}
        except Exception:
            pass

    if not chunk_start_segs:
        # Check if multiple chunk files exist on disk
        chunk_files = list(hls_dir.glob("chunk_*.m3u8"))
        if len(chunk_files) > 1:
            chunk_start_segs = {i * 15 for i in range(1, len(chunk_files) + 1)}

    if not chunk_start_segs:
        return False

    lines = text.splitlines()
    repaired_lines = []
    modified = False

    for i, line in enumerate(lines):
        if line.startswith('#EXTINF:'):
            next_line = lines[i + 1] if i + 1 < len(lines) else ''
            m_seg = re.search(r"segment_(\d+)\.ts", next_line)
            if m_seg and int(m_seg.group(1)) in chunk_start_segs:
                repaired_lines.append("#EXT-X-DISCONTINUITY")
                modified = True
        repaired_lines.append(line)

    if modified:
        new_text = "\n".join(repaired_lines) + "\n"
        try:
            playlist.write_text(new_text, encoding='utf-8')
            try:
                (hls_dir / "playlist.m3u8.bak").write_text(new_text, encoding='utf-8')
            except OSError:
                pass
            logger.info(f"Reconciled #EXT-X-DISCONTINUITY tags for {hls_dir.name} ({len(chunk_start_segs)} boundaries)")
            return True
        except OSError as e:
            logger.warning(f"Failed to write reconciled playlist in {hls_dir}: {e}")

    return False

