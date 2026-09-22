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
# Segment-index stride: 4x the planned segments per 60s chunk, so a render that emits one or two
# segments more than planned still cannot reach the next chunk's range. Over this much of a chunk
# is a hard failure (see _chunk_output_ok) rather than silent corruption.
SEGMENTS_PER_CHUNK_STRIDE = 32

# Stamped into a cache directory once its segments are numbered on the strided grid. Its absence
# means the segments are still on the legacy dense grid (round(start/4)), where a chunk's window
# cannot be recovered from indices alone: chunk N's overflow segment sits on chunk N+1's first
# index. Anything that measures a cache must read this marker before assuming strided windows.
HLS_LAYOUT_MARKER = '.seg_layout'
HLS_LAYOUT_STRIDE = 'stride32'


def cache_uses_strided_layout(hls_dir) -> bool:
    """True when *hls_dir* is stamped as using the strided segment grid."""
    try:
        marker = Path(hls_dir) / HLS_LAYOUT_MARKER
        return marker.is_file() and marker.read_text(errors='replace').strip() == HLS_LAYOUT_STRIDE
    except OSError:
        return False


def _probe_file_duration(path) -> float:
    """Measured duration of one media file, or 0.0 when it cannot be probed."""
    try:
        from app.services.transcode_service import _ffprobe_bin
        ffprobe = _ffprobe_bin()
        if not ffprobe:
            return 0.0
        out = subprocess.run(
            [ffprobe, '-v', 'error', '-show_entries', 'format=duration',
             '-of', 'default=nw=1:nk=1', str(path)],
            capture_output=True, text=True, timeout=30, check=False,
        )
        return float(out.stdout.strip())
    except Exception:
        return 0.0

# A chunk that exits 0 while rendering less than this fraction of its expected duration counts
# as a GPU failure: AMD AMF can emit a single zero-length segment and still report success.
MIN_CHUNK_YIELD_RATIO = 0.5

# Rendered-video coverage required before #EXT-X-ENDLIST may be written. Measured against the
# *video* stream end, not the container duration (audio/subtitles may run past the picture).
MIN_COVERAGE_RATIO = 0.98

# Consecutive failed validations tolerated for one cache dir before the job settles by writing
# ENDLIST plus an error marker, so the auto-transcoder cannot re-encode the same tail forever.
MAX_VALIDATION_ATTEMPTS = 3

# Serialises master-playlist rewrites: the worker threads, the 1 Hz progress updater and
# request threads all rebuild the same file, and a torn read is what _hls_resume_point then
# freezes into both playlist.m3u8 and playlist.m3u8.bak.
_PLAYLIST_WRITE_LOCK = threading.Lock()

# Consecutive validation failures keyed by HLS cache dir (module-level: survives job restarts).
_VALIDATION_FAILURES: Dict[str, int] = {}
# Cache dirs whose last validation attempt came up short: the next attempt must re-render the
# tail instead of trusting "all chunks cached" (see _tail_chunks for why that can be wrong).
_FORCE_TAIL_RERENDER: Dict[str, bool] = {}
# How many tail repairs a cache has had; after MAX_TAIL_REPAIRS the cache is left alone so a
# hopeless file cannot burn GPU time forever.
_TAIL_REPAIR_ATTEMPTS: Dict[str, int] = {}
MAX_TAIL_REPAIRS = 3
# Fraction of the media treated as "the tail" when a forced re-render is needed.
TAIL_RERENDER_FRACTION = 0.95


