"""Video-packet continuity inventory: every live HLS cache vs its source file.

The only label-independent way to tell "the playlist understates the movie" from "content is
genuinely missing": read every video packet PTS from the cache and from the source and compare
packet counts, span and gaps.  A clean cache has 0 gaps >0.5s; a cache that was resumed from
untrusted labels has gaps at the chunk boundaries whose labels were wrong.

Read-only: probes files, writes only its own report JSON.
    python scripts/hls_content_gap_inventory.py [--out report.json] [--workers 4]
"""
import argparse
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

_BIN = (r"C:\Users\anis7\AppData\Local\Microsoft\WinGet\Packages"
        r"\Gyan.FFmpeg.Essentials_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.1-essentials_build\bin")
if Path(_BIN).is_dir():
    os.environ["PATH"] = _BIN + os.pathsep + os.environ.get("PATH", "")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

FFPROBE = str(Path(_BIN) / "ffprobe.exe") if Path(_BIN).is_dir() else "ffprobe"
GAP_THRESHOLD = 0.5


def video_pts(path: str, timeout: int = 3600):
    out = subprocess.run(
        [FFPROBE, "-v", "error", "-select_streams", "v:0",
         "-show_entries", "packet=pts_time", "-of", "csv=p=0", path],
        capture_output=True, text=True, timeout=timeout)
    pts = []
    for line in out.stdout.splitlines():
        line = line.strip().rstrip(",")
        if not line or line == "N/A":
            continue
        try:
            pts.append(float(line))
        except ValueError:
            pass
    pts.sort()
    return pts


def scan(path: str):
    pts = video_pts(path)
    if not pts:
        return {"packets": 0, "span": 0.0, "first": 0.0, "last": 0.0, "gaps": [], "gap_total": 0.0}
    gaps = [(round(a, 3), round(b - a, 3)) for a, b in zip(pts, pts[1:]) if b - a > GAP_THRESHOLD]
    return {
        "packets": len(pts), "first": round(pts[0], 3), "last": round(pts[-1], 3),
        "span": round(pts[-1] - pts[0], 3), "gaps": gaps,
        "gap_total": round(sum(d for _, d in gaps), 3),
    }


def audit_one(path: Path):
    from app.services.transcode_service import hls_cache_dir
    row = {"media": path.name}
    try:
        cache = hls_cache_dir(path)
        row["cache_dir"] = cache.name if cache else None
        row["has_cache"] = bool(cache and (cache / "playlist.m3u8").is_file())
        if not row["has_cache"]:
            return row
        src = scan(str(path))
        hls = scan(str(cache / "playlist.m3u8"))
        row["source"] = {"packets": src["packets"], "span": src["span"], "gaps": len(src["gaps"])}
        row["hls"] = {"packets": hls["packets"], "span": hls["span"], "gaps": len(hls["gaps"]),
                      "gap_total": hls["gap_total"], "biggest": sorted(hls["gaps"], key=lambda g: -g[1])[:5]}
        row["missing_packets"] = src["packets"] - hls["packets"]
        row["verdict"] = "CLEAN" if hls["gap_total"] < 5.0 else "INCOMPLETE_CONTENT"
    except Exception as exc:  # keep the inventory going
        row["verdict"] = f"ERROR: {exc}"
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="hls_gap_inventory.json")
    ap.add_argument("--workers", type=int, default=4)
    args = ap.parse_args()

    from app.services.media_service import video_paths
    paths = list(video_paths())
    print(f"scanning {len(paths)} library items (video-packet PTS, {args.workers} at a time)...", flush=True)
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        rows = list(pool.map(audit_one, paths))

    print(f"\n{'media':52} {'src pkts':>9} {'hls pkts':>9} {'missing':>8} {'span src/hls':>20} {'gaps':>6} {'gap s':>8}  verdict")
    for r in sorted(rows, key=lambda r: -r.get("hls", {}).get("gap_total", 0)):
        if not r.get("has_cache"):
            print(f"{r['media'][:52]:52} {'-':>9} {'-':>9} {'-':>8} {'no cache':>20} {'-':>6} {'-':>8}  DIRECT/NO HLS")
            continue
        s, h = r["source"], r["hls"]
        print(f"{r['media'][:52]:52} {s['packets']:>9} {h['packets']:>9} {r['missing_packets']:>8} "
              f"{s['span']:>9.1f}/{h['span']:<10.1f} {h['gaps']:>6} {h['gap_total']:>8.1f}  {r['verdict']}")
    bad = [r for r in rows if r.get("verdict") == "INCOMPLETE_CONTENT"]
    print(f"\ncaches with missing content: {len(bad)}/{sum(1 for r in rows if r.get('has_cache'))}")
    for r in bad:
        print(f"  {r['media'][:60]}: {r['hls']['gap_total']}s missing across {r['hls']['gaps']} gaps "
              f"({r['missing_packets']} frames); biggest {r['hls']['biggest'][:3]}")
    out = Path(args.out)
    out.write_text(json.dumps(rows, indent=2), encoding="utf-8")
    print(f"\nreport -> {out.resolve()}")


if __name__ == "__main__":
    main()