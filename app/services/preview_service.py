"""Seek-bar video-frame preview generation and caching."""
import hashlib
import subprocess
from pathlib import Path
from shutil import which

from app import config
from app.services.media_service import probe_media
from app.services.transcode_service import get_cache_dir


def get_preview_candidates(path):
    """Return all valid candidate preview directory names for a given video path across roots."""
    path = Path(path)
    candidates = set()
    try:
        st = path.stat()
        file_sig = f"{st.st_size}:{st.st_mtime_ns}"
    except OSError:
        file_sig = "0:0"

    candidates.add(hashlib.sha256(f"preview:{path.resolve()}:{file_sig}".encode()).hexdigest())

    roots = config.get_media_roots() if hasattr(config, 'get_media_roots') else [config.MEDIA_ROOT]
    sorted_roots = sorted(roots, key=lambda r: len(str(r)), reverse=True)
    rel = None
    for r in sorted_roots:
        try:
            rel = path.relative_to(r)
            break
        except ValueError:
            pass

    rel_clean = None
    if rel:
        clean_parts = [p for p in rel.parts if p != '.archive']
        if clean_parts:
            rel_clean = Path(*clean_parts)

    for root in roots:
        candidates.add(hashlib.sha256(f"preview:{(root / path.name).resolve()}:{file_sig}".encode()).hexdigest())
        if rel:
            candidates.add(hashlib.sha256(f"preview:{(root / rel).resolve()}:{file_sig}".encode()).hexdigest())
        if rel_clean:
            candidates.add(hashlib.sha256(f"preview:{(root / rel_clean).resolve()}:{file_sig}".encode()).hexdigest())
            candidates.add(hashlib.sha256(f"preview:{(root / '.archive' / rel_clean).resolve()}:{file_sig}".encode()).hexdigest())

    return candidates


def preview_dir(path):
    """Deterministic directory path for seek preview thumbnails across drive roots."""
    path = Path(path)
    cache_base = get_cache_dir() / "previews"
    try:
        st = path.stat()
        file_sig = f"{st.st_size}:{st.st_mtime_ns}"
    except OSError:
        file_sig = "0:0"

    primary_key = hashlib.sha256(f"preview:{path.resolve()}:{file_sig}".encode()).hexdigest()
    primary_dir = cache_base / primary_key

    candidates = get_preview_candidates(path)
    existing_dirs = [cache_base / c for c in candidates if (cache_base / c).is_dir()]
    if not existing_dirs:
        return primary_dir

    # Prefer existing directory with the most thumbnails
    best_dir = None
    max_thumbs = -1
    for d in existing_dirs:
        count = len(list(d.glob('*.jpg')))
        if count > max_thumbs:
            max_thumbs = count
            best_dir = d

    return best_dir or (primary_dir if primary_dir in existing_dirs else existing_dirs[0])


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
