"""Filesystem, path sanitization, and HTTP range utilities."""
import mimetypes
import urllib.parse
from pathlib import Path
from flask import abort
from app import config


def safe_path(name):
    """Sanitize and resolve a relative media path across configured media roots."""
    if not name or "\0" in name:
        abort(404)
    name = urllib.parse.unquote(name)

    roots = config.get_media_roots() if hasattr(config, "get_media_roots") else [config.MEDIA_ROOT]

    # 1. Try finding existing file across active media roots
    for root in roots:
        try:
            p = (root / name).resolve()
            if (p == root or root in p.parents) and p.exists():
                return p
        except Exception:
            continue

    # 2. Try finding existing video matching filename across library
    if Path(name).suffix.lower() in config.VIDEO_EXTENSIONS:
        try:
            from app.services.media_service import video_paths
            target_name = Path(name).name
            for v in video_paths():
                if v.name == target_name:
                    return v
        except Exception:
            pass

    # 3. If not found as existing file, resolve within primary MEDIA_ROOT for write/fallback
    p = (config.MEDIA_ROOT / name).resolve()
    is_safe = (p == config.MEDIA_ROOT or config.MEDIA_ROOT in p.parents)
    if not is_safe:
        is_safe = any((p == r or r in p.parents) for r in roots)
    if not is_safe:
        abort(403)
    return p


def get_rel_path(path):
    """Compute relative POSIX path for media across all configured media roots, falling back to name."""
    p = Path(path)
    roots = config.get_media_roots() if hasattr(config, "get_media_roots") else [config.MEDIA_ROOT]
    sorted_roots = sorted(roots, key=lambda r: len(str(r)), reverse=True)
    for r in sorted_roots:
        try:
            rel = p.relative_to(r).as_posix()
            while rel.startswith('.archive/'):
                rel = rel[len('.archive/'):]
            return rel
        except ValueError:
            continue
    return p.name


def is_video(path):
    """Check if the given path is an existing file with a recognized video extension."""
    p = Path(path)
    return p.is_file() and p.suffix.lower() in config.VIDEO_EXTENSIONS


def mimetype(path):
    """Guess MIME type for a file, with fallback for Matroska (.mkv)."""
    p = Path(path)
    return mimetypes.guess_type(p.name)[0] or {
        '.mkv': 'video/x-matroska'
    }.get(p.suffix.lower(), 'application/octet-stream')


def parse_range(header, size):
    """Parse HTTP Range header and return (start, end) or 'bad' or None."""
    import re
    m = re.fullmatch(r'bytes=(\d*)-(\d*)', header.strip()) if header else None
    if not m:
        return None
    a, b = m.groups()
    if not a and not b:
        return 'bad'
    if a:
        start, end = int(a), int(b) if b else size - 1
    else:
        end = size - 1
        start = max(0, size - int(b))
    return 'bad' if start >= size or start > end else (start, min(end, size - 1))
