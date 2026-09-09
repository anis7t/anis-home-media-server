"""Filesystem, path sanitization, and HTTP range utilities."""
import mimetypes
import urllib.parse
from pathlib import Path
from flask import abort
from app import config


def safe_path(name):
    """Sanitize and resolve a relative media path within MEDIA_ROOT."""
    if not name or "\0" in name:
        abort(404)
    name = urllib.parse.unquote(name)
    p = (config.MEDIA_ROOT / name).resolve()
    if p != config.MEDIA_ROOT and config.MEDIA_ROOT not in p.parents:
        abort(403)
    return p


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
