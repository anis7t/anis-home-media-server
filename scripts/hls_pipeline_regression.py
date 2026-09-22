"""End-to-end regression harness for the chunked HLS pipeline (synthetic source).

Runs the REAL dual-GPU pipeline over a synthetic 300s source and reports per-chunk frame
deficits and the per-segment frame profile by position within a chunk. This is how the
segment-index collision was found and how the strided layout is verified: expect
"deficient chunks: 0 / 5", a total of one frame per source frame, coverage 100% and rc=0.

Usage:  python scripts/hls_pipeline_regression.py
"""

import json
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

_BIN = (r"C:\Users\anis7\AppData\Local\Microsoft\WinGet\Packages"
        r"\Gyan.FFmpeg.Essentials_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.1-essentials_build\bin")
os.environ["PATH"] = _BIN + os.pathsep + os.environ.get("PATH", "")
sys.path.insert(0, r"C:\MediaServer")
FFMPEG, FFPROBE = str(Path(_BIN) / "ffmpeg.exe"), str(Path(_BIN) / "ffprobe.exe")

import app  # noqa: E402
import app.config as config  # noqa: E402
from app.services import chunk_transcode_service as cts  # noqa: E402
from app.services.transcode_service import (chunk_content_deficits, clear_segment_probe_cache,  # noqa: E402
                                            clear_video_duration_cache, source_frame_rate,
                                            source_video_duration)

DURATION = 300


def frames(path):
    out = subprocess.run([FFPROBE, "-v", "error", "-select_streams", "v:0", "-count_packets",
                          "-show_entries", "stream=nb_read_packets", "-of", "default=nw=1:nk=1",
                          str(path)], capture_output=True, text=True, timeout=120)
    for line in out.stdout.splitlines():
        line = line.strip()
        if line and line != "N/A":
            return int(float(line))
    return -1


if __name__ == "__main__":
    tmp = Path(tempfile.mkdtemp(prefix="syn_detail_")).resolve()
    cache, media = tmp / "cache", tmp / "media"
    (cache / "hls").mkdir(parents=True)
    media.mkdir(parents=True)
    app.CACHE_DIR = config.CACHE_DIR = cache
    config.MEDIA_ROOT = media
    if hasattr(app, "MEDIA_ROOT"):
        app.MEDIA_ROOT = media

    src = media / "synth_2s_gop.mkv"
    subprocess.run([FFMPEG, "-y", "-v", "error", "-f", "lavfi",
                    "-i", f"testsrc=size=320x240:rate=24:duration={DURATION}",
                    "-f", "lavfi", "-i", f"sine=frequency=440:duration={DURATION}",
                    "-c:v", "libx264", "-x264-params", "keyint=48:min-keyint=48:scenecut=0",
                    "-preset", "veryfast", "-c:a", "aac", "-shortest", str(src)],
                   check=True, capture_output=True)

    hls = cache / "hls" / "synthetic"
    hls.mkdir(parents=True)
    job = cts.DualGPUTranscodeJob(src.name, src, hls, hls / "playlist.m3u8")
    job._run_pipeline()
    clear_video_duration_cache()
    clear_segment_probe_cache()
    end = source_video_duration(src, fallback=0.0)
    fps = source_frame_rate(src)
    print(f"source {DURATION}s  video_end={end:.2f}s  fps={fps:.3f}  rc={job._returncode}", flush=True)

    deficits = chunk_content_deficits(hls, end, source_path=src)
    print(f"deficient chunks: {len(deficits)} / {len(cts.plan_chunks(end))}")
    for d in deficits:
        print(f"   chunk {d['chunk_id']:>3} at {d['start']:>7.1f}s: {d['frames']}/{d['expected_frames']} "
              f"frames (missing {d['missing_s']}s)")

    segs = sorted(hls.glob("segment_*.ts"))
    with ThreadPoolExecutor(max_workers=8) as pool:
        counts = dict(zip([s.name for s in segs], pool.map(frames, segs)))
    by_pos = {}
    for name, count in counts.items():
        pos = int(name.split("_")[1].split(".")[0]) % 15
        by_pos.setdefault(pos, []).append(count)
    print(f"\n{'pos':>4} {'segments':>9} {'mean frames':>12} {'implied s':>10}")
    for pos in sorted(by_pos):
        rows = by_pos[pos]
        mean = sum(rows) / len(rows)
        print(f"{pos:>4} {len(rows):>9} {mean:>12.1f} {mean / fps:>10.2f}")
    total = sum(c for c in counts.values() if c > 0)
    print(f"\ntotal frames {total} = {total / fps:.1f}s of video (expected {end:.1f}s)")
    Path(r"C:\MediaServer\_syn_detail.json").write_text(json.dumps(
        {"deficits": deficits, "by_position": {k: len(v) for k, v in by_pos.items()}}, indent=2))
    print("segments with unreadable frame counts:",
          sum(1 for c in counts.values() if c < 0))