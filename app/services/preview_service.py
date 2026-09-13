"""Seek-bar thumbnail preview generation and cached delivery helpers."""
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


def _duration(path):
    try:
        return float(probe_media(path).get("format", {}).get("duration") or 0)
    except (TypeError, ValueError, OSError):
        return 0.0


def ensure_preview(path):
    """Generate a compact VTT + JPEG thumbnail set on first request."""
    path = Path(path)
    directory = preview_dir(path)
    vtt = directory / "preview.vtt"
    if vtt.is_file() and vtt.stat().st_size:
        return directory
    ffmpeg = config.FFMPEG_BIN if hasattr(config, "FFMPEG_BIN") else "ffmpeg"
    duration = _duration(path)
    if duration <= 0:
        return None
    directory.mkdir(parents=True, exist_ok=True)
    interval = 10.0 if duration < 3600 else 15.0
    count = int(duration // interval) + 1
    for idx in range(count):
        t = min(duration, idx * interval)
        out = directory / f"thumb_{idx:05d}.jpg"
        if out.is_file() and out.stat().st_size:
            continue
        try:
            subprocess.run([
                ffmpeg, "-hide_banner", "-loglevel", "error", "-ss", f"{t:.3f}",
                "-i", str(path), "-frames:v", "1", "-vf", "scale=320:-2", "-q:v", "5", "-y", str(out)
            ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
        except (OSError, subprocess.SubprocessError):
            return None
    lines = ["WEBVTT", ""]
    for idx in range(count):
        start = idx * interval
        end = min(duration, start + interval)
        if start >= duration:
            break
        def ts(value):
            value = max(0.0, value)
            h = int(value // 3600)
            m = int((value % 3600) // 60)
            s = value % 60
            return f"{h:02d}:{m:02d}:{s:06.3f}"
        lines += [f"{ts(start)} --> {ts(end)}", f"/seek-preview/{path.name}/thumb_{idx:05d}.jpg", ""]
    vtt.write_text("\n".join(lines), encoding="utf-8")
    return directory
