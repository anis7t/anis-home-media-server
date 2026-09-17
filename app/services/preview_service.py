"""Seek-bar video-frame preview generation and caching."""
import hashlib
import subprocess
from pathlib import Path
from shutil import which

from app import config
from app.services.media_service import probe_media
from app.services.transcode_service import get_cache_dir


def preview_dir(path):
    """Return deterministic preview cache directory for a given media file across drive roots."""
    path = Path(path)
    cache_base = get_cache_dir() / "previews"
    try:
        st = path.stat()
        file_sig = f"{st.st_size}:{st.st_mtime_ns}"
    except OSError:
        file_sig = "0:0"

    primary_key = hashlib.sha256(f"preview:{path.resolve()}:{file_sig}".encode()).hexdigest()
    primary_dir = cache_base / primary_key
    if primary_dir.is_dir():
        return primary_dir

    roots = config.get_media_roots() if hasattr(config, 'get_media_roots') else [config.MEDIA_ROOT]
    rel = None
    for r in roots:
        try:
            rel = path.relative_to(r)
            break
        except ValueError:
            pass
    for root in roots:
        alt_path = ((root / rel) if rel else (root / path.name)).resolve()
        alt_key = hashlib.sha256(f"preview:{alt_path}:{file_sig}".encode()).hexdigest()
        alt_dir = cache_base / alt_key
        if alt_dir.is_dir():
            return alt_dir

    return primary_dir


def preview_meta(path):
    """Calculate sampling interval, thumbnail count, and preview directory."""
    path = Path(path)
    try:
        data = probe_media(path)
        format_data = data.get("format", {})
        duration = float(format_data.get("duration") or 0)
        if duration <= 0:
            for s in data.get("streams", []):
                if s.get("codec_type") == "video" and s.get("duration"):
                    duration = float(s["duration"])
                    break
    except (TypeError, ValueError, OSError):
        return None
    if duration <= 0:
        return None
    interval = 5.0 if duration < 1800 else 10.0 if duration < 7200 else 15.0
    count = max(1, int((duration - 0.001) // interval) + 1)
    return {
        "duration": duration,
        "interval": interval,
        "count": count,
        "directory": preview_dir(path),
    }


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
    if target.is_file() and target.stat().st_size > 0:
        return target

    timestamp = min(max(meta["duration"] - 0.05, 0.0), index * meta["interval"])
    ffmpeg = getattr(config, "FFMPEG_BIN", None) or which("ffmpeg") or "ffmpeg"
    temporary = target.with_suffix(".part.jpg")
    try:
        subprocess.run(
            [
                ffmpeg,
                "-hide_banner",
                "-loglevel",
                "error",
                "-ss",
                f"{timestamp:.3f}",
                "-i",
                str(path),
                "-frames:v",
                "1",
                "-vf",
                "scale=320:-2",
                "-q:v",
                "5",
                "-y",
                str(temporary),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
        if temporary.is_file() and temporary.stat().st_size > 0:
            temporary.replace(target)
            return target
    except (OSError, subprocess.SubprocessError):
        temporary.unlink(missing_ok=True)
    return None
