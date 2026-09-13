"""Seek-bar video-frame preview generation and caching."""
import hashlib
import subprocess
from pathlib import Path

from app import config
from app.services.media_service import probe_media
from app.services.transcode_service import get_cache_dir


def preview_dir(path):
    path = Path(path)
    key = hashlib.sha256(f"preview:{path}:{path.stat().st_size}:{path.stat().st_mtime_ns}".encode()).hexdigest()
    return get_cache_dir() / "previews" / key


def preview_meta(path):
    path = Path(path)
    try:
        duration = float(probe_media(path).get("format", {}).get("duration") or 0)
    except (TypeError, ValueError, OSError):
        return None
    if duration <= 0:
        return None
    interval = 5.0 if duration < 1800 else 10.0 if duration < 7200 else 15.0
    count = max(1, int((duration - 0.001) // interval) + 1)
    return {"duration": duration, "interval": interval, "count": count, "directory": preview_dir(path)}


def ensure_preview_thumbnail(path, index):
    """Generate exactly one cached JPEG frame on demand."""
    path = Path(path)
    meta = preview_meta(path)
    if not meta:
        return None
    try:
        index = max(0, min(int(index), meta["count"] - 1))
    except (TypeError, ValueError):
        return None
    directory = meta["directory"]
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / f"thumb_{index:05d}.jpg"
    if target.is_file() and target.stat().st_size:
        return target
    timestamp = min(max(meta["duration"] - 0.05, 0.0), index * meta["interval"])
    ffmpeg = getattr(config, "FFMPEG_BIN", "ffmpeg")
    temporary = target.with_suffix(".part.jpg")
    try:
        subprocess.run([
            ffmpeg, "-hide_banner", "-loglevel", "error", "-ss", f"{timestamp:.3f}",
            "-i", str(path), "-frames:v", "1", "-vf", "scale=320:-2", "-q:v", "5", "-y", str(temporary)
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
        if temporary.is_file() and temporary.stat().st_size:
            temporary.replace(target)
            return target
    except (OSError, subprocess.SubprocessError):
        temporary.unlink(missing_ok=True)
    return None
