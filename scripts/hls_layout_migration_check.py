"""Validate the dense->strided cache migration against the REAL caches, read-only.

Each cache is hardlinked (same volume) or copied into scratch, the migration runs against
the copy, and the live directory is asserted unchanged. A clean cache (15 segments per
chunk, no overlap) must migrate by renaming; a cache whose chunk playlists overlap has
already lost the content at those boundaries and must be cleared for re-render.

Usage:  python scripts/hls_layout_migration_check.py
"""

import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, r"C:\MediaServer")
from app.services import chunk_transcode_service as cts  # noqa: E402

LIVE = Path(r"C:\MediaServer\cache\hls")


def snapshot(d: Path):
    segs = {p.name: p.stat().st_size for p in d.glob("segment_*.ts")}
    return len(segs), sum(segs.values()), sorted(segs)[:3]


def copy_cache(src: Path, dest: Path):
    dest.mkdir(parents=True, exist_ok=True)
    n = 0
    for p in sorted(src.glob("segment_*.ts")):
        os.link(p, dest / p.name)          # hardlink: no data copy, no effect on the original
        n += 1
    for p in list(src.glob("chunk_*.m3u8")) + [src / "playlist.m3u8"]:
        if p.is_file():
            shutil.copy2(p, dest / p.name)
    return n


def check_master(dest: Path):
    master = dest / "playlist.m3u8"
    if not master.is_file():
        return "no master"
    names = [l.strip() for l in master.read_text(errors="replace").splitlines()
             if l.strip().endswith(".ts")]
    missing = [n for n in names if not (dest / n).is_file()]
    return f"{len(names)} entries, {len(missing)} missing files"


def run_case(dirname, expect):
    src = LIVE / dirname
    if not src.is_dir():
        print(f"{dirname}: not found")
        return
    before = snapshot(src)
    scratch = Path(tempfile.mkdtemp(prefix="layout_"))
    dest = scratch / "hls"
    n = copy_cache(src, dest)
    job = cts.DualGPUTranscodeJob("probe.mkv", Path("probe.mkv"), dest, dest / "playlist.m3u8")
    ok = job._prepare_cache_layout()
    after_marker = (dest / ".seg_layout").read_text().strip() if (dest / ".seg_layout").is_file() else None
    remaining = sorted(p.name for p in dest.glob("segment_*.ts"))
    leftover_legacy = [n for n in remaining if not any(
        int(re.search(r"(\d+)", n).group(1)) == cid * cts.SEGMENTS_PER_CHUNK_STRIDE + k
        for cid in range(400) for k in range(cts.SEGMENTS_PER_CHUNK_STRIDE))]
    after = snapshot(src)
    print(f"{dirname}: {n} segments copied | migration={ok} marker={after_marker} | "
          f"{len(remaining)} segments remain | live unchanged={before == after} | {check_master(dest)}")
    if expect == "migrate":
        assert ok and after_marker == "stride32" and len(remaining) == n, (dirname, ok, len(remaining), n)
        assert before == after, "LIVE CACHE CHANGED"
    else:
        assert not remaining, (dirname, len(remaining))
        assert before == after, "LIVE CACHE CHANGED"
    shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    # a clean (15-per-chunk) cache must migrate; Spider-Man's overlapping one must be cleared
    clean = [d.name for d in sorted(LIVE.iterdir()) if d.is_dir() and not d.name.startswith("372fdd")]
    for name in clean[:2]:
        run_case(name, "migrate")
    run_case("372fdd0ed97c1a4b911bc5f63cdfff6412aad53cec5d6c8f2afdacf12d4eeb08", "wipe")
    print("residual .tmp files:", list(LIVE.glob("*/*.tmp"))[:3])