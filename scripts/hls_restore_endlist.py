"""Restore ENDLIST on caches the buggy frame audit stripped, using the fixed measurement.

The audit's per-chunk window walk assumed the strided grid; on a legacy dense cache it read a
neighbour's segments (or the near-empty tail) and reported complete caches as missing 13-38s of
video, stripping ENDLIST from them. This restores ENDLIST for every cache the corrected
measurement clears, and leaves genuinely short caches (Spider-Man) without it so they re-render.

Reads the caches; writes only the playlist's ENDLIST line, atomically, with one backup.
"""
import logging
import os
import sys
from pathlib import Path

sys.path.insert(0, r"C:\MediaServer")
for cand in Path(r"C:\Users\anis7\AppData\Local\Microsoft\WinGet\Packages").glob("Gyan.FFmpeg*/**/bin/ffmpeg.exe"):
    os.environ["PATH"] = str(cand.parent) + os.pathsep + os.environ["PATH"]

logging.disable(logging.WARNING)

from app.services import transcode_service as ts
from app.services.media_service import video_paths
from app.services.transcode_service import hls_cache_dir, source_video_duration

restored, kept, skipped = [], [], []
for media in sorted(video_paths(), key=lambda p: p.name):
    cache = hls_cache_dir(media)
    playlist = cache / "playlist.m3u8"
    if not playlist.is_file():
        continue
    text = playlist.read_text(encoding="utf-8", errors="replace")
    if "#EXT-X-ENDLIST" in text:
        skipped.append((media.name, "already complete"))
        continue
    total = source_video_duration(media, fallback=0.0) or 0.0
    if total <= 0:
        kept.append((media.name, "no measurable source duration"))
        continue
    deficits = ts.chunk_content_deficits(cache, total, source_path=media)
    if deficits:
        missing = round(sum(d["missing_s"] for d in deficits), 1)
        kept.append((media.name, f"genuinely short by {missing}s -> must re-render"))
        continue
    backup = cache / "playlist.m3u8.pre-restore.bak"
    if not backup.exists():
        backup.write_bytes(playlist.read_bytes())
    tmp = playlist.with_suffix(".tmp")
    tmp.write_text(text.rstrip() + "\n#EXT-X-ENDLIST\n", encoding="utf-8")
    os.replace(tmp, playlist)
    restored.append(media.name)

print("\nRESTORED ENDLIST (measured complete, was stripped by the buggy audit):")
for n in restored:
    print("  +", n)
print("\nLEFT WITHOUT ENDLIST (genuinely short of frames):")
for n, why in kept:
    print("  -", n, "|", why)
print(f"\nskipped (already had ENDLIST): {len(skipped)}")
print(f"restored {len(restored)} / kept {len(kept)} / skipped {len(skipped)}")