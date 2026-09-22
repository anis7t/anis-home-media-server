"""GOP-cadence matrix: does the chunk-boundary #EXTINF defect reproduce, and does the fix hold?

Runs the REAL dual-GPU chunked pipeline (same class the service uses) against synthetic sources
whose keyframe cadence varies, twice per source: with the boundary-label correction active and
with it disabled. Everything is written to a throwaway cache/media root.

A source's keyframe cadence decides where ffmpeg splits HLS segments, which is what made the
muxer mislabel the first segment of each chunk. If the fix is general, every "fixed" run must
validate at >= 98% coverage with no mislabelled segment, while the "unfixed" runs show the
defect for the cadences that trigger it.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

_BIN = (r"C:\Users\anis7\AppData\Local\Microsoft\WinGet\Packages"
        r"\Gyan.FFmpeg.Essentials_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.1-essentials_build\bin")
os.environ["PATH"] = _BIN + os.pathsep + os.environ.get("PATH", "")
sys.path.insert(0, r"C:\MediaServer")

import app  # noqa: E402
import app.config as config  # noqa: E402
from app.services import chunk_transcode_service as cts  # noqa: E402
from app.services.transcode_service import (  # noqa: E402
    chunk_content_deficits,
    chunk_content_holes,
    clear_segment_probe_cache,
    clear_video_duration_cache,
    source_video_duration,
)

TMP = Path(tempfile.mkdtemp(prefix="gop_matrix_")).resolve()
CACHE = TMP / "cache"
MEDIA = TMP / "media"
(CACHE / "hls").mkdir(parents=True, exist_ok=True)
MEDIA.mkdir(parents=True, exist_ok=True)
app.CACHE_DIR = CACHE
config.CACHE_DIR = CACHE
config.MEDIA_ROOT = MEDIA
if hasattr(app, "MEDIA_ROOT"):
    app.MEDIA_ROOT = MEDIA
for name in ("archive", "deleted", "uploads", "uploads_tmp"):
    d = TMP / name
    d.mkdir(parents=True, exist_ok=True)
config.ARCHIVE_DIR = TMP / "archive"
config.DELETED_DIR = TMP / "deleted"

DURATION = 300          # seconds -> 5 chunks of 60s -> 4 chunk boundaries
FFMPEG = str(Path(_BIN) / "ffmpeg.exe")
FFPROBE = str(Path(_BIN) / "ffprobe.exe")

CASES = [
    ("x264_gop_1s0", "libx264", "keyint=24:min-keyint=24:scenecut=0", 24),
    ("x264_gop_2s0", "libx264", "keyint=48:min-keyint=48:scenecut=0", 24),
    ("x265_gop_3s88", "libx265", "keyint=93:min-keyint=93:scenecut=0", 93),
    ("x264_gop_5s0", "libx264", "keyint=120:min-keyint=120:scenecut=0", 24),
]


def log(msg):
    print(msg, flush=True)


def make_source(name, encoder, params, gop_frames):
    out = MEDIA / f"{name}.mkv"
    if out.is_file():
        return out
    cmd = [FFMPEG, "-y", "-v", "error",
           "-f", "lavfi", "-i", f"testsrc=size=320x240:rate=24:duration={DURATION}",
           "-f", "lavfi", "-i", f"sine=frequency=440:duration={DURATION}"]
    if encoder == "libx265":
        cmd += ["-c:v", "libx265", "-x265-params", params]
    else:
        cmd += ["-c:v", "libx264", "-x264-params", params, "-preset", "veryfast"]
    cmd += ["-c:a", "aac", "-shortest", str(out)]
    subprocess.run(cmd, check=True, capture_output=True)
    return out


def measure(playlist: Path, video_end: float, label: str, source_path=None):
    """Return the audit numbers for one produced cache."""
    text = playlist.read_text(errors="replace")
    labels = {}
    for line in text.splitlines():
        if line.startswith("#EXTINF:"):
            pending = float(line.split(":", 1)[1].rstrip(","))
        elif line.endswith(".ts") and not line.startswith("#"):
            labels[line.strip()] = pending
    total_label = sum(labels.values())
    boundaries = {c["start_seg"] for c in cts.plan_chunks(video_end)}
    all_rows = []
    for seg_name, lab in labels.items():
        seg = playlist.parent / seg_name
        if not seg.is_file():
            continue
        out = subprocess.run(
            [FFPROBE, "-v", "error", "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", str(seg)], capture_output=True, text=True, timeout=30)
        try:
            real = float(out.stdout.strip())
        except ValueError:
            real = 0.0
        idx = int(seg_name.split("_")[1].split(".")[0])
        all_rows.append({"name": seg_name, "label": lab, "real": real, "boundary": idx in boundaries})
    short = [r for r in all_rows if r["real"] > r["label"] + 0.2]
    under = sum(r["real"] - r["label"] for r in short)
    clear_segment_probe_cache()
    try:
        holes = chunk_content_holes(playlist.parent, video_end)
    except Exception as exc:
        holes = [{"hole": 0.0, "error": str(exc)}]
    try:
        deficits = chunk_content_deficits(playlist.parent, video_end, source_path=source_path)
    except Exception as exc:
        deficits = [{"missing_s": 0.0, "error": str(exc)}]
    return {
        "variant": label,
        "playlist_sum_s": round(total_label, 1),
        "video_end_s": round(video_end, 1),
        "pct": round(total_label / video_end * 100, 2) if video_end else 0.0,
        "endlist": "#EXT-X-ENDLIST" in text,
        "segments": len(all_rows),
        "mislabelled_total": len(short),
        "mislabelled_boundary": sum(1 for r in short if r["boundary"]),
        "mislabelled_non_boundary": sum(1 for r in short if not r["boundary"]),
        "understated_s": round(under, 1),
        "boundaries": len(boundaries),
        "holes": len(holes),                      # diagnostic only: boundaries carry
        "missing_s": round(sum(h.get("hole", 0.0) for h in holes), 1),   # DISCONTINUITY by design
        "deficient_chunks": len(deficits),
        "frames_missing_s": round(sum(d.get("missing_s", 0.0) for d in deficits), 1),
        "content_complete": not deficits,
    }


def run_variant(src: Path, label: str, disable_fix: bool):
    hls = CACHE / "hls" / f"{src.stem}__{label}"
    shutil.rmtree(hls, ignore_errors=True)
    hls.mkdir(parents=True, exist_ok=True)
    playlist = hls / "playlist.m3u8"

    original = cts.DualGPUTranscodeJob._verified_boundary_durations
    if disable_fix:
        cts.DualGPUTranscodeJob._verified_boundary_durations = lambda self, durations_map: {}
    try:
        job = cts.DualGPUTranscodeJob(src.name, src, hls, playlist)
        t0 = time.time()
        job._run_pipeline()
        elapsed = time.time() - t0
    finally:
        cts.DualGPUTranscodeJob._verified_boundary_durations = original

    clear_video_duration_cache()
    video_end = source_video_duration(src, fallback=0.0)
    if not playlist.is_file():
        return {"variant": label, "error": "no playlist produced", "returncode": job._returncode}
    row = measure(playlist, video_end, label, source_path=src)
    row["returncode"] = job._returncode
    row["seconds"] = round(elapsed, 1)
    return row


results = []
for name, encoder, params, gop in CASES:
    src = make_source(name, encoder, params, gop)
    for label, disable in (("unfixed", True), ("fixed", False)):
        row = run_variant(src, label, disable)
        row["case"] = name
        row["source_s"] = round(source_video_duration(src, fallback=0.0), 1)
        results.append(row)
        log(f"  {name:14} {label:8} rc={row.get('returncode')} pct={row.get('pct')} "
            f"endlist={row.get('endlist')} mislabelled={row.get('mislabelled_total')} "
            f"(boundary {row.get('mislabelled_boundary')}, non-boundary {row.get('mislabelled_non_boundary')}) "
            f"deficient_chunks={row.get('deficient_chunks')} frames_missing={row.get('frames_missing_s')}s "
            f"understated={row.get('understated_s')}s in {row.get('seconds')}s")

out = Path(r"C:\MediaServer\_gop_matrix_results.json")
out.write_text(json.dumps(results, indent=2), encoding="utf-8")
log(f"\nresults -> {out}")

fixed = [r for r in results if r.get("variant") == "fixed"]
bad = [r for r in fixed if not r.get("endlist") or (r.get("pct") or 0) < 98.0
       or r.get("mislabelled_total") or r.get("deficient_chunks")]
log(f"FIXED variants: {len(fixed)} | passing (ENDLIST, >=98%, 0 mislabelled, 0 frame deficits): "
    f"{len(fixed) - len(bad)} | failing: {len(bad)}")
for r in bad:
    log(f"  FAILING: {r.get('case')} pct={r.get('pct')} endlist={r.get('endlist')} "
        f"mislabelled={r.get('mislabelled_total')} deficient_chunks={r.get('deficient_chunks')}")
unfixed = [r for r in results if r.get("variant") == "unfixed"]
reproduced = [r for r in unfixed if (r.get("mislabelled_total") or 0) > 0 or (r.get("pct") or 0) < 98.0]
log(f"UNFIXED variants where the defect reproduced: {len(reproduced)}/{len(unfixed)} -> "
    f"{[r.get('case') for r in reproduced]}")
shutil.rmtree(TMP, ignore_errors=True)
