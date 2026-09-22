"""Snapshot the host's live data (library files, production DB rows, transcode cache) so a
test-suite run can be proven not to touch any of it. Prints one line per data set.
"""
import hashlib
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, r"C:\MediaServer")

from app import config  # noqa: E402

roots = [Path(r) for r in config.get_media_roots()]
files = 0
h = hashlib.sha256()
for root in roots:
    if not root.is_dir():
        continue
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        try:
            st = p.stat()
        except OSError:
            continue
        h.update(f"{p}|{st.st_size}".encode())
        files += 1
print(f"  library: {files} files  hash={h.hexdigest()[:16]}")

con = sqlite3.connect(r"C:\MediaServer\media.db")
rows = list(con.execute("SELECT filename, title, tmdb_id FROM movies ORDER BY filename"))
print(f"  prod DB: {len(rows)} movie rows  hash={hashlib.sha256(repr(rows).encode()).hexdigest()[:16]}")

cache = Path(r"C:\MediaServer\cache\hls")
dirs = sorted(p.name for p in cache.iterdir() if p.is_dir()) if cache.is_dir() else []
segs = sum(1 for _ in cache.rglob("*.ts")) if cache.is_dir() else 0
print(f"  live cache: {len(dirs)} dirs, {segs} segments  hash={hashlib.sha256(repr(dirs).encode()).hexdigest()[:16]}")