def plan_chunks(total_duration: float, chunk_duration: float = DEFAULT_CHUNK_DURATION) -> List[Dict]:
    """Divide media duration into contiguous chunk specifications."""
    if total_duration <= 0:
        return []

    chunks = []
    chunk_id = 0
    current_time = 0.0

    while current_time < total_duration:
        dur = min(chunk_duration, total_duration - current_time)
        # Strided, collision-proof segment indices: every chunk owns its own index range
        # (chunk_id * SEGMENTS_PER_CHUNK_STRIDE). A chunk's render does not necessarily emit
        # exactly the planned number of segments - a 60s chunk can produce 15, 16 or even 1
        # depending on the AMF encoder/driver - and with the old dense grid (round(start/4)) an
        # extra segment landed on the NEXT chunk's first segment index. Whichever render finished
        # last won, destroying ~1.25s of the previous chunk's tail at every chunk boundary
        # (measured: 4 of 5 chunks short, 5.0s lost from a 300s source, 101 chunks / 277.2s in a
        # real cached movie). The stride makes that impossible regardless of encoder behaviour.
        start_seg = int(chunk_id) * SEGMENTS_PER_CHUNK_STRIDE
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

        # Chunk queue + per-job GPU health, guarded by a single lock (avoids lock-ordering
        # hazards between queue mutation and health marking).
        self._state_lock = threading.Lock()
        self._pending_queue: List[Dict] = []
        self._unhealthy: Set[str] = set()

        self.total_duration = 0.0
        self.container_duration = 0.0
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

        # NOTE: do not pin the encoder GOP here. -g <4s worth of frames> gives the Vega 8 exactly
        # 15x4.0s segments but makes the RX 560X emit a single 60s segment (both AMF encoders are
        # free to split wherever they like relative to the 4.0s plan); the layout below is made
        # collision-proof instead of relying on encoder behaviour.

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
                encoding="utf-8",
                errors="replace",
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

    def _chunk_output_ok(self, chunk: Dict) -> bool:
        """Verify a chunk that exited 0 actually produced usable video.

        AMD AMF occasionally exits successfully while emitting a single zero-duration segment
        (observed on the integrated Vega 8 at the tail of a long source). Without this check the
        chunk counts as encoded, the master playlist stays short, and the job reports a coverage
        failure with no indication of which GPU is at fault.
        """
        chunk_pl = self.hls_dir / f"chunk_{chunk['chunk_id']}.m3u8"
        if not chunk_pl.is_file():
            return False
        try:
            text = chunk_pl.read_text(encoding='utf-8', errors='replace')
        except OSError:
            return False
        durations = [float(m.group(1)) for m in re.finditer(r'#EXTINF:([\d.]+)', text)]
        if not durations:
            return False
        produced = sum(durations)
        expected = float(chunk.get('duration') or 0.0)
        if expected <= 0:
            return produced > 0
        # A chunk must stay inside its planned segment range. One segment too many is exactly how
        # a chunk used to overwrite the next chunk's first segment and destroy ~1.25s of the
        # previous chunk's tail (h264_amf's 90-frame default GOP vs the 4.0s plan), so overflow is
        # a failure even when the durations look healthy.
        names = [m.group(1).strip() for m in re.finditer(r'#EXTINF:[\d.]+[^\n]*\n([^\n#]+\.ts)', text)]
        start_seg = int(chunk.get('start_seg') or 0)
        planned = max(1, int(round(expected / SEGMENT_TARGET_DURATION)))
        for name in names:
            match = re.search(r'(\d+)\.ts$', name)
            if not match:
                continue
            if int(match.group(1)) >= start_seg + SEGMENTS_PER_CHUNK_STRIDE:
                logger.error(
                    "Chunk %s wrote segment %s outside its segment stride %d..%d — it would "
                    "overwrite the next chunk's first segment",
                    chunk.get('chunk_id'), name, start_seg, start_seg + SEGMENTS_PER_CHUNK_STRIDE - 1,
                )
                return False
        if len(names) > planned * 2:
            logger.error("Chunk %s emitted %d segments for a %.1fs window (planned %d) — treating "
                         "it as unrendered", chunk.get('chunk_id'), len(names), expected, planned)
            return False
        return produced >= expected * MIN_CHUNK_YIELD_RATIO

    def _mark_worker_unhealthy(self, worker: GPUWorkerConfig) -> None:
        """Retire a GPU for the remainder of this job after it produced unusable output."""
        with self._state_lock:
            self._unhealthy.add(worker.name)

    def _next_healthy_worker(self, exclude: Optional[GPUWorkerConfig] = None) -> Optional[GPUWorkerConfig]:
        with self._state_lock:
            unhealthy = set(self._unhealthy)
        for w in self.workers:
            if w.name in unhealthy or (exclude is not None and w.name == exclude.name):
                continue
            return w
        return None

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

    def _chunk_fully_rendered(self, chunk: Dict) -> bool:
        """True only when every expected segment of the chunk exists and is non-empty.

        The previous check tested just the first and last segment of the range, so a chunk
        with holes in the middle counted as rendered and was never re-encoded. Duration is
        deliberately not compared here: FFmpeg splits on keyframes and may emit segments
        below the 4s target, which would mark every chunk pending and force a full re-encode.
        Tail shortfalls are handled explicitly by _tail_chunks.
        """
        start = chunk['start_seg']
        for idx in range(start, start + chunk['expected_segs']):
            seg = self.hls_dir / f"segment_{idx:06d}.ts"
            if not seg.is_file() or seg.stat().st_size == 0:
                return False
        # Every segment can exist while the chunk's frames are missing: a resume that trusted the
        # understated boundary labels re-rendered from a later time, so the head of the chunk was
        # never produced. Treat a frame deficit as "not rendered" so the chunk is re-encoded
        # instead of being reported as cached forever.
        from app.services.transcode_service import chunk_content_deficits
        try:
            if chunk_content_deficits(self.hls_dir, self.total_duration,
                                      source_path=getattr(self, 'path', None),
                                      chunk_ids={chunk['chunk_id']}):
                return False
        except Exception as exc:
            logger.debug("Frame accounting unavailable for chunk %s: %s", chunk.get('chunk_id'), exc)
        return True

    def _tail_chunks(self, all_chunks: List[Dict]) -> List[Dict]:
        """Chunks covering the last TAIL_RERENDER_FRACTION of the media.

        Segment indices are planned against a fixed 4s segment, but the encoder splits on the
        source's keyframes and commonly emits shorter segments (e.g. 3.88s). The planned
        segment count then stops short of the media end, every chunk still looks "cached" and
        coverage validation can never pass - the cache is stuck forever. Re-rendering the tail
        is what actually closes the gap.
        """
        if not all_chunks or self.total_duration <= 0:
            return []
        if _TAIL_REPAIR_ATTEMPTS.get(str(self.hls_dir), 0) > MAX_TAIL_REPAIRS:
            logger.error(
                "%s: %d tail repairs did not reach the coverage threshold; stopping automatic "
                "retries (a manual full re-encode is needed)",
                self.filename, MAX_TAIL_REPAIRS,
            )
            return []
        cutoff = self.total_duration * TAIL_RERENDER_FRACTION
        # overlap, not "starts after": with a coarse chunk grid the last chunk can begin well
        # before the cutoff and still hold the missing seconds
        return [c for c in all_chunks
                if c['start_time'] + float(c.get('duration') or 0) > cutoff]

    def _update_master_playlist(self, is_complete: bool = False):
        """Reconstruct master playlist.m3u8 from contiguous segment files on disk with RFC 8216 discontinuities."""
        # Glob, never a dense walk from 0: segment indices are strided (chunk_id * 32), so a
        # dense walk stops at the first inter-chunk gap and silently drops every later chunk from
        # the playlist (measured: coverage read 50% for a fully rendered 120s source).
        disk_segs = [p for p in sorted(self.hls_dir.glob("segment_*.ts")) if p.stat().st_size > 0]

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
        # Deliberately NO label correction here. ffmpeg's boundary labels are honest (a segment
        # labelled 2.4s really holds 60 frames = 2.4s of video); the container duration that a
        # naive probe returns includes the audio pre-roll and would overstate the timeline,
        # hiding exactly the content loss the frame accounting in _finalize is there to catch.
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
        from app.services.transcode_service import write_text_atomic
        with _PLAYLIST_WRITE_LOCK:
            write_text_atomic(self.playlist, text)
            try:
                write_text_atomic(self.hls_dir / "playlist.m3u8.bak", text)
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

    def _measure_coverage(self):
        """Return (rendered_seconds, has_segments, coverage_ratio) for the assembled playlist."""
        playlist_text = ""
        try:
            playlist_text = self.playlist.read_text(encoding="utf-8", errors="replace")
        except OSError:
            pass
        rendered_duration = sum(
            float(m.group(1))
            for m in re.finditer(r'#EXTINF:([\d.]+)', playlist_text)
        )
        has_segments = any(self.hls_dir.glob("segment_*.ts"))
        coverage = (rendered_duration / self.total_duration) if self.total_duration else 0.0
        return rendered_duration, has_segments, coverage

    def _repair_deficient_chunks(self, max_chunks: int = 12) -> int:
        """Re-render chunks that came out short of video frames, one at a time.

        Two chunks encoding concurrently on the two GPUs can drop up to one GOP of frames at the
        head of a seeked chunk for some sources (measured on a synthetic source: 1.25s-2.5s of a
        60s chunk, 4 of 5 chunks in one run; the very same chunk rendered alone is frame-complete
        1440/1440, and a run of the same chunk with a pre-roll margin is complete too, so the
        encoder is not inherently lossy). Serialising only the repairs keeps full parallel
        throughput for the bulk render while making the end state complete. The loop is bounded -
        a chunk that stays short is left for the next pipeline pass instead of being re-rendered
        in a tight loop - and every repair is verified by frame accounting, never by labels.
        """
        if self._cancelled.is_set() or not self.workers or self.total_duration <= 0:
            return 0
        from app.services.transcode_service import chunk_content_deficits
        try:
            deficits = chunk_content_deficits(
                self.hls_dir, self.total_duration, source_path=getattr(self, 'path', None))
        except Exception as exc:
            logger.warning("Frame verification failed for %s: %s", self.filename, exc)
            return 0
        if not deficits:
            return 0

        plan = {c['chunk_id']: c for c in plan_chunks(self.total_duration)}
        worker = self.workers[0]
        logger.warning(
            "Re-rendering %d chunk(s) of %s serially (missing %s): %s",
            min(len(deficits), max_chunks), self.filename,
            ", ".join(f"#{d['chunk_id']} {d['missing_s']}s" for d in deficits[:max_chunks]),
            "frame accounting",
        )
        repaired = 0
        for deficit in deficits[:max_chunks]:
            if self._cancelled.is_set():
                break
            chunk = plan.get(deficit['chunk_id'])
            if chunk is None:
                continue
            if self._execute_chunk(chunk, worker):
                repaired += 1
        if repaired:
            logger.info("Serial repair re-rendered %d chunk(s) of %s", repaired, self.filename)
        self._update_master_playlist(is_complete=False)
        return repaired

    def _finalize(self) -> None:
        """Assemble the master playlist and only then declare completion.

        #EXT-X-ENDLIST is the marker the rest of the app treats as "this cache is finished", so it
        is written only when the rendered output actually covers the source video. A failed
        validation leaves the playlist as an EVENT playlist (resumable) and records an error,
        instead of letting a broken transcode masquerade as a cached, complete movie.
        """
        self._update_master_playlist(is_complete=False)
        rendered_duration, has_segments, coverage = self._measure_coverage()

        # Coverage is computed from durations, and durations cannot see lost frames: a resume
        # that trusted the mislabelled boundaries re-rendered later content over the boundary
        # content, so every segment exists and measures sanely while seconds of frames are
        # simply absent. Count frames per chunk before declaring the cache finished.
        deficits = []
        if has_segments and coverage >= MIN_COVERAGE_RATIO:
            from app.services.transcode_service import chunk_content_deficits
            try:
                deficits = chunk_content_deficits(self.hls_dir, self.total_duration,
                                                  source_path=getattr(self, 'path', None))
            except Exception as exc:
                logger.warning("Frame accounting failed for %s: %s", self.filename, exc)

        if has_segments and coverage >= MIN_COVERAGE_RATIO and not deficits:
            _VALIDATION_FAILURES.pop(str(self.hls_dir), None)
            _FORCE_TAIL_RERENDER.pop(str(self.hls_dir), None)
            _TAIL_REPAIR_ATTEMPTS.pop(str(self.hls_dir), None)
            self._update_master_playlist(is_complete=True)
            self._returncode = 0
            logger.info(f"Dual-GPU Transcoding for {self.filename} completed successfully!")
            return

        if deficits:
            logger.error(
                "Refusing ENDLIST for %s: %d chunk(s) are missing %.1fs of video frames "
                "(worst: %.1fs at %.1fs) — the affected chunks will be re-rendered",
                self.filename, len(deficits), sum(d['missing_s'] for d in deficits),
                max(d['missing_s'] for d in deficits), min(d['start'] for d in deficits))

        attempts = _VALIDATION_FAILURES.get(str(self.hls_dir), 0) + 1
        _VALIDATION_FAILURES[str(self.hls_dir)] = attempts
        # The rendered seconds fell short of the plan: force the next attempt to re-render the
        # tail, otherwise "all chunks cached" keeps it stuck below the coverage threshold.
        _FORCE_TAIL_RERENDER[str(self.hls_dir)] = True
        self._returncode = 1
        logger.error(
            "Dual-GPU transcoding failed for %s: only %.1f%% of the video duration "
            "(%.1fs of %.1fs) was rendered (attempt %d/%d)",
            self.filename, coverage * 100, rendered_duration, self.total_duration,
            attempts, MAX_VALIDATION_ATTEMPTS,
        )
        repairs = _TAIL_REPAIR_ATTEMPTS.get(str(self.hls_dir), 0) + 1
        _TAIL_REPAIR_ATTEMPTS[str(self.hls_dir)] = repairs
        if attempts >= MAX_VALIDATION_ATTEMPTS:
            if coverage >= MIN_COVERAGE_RATIO:
                self._update_master_playlist(is_complete=True)
            else:
                # Never write ENDLIST for an under-covered cache: ENDLIST is authoritative, so
                # doing it here permanently hid the missing seconds - the cache reported
                # "ready", playback stopped at its real end and no repair was ever attempted.
                logger.error(
                    "Leaving %s WITHOUT ENDLIST after %d attempts (only %.1f%% rendered); "
                    "the tail will be re-rendered on the next attempt",
                    self.filename, attempts, coverage * 100,
                )
            logger.error(
                "Giving up on %s after %d validation attempts; leaving the cache in place for inspection",
                self.filename, attempts,
            )
        try:
            self.progress_file.write_text(
                f"out_time_us={int(rendered_duration * 1_000_000)}\n"
                f"out_time_ms={int(rendered_duration * 1_000_000)}\n"
                f"speed=0.00x\n"
                "progress=error\n"
                f"error=HLS transcode rendered {coverage * 100:.1f}% of the source video "
                f"(attempt {attempts}/{MAX_VALIDATION_ATTEMPTS})\n"
            )
        except OSError:
            pass

    def _prepare_cache_layout(self) -> bool:
        """Make sure this cache uses the strided segment grid, discarding a legacy one.

        Caches built before the stride used dense indices (round(start/4)), which is exactly the
        layout in which one chunk's overflow segment overwrote the next chunk's first segment.
        A dense cache cannot be migrated segment-by-segment - the indices are its ordering - so an
        unmarked cache that already holds segments is cleared and re-rendered. Returns True when
        the cache is clean (empty or already strided).
        """
        marker = self.hls_dir / HLS_LAYOUT_MARKER
        if cache_uses_strided_layout(self.hls_dir):
            return True
        existing = sorted(self.hls_dir.glob('segment_*.ts'))
        if not existing:
            self._write_layout_marker(marker)
            return True
        if self._migrate_dense_layout(existing):
            self._write_layout_marker(marker)
            return True
        logger.warning(
            "Cache for %s uses the legacy dense segment grid (%d segments) and its chunks "
            "overlap, so the content at those boundaries is already lost — clearing it to "
            "re-render on the strided grid",
            self.filename, len(existing),
        )
        removed = 0
        for pattern in ('segment_*.ts', 'chunk_*.m3u8', 'playlist.m3u8', 'playlist.m3u8.bak', 'hls.progress'):
            for path in self.hls_dir.glob(pattern):
                try:
                    path.unlink()
                    removed += 1
                except OSError as exc:
                    logger.debug("Could not remove %s: %s", path, exc)
        self._write_layout_marker(marker)
        logger.info("Cleared %d legacy cache file(s) for %s", removed, self.filename)
        return True

    def _migrate_dense_layout(self, existing: list) -> bool:
        """Renumber an intact dense cache onto the strided grid, without re-encoding anything.

        Nine of the ten live caches emitted exactly 15 segments per chunk, so their indices are
        contiguous and unambiguous - only the *numbering* predates the stride. Renaming the files
        and rewriting the playlists preserves hours of GPU work. A cache whose chunk playlists
        overlap (a chunk wrote an extra segment onto its neighbour's first index - the shape that
        destroyed content in Spider-Man's cache) cannot be salvaged this way: the file at that
        index holds only one of the two chunks' content, so it is reported False and re-rendered.
        """
        try:
            playlists = sorted(
                self.hls_dir.glob('chunk_*.m3u8'),
                key=lambda p: int(re.search(r'(\d+)', p.name).group(1)),
            )
        except (ValueError, AttributeError):
            return False
        if not playlists:
            return False

        entries = []          # [(playlist, [(label, old_name), ...]), ...]
        seen = set()
        mapping = []
        for cid, pl in enumerate(playlists):
            try:
                text = pl.read_text(encoding='utf-8', errors='replace')
            except OSError:
                return False
            pairs = re.findall(r'#EXTINF:([\d.]+)[^\n]*\n([^\n#]+\.ts)', text)
            if not pairs:
                return False
            if len(pairs) > SEGMENTS_PER_CHUNK_STRIDE:
                return False
            base = cid * SEGMENTS_PER_CHUNK_STRIDE
            for k, (label, name) in enumerate(pairs):
                name = name.strip()
                if name in seen:              # two chunks claim the same segment: content is gone
                    return False
                seen.add(name)
                mapping.append((name, f"segment_{base + k:06d}.ts"))
            entries.append((pl, [(label, n.strip()) for label, n in pairs], base))

        if len(seen) != len(existing):
            return False                      # orphan segments no chunk claims: re-render
        if any(not (self.hls_dir / old).is_file() for old, _ in mapping):
            return False

        # two-phase rename: the new ranges interleave with the old ones
        staged = []
        for i, (old_name, new_name) in enumerate(mapping):
            tmp = self.hls_dir / f".migrate_{i:06d}.tmp"
            try:
                os.replace(self.hls_dir / old_name, tmp)
            except OSError as exc:
                logger.warning("Layout migration failed for %s: %s", self.filename, exc)
                return False
            staged.append((tmp, new_name))
        for tmp, new_name in staged:
            try:
                os.replace(tmp, self.hls_dir / new_name)
            except OSError as exc:
                logger.warning("Layout migration failed for %s: %s", self.filename, exc)
                return False

        # chunk playlists keep their (honest) labels, only the names move
        for pl, pairs, base in entries:
            body = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:%d\n#EXT-X-MEDIA-SEQUENCE:0\n" % int(SEGMENT_TARGET_DURATION)
            for k, (label, _old) in enumerate(pairs):
                body += f"#EXTINF:{label},\nsegment_{base + k:06d}.ts\n"
            try:
                pl.write_text(body, encoding='utf-8')
            except OSError as exc:
                logger.warning("Could not rewrite %s: %s", pl, exc)
                return False

        # the served master playlist references the same files by name
        from app.services.transcode_service import write_text_atomic
        for name in ('playlist.m3u8', 'playlist.m3u8.bak'):
            path = self.hls_dir / name
            if not path.is_file():
                continue
            try:
                text = path.read_text(encoding='utf-8', errors='replace')
            except OSError:
                continue
            for old_name, new_name in mapping:
                text = text.replace(old_name, new_name)
            try:
                write_text_atomic(path, text)
            except Exception as exc:
                logger.warning("Could not rewrite %s: %s", path, exc)

        logger.info(
            "Migrated %s to the strided segment grid (%d segments, %d chunks) without re-encoding",
            self.filename, len(mapping), len(entries),
        )
        return True

    @staticmethod
    def _write_layout_marker(marker: Path) -> None:
        try:
            tmp = marker.with_suffix('.tmp')
            tmp.write_text('stride32', encoding='utf-8')
            os.replace(tmp, marker)
        except OSError as exc:
            logger.debug("Could not write layout marker %s: %s", marker, exc)

    def _run_pipeline(self):
        """Main coordinator thread executing chunks in prioritized parallel order."""
        try:
            info = probe_media(self.path)
            self.container_duration = float(info.get('format', {}).get('duration') or 0.0)
            if self.container_duration <= 0:
                # Probe failed or zero length
                self._returncode = 1
                self._finished.set()
                return

            # A legacy dense-grid cache must be discarded before the queue is planned, or its
            # unresumable indices would collide with the strided ones.
            self._prepare_cache_layout()

            # Plan and validate against the video stream's end, not the container duration:
            # WEB-DL/WEBRip muxes routinely carry audio/subtitle packets minutes past the last
            # video frame, which would otherwise score a complete render as incomplete and
            # re-encode a tail that can never produce video.
            try:
                from app.services.transcode_service import source_video_duration
                video_duration = source_video_duration(self.path, fallback=self.container_duration)
            except Exception as e:
                logger.warning(
                    "Video-duration measurement failed for %s (%s); using container duration",
                    self.filename, e,
                )
                video_duration = self.container_duration
            self.total_duration = float(video_duration or self.container_duration)
            if abs(self.total_duration - self.container_duration) > 1.0:
                logger.info(
                    "Source %s: container %.1fs but video stream ends at %.1fs — planning against video",
                    self.filename, self.container_duration, self.total_duration,
                )

            all_chunks = plan_chunks(self.total_duration)
            if not all_chunks:
                self._returncode = 0
                self._finished.set()
                return

            self.hls_dir.mkdir(parents=True, exist_ok=True)

            # Check existing completed segments for resume
            force_tail = _FORCE_TAIL_RERENDER.pop(str(self.hls_dir), False)
            tail = self._tail_chunks(all_chunks) if force_tail else []
            pending_chunks = []
            for c in all_chunks:
                if force_tail and c in tail:
                    continue  # handled below: tail is re-rendered regardless of cache state
                if self._chunk_fully_rendered(c):
                    continue  # Chunk already fully rendered
                pending_chunks.append(c)
            if tail:
                logger.info(
                    "Re-rendering the tail of %s: %d chunk(s) from %.1fs (previous attempt fell short of %.1fs)",
                    self.filename, len(tail), tail[0]['start_time'], self.total_duration,
                )
                for c in tail:
                    if c not in pending_chunks:
                        pending_chunks.append(c)

            if not pending_chunks:
                logger.info(f"All {len(all_chunks)} chunks for {self.filename} already cached.")
                self._finalize()
                self._finished.set()
                return

            init_segs = 0
            while (self.hls_dir / f"segment_{init_segs:06d}.ts").is_file():
                init_segs += 1
            self._initial_cached_sec = init_segs * SEGMENT_TARGET_DURATION
            self._start_wall_time = time.time()

            logger.info(f"Starting Multi-GPU Transcoding for {self.filename} ({len(pending_chunks)} chunks remaining)")

            # Multi-GPU worker assignment: every worker pulls from one shared queue. A worker that
            # fails a chunk (or reports success while rendering almost nothing) is retired for this
            # job and the chunk is retried on a healthy worker, so a misbehaving adapter cannot
            # stall the job or silently shorten the output.
            self._pending_queue = list(pending_chunks)

            def worker_loop(assigned_worker: GPUWorkerConfig):
                while not self._cancelled.is_set():
                    with self._state_lock:
                        if assigned_worker.name in self._unhealthy:
                            logger.warning("GPU worker %s retired for this job; stopping its loop", assigned_worker.name)
                            return
                        current_chunk = self._pending_queue.pop(0) if self._pending_queue else None
                    if not current_chunk:
                        break

                    success = self._execute_chunk(current_chunk, assigned_worker)
                    if success and not self._cancelled.is_set() and not self._chunk_output_ok(current_chunk):
                        logger.error(
                            "GPU worker %s reported success for chunk %d but produced under %.0f%% of "
                            "the expected %.1fs — retiring it for this job",
                            assigned_worker.name,
                            current_chunk['chunk_id'],
                            MIN_CHUNK_YIELD_RATIO * 100,
                            current_chunk['duration'],
                        )
                        self._mark_worker_unhealthy(assigned_worker)
                        success = False

                    if not success and not self._cancelled.is_set():
                        fallback_worker = self._next_healthy_worker(exclude=assigned_worker)
                        if fallback_worker is None:
                            logger.error(
                                "Chunk %d could not be produced by any healthy GPU worker; aborting job",
                                current_chunk['chunk_id'],
                            )
                            self._cancelled.set()
                        else:
                            logger.warning(
                                "Chunk %d failed on %s; retrying on %s",
                                current_chunk['chunk_id'],
                                assigned_worker.name,
                                fallback_worker.name,
                            )
                            if not self._execute_chunk(current_chunk, fallback_worker):
                                logger.error(
                                    "Chunk %d also failed on %s; retiring it for this job",
                                    current_chunk['chunk_id'],
                                    fallback_worker.name,
                                )
                                self._mark_worker_unhealthy(fallback_worker)

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
                # Frame-verify and serialise the repairs before deciding completion: a batch of
                # concurrent chunks can each lose a GOP, and ENDLIST must not be written over it.
                self._repair_deficient_chunks()
                self._finalize()
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

