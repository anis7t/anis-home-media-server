"""HLS completeness ledger: for every library video, compare the cache against the video end."""
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, r"C:\MediaServer")
os.environ["PATH"] = (r"C:\Users\anis7\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg.Essentials_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.1-essentials_build\bin"
                      + os.pathsep + os.environ.get("PATH", ""))

import app.config as config  # noqa: E402
from app.services import transcode_service as ts  # noqa: E402

print(f"{'media':52} {'video_end':>10} {'playlist':>10} {'cover':>7} {'ENDLIST':>8} {'segments':>9}")
print("-" * 104)
rows = []
for path in sorted(ts.video_paths()):
    name = path.name
    video_end = ts.source_video_duration(path, fallback=0.0)
    hls = ts.hls_cache_dir(path)
    pl = hls / "playlist.m3u8"
    total = 0.0
    segs = 0
    endlist = False
    if pl.is_file():
        text = pl.read_text(encoding="utf-8", errors="replace")
        total = sum(float(m) for m in re.findall(r"#EXTINF:([0-9.]+)", text))
        segs = len(re.findall(r"^segment_\d+\.ts$", text, re.M))
        endlist = "#EXT-X-ENDLIST" in text
    cover = (total / video_end * 100) if video_end else 0.0
    rows.append((name, video_end, total, cover, endlist, segs))
    print(f"{name[:52]:52} {video_end:10.1f} {total:10.1f} {cover:6.1f}% {str(endlist):>8} {segs:9d}")

print()
incomplete = [r for r in rows if r[3] < 98.0 or not r[4]]
print(f"{len(rows)} media | complete+ENDLIST: {len(rows) - len(incomplete)} | incomplete/no-ENDLIST: {len(incomplete)}")
for name, ve, tot, cov, el, segs in incomplete:
    print(f"  NEEDS WORK: {name[:60]} coverage={cov:.1f}% endlist={el}")
