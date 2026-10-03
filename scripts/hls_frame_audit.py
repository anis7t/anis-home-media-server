"""Per-chunk frame accounting for every HLS cache - the only trustworthy content measure.

Counts video packets per chunk and compares them with `chunk window x source fps`. Container
durations (and therefore #EXTINF labels, which include the audio pre-roll) cannot see missing
frames: a cache can measure 100% by duration and still be short by minutes of video.

Usage:  python scripts/hls_frame_audit.py [name-filter ...]
A frame count of -1 means "unknown" (unreadable/absent), never "empty".
"""
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

_BIN = (r"C:\Users\anis7\AppData\Local\Microsoft\WinGet\Packages"
        r"\Gyan.FFmpeg.Essentials_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.1-essentials_build\bin")
if Path(_BIN).is_dir():
    os.environ["PATH"] = _BIN + os.pathsep + os.environ.get("PATH", "")
sys.path.insert(0, r"E:\MediaServer")
FFPROBE = str(Path(_BIN) / "ffprobe.exe")


def count_frames(path):
    """Video frames in one segment.

    Delegates to the server's own memoised measurement so there is a single probe implementation
    with a single convention for "unknown". The local ffprobe call this replaced returned 0 on
    failure, which the server deliberately refuses to do: an unreadable segment is unknown (-1),
    never empty, because treating it as empty marks every chunk deficient and re-renders forever.
    """
    from app.services.transcode_service import measure_segment_frame_count
    return measure_segment_frame_count(path)


def source_fps(path):
    out = subprocess.run(
        [FFPROBE, "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=r_frame_rate,avg_frame_rate", "-of", "json", str(path)],
        capture_output=True, text=True, timeout=120)
    try:
        stream = json.loads(out.stdout)["streams"][0]
    except (ValueError, KeyError, IndexError):
        return 24.0
    for key in ("avg_frame_rate", "r_frame_rate"):
        value = stream.get(key) or ""
        if "/" in value:
            num, den = value.split("/")
            try:
                if float(den) > 0:
                    return float(num) / float(den)
            except ValueError:
                continue
    return 24.0


def audit(media):
    from app.services.transcode_service import hls_cache_dir
    # Shared with the server's own accounting (transcode_service.chunk_content_deficits) so the
    # two can never disagree again: this script used to apply max(0.6, 1.5% * duration) while the
    # server applied max(0.6, 1% * duration), which made a 0.625s deficit on a 60s chunk invisible
    # here and visible there - the same cache, two verdicts.
    from app.services.chunk_transcode_service import (
        expected_frames_for_window, plan_chunks, SEGMENTS_PER_CHUNK_STRIDE,
        chunk_boundary_frame_tolerance)
    cache = hls_cache_dir(media)
    if not (cache / "playlist.m3u8").is_file():
        return None
    fps = source_fps(media)
    if fps <= 0:
        return {"media": media.name, "fps": fps, "error": "unusable frame rate - not judged"}
    plan = plan_chunks(_video_end(media))
    segs = sorted(cache.glob("segment_*.ts"))
    # Deliberately conservative. This audit counts packets over tens of GB and can run while the
    # server is transcoding; at one worker per core it starves the AMF encoder's CPU side and the
    # GPUs visibly drop to single-digit utilisation. Leave headroom for the transcode.
    workers = max(1, min(4, (os.cpu_count() or 4) // 2))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        counts = dict(zip([s.name for s in segs], pool.map(count_frames, segs)))
    # A zero-length segment terminates a chunk's run exactly as a missing one does.
    present = {s.name for s in segs if s.stat().st_size > 0}

    tolerance = chunk_boundary_frame_tolerance(fps)
    rows, missing_total, missing_frames_total, unknown, unstarted = [], 0.0, 0, 0, 0
    for c in plan:
        start = c["start_seg"]
        # Measure the chunk's OWN contiguous run of segments, bounded by the stride - NOT the
        # planned `expected_segs` count. A 60s chunk legitimately emits 15, 16 or 17 segments
        # depending on the encoder's keyframes, and all of them belong to this chunk. Measuring
        # only the planned count undercounts the frames and invents enormous phantom deficits:
        # it reported 104,601 missing frames (72 minutes) in a cache the server judges complete.
        # This is the same defect the server's strided-layout work fixed; this script was missed.
        run, i = [], start
        while i < start + SEGMENTS_PER_CHUNK_STRIDE:
            name = f"segment_{i:06d}.ts"
            if name not in present:
                if run:
                    break              # end of this chunk's run
                i += 1
                continue                 # this chunk has not started yet
            run.append(name)
            i += 1
        if not run:
            unstarted += 1
            continue
        window = [counts[n] for n in run]
        if any(v < 0 for v in window):
            unknown += 1        # unknown is never "empty" and never deficient
            continue
        frames = sum(window)
        expected = expected_frames_for_window(c["start_time"], c["duration"], fps)
        missing_frames = expected - frames
        if missing_frames > tolerance:
            rows.append({"chunk_id": c["chunk_id"], "start": c["start_time"],
                         "segments": len(run), "expected_frames": expected, "frames": frames,
                         "missing_frames": missing_frames,
                         "missing_s": round(missing_frames / fps, 2)})
            missing_total += missing_frames / fps
            missing_frames_total += missing_frames
    return {"media": media.name, "fps": round(fps, 3), "chunks": len(plan),
            "tolerance_frames_per_chunk": tolerance,
            "unmeasurable_chunks": unknown, "unrendered_chunks": unstarted,
            "deficient_chunks": len(rows), "missing_frames": missing_frames_total,
            "missing_s": round(missing_total, 1),
            "worst": sorted(rows, key=lambda r: -r["missing_frames"])[:6]}


def _video_end(media):
    from app.services.transcode_service import source_video_duration
    return source_video_duration(media, fallback=0.0)


if __name__ == "__main__":
    from app.services.media_service import video_paths
    needles = [n.lower() for n in sys.argv[1:]] or ["spider", "satluj"]
    for media in video_paths():
        if any(n in media.name.lower() for n in needles):
            res = audit(media)
            if res:
                print(json.dumps(res, indent=2), flush=True)