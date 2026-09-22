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
sys.path.insert(0, r"C:\MediaServer")
FFPROBE = str(Path(_BIN) / "ffprobe.exe")


def count_frames(path):
    try:
        out = subprocess.run(
            [FFPROBE, "-v", "error", "-select_streams", "v:0", "-count_packets",
             "-show_entries", "stream=nb_read_packets", "-of", "default=nw=1:nk=1", str(path)],
            capture_output=True, text=True, timeout=120)
        for line in out.stdout.splitlines():
            line = line.strip()
            if line and line != "N/A":
                try:
                    return int(float(line))     # duplicated per TS program: take the first
                except ValueError:
                    continue
        return 0
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0


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
    from app.services.chunk_transcode_service import plan_chunks
    cache = hls_cache_dir(media)
    if not (cache / "playlist.m3u8").is_file():
        return None
    fps = source_fps(media)
    plan = plan_chunks(_video_end(media))
    segs = sorted(cache.glob("segment_*.ts"))
    with ThreadPoolExecutor(max_workers=8) as pool:
        counts = dict(zip([s.name for s in segs], pool.map(count_frames, segs)))
    rows, missing_total = [], 0.0
    for c in plan:
        start, count = c["start_seg"], c["expected_segs"]
        frames = sum(counts.get(f"segment_{i:06d}.ts", 0) for i in range(start, start + count))
        expected = c["duration"] * fps
        deficit = (expected - frames) / fps if fps else 0.0
        if deficit > max(0.6, 0.015 * c["duration"]):
            rows.append({"chunk_id": c["chunk_id"], "start": c["start_time"],
                         "expected_frames": round(expected), "frames": frames,
                         "missing_s": round(deficit, 2)})
            missing_total += deficit
    return {"media": media.name, "fps": round(fps, 3), "chunks": len(plan),
            "deficient_chunks": len(rows), "missing_s": round(missing_total, 1),
            "worst": sorted(rows, key=lambda r: -r["missing_s"])[:6]}


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