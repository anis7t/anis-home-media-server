"""String, duration, byte size, and ETA formatting utilities."""
import re
from pathlib import Path


def clean_title(name):
    """Strip extension, release tags, dots/underscores to derive a clean movie title."""
    name = Path(name).stem
    t = re.sub(
        r'(?i)\b(1080p|720p|2160p|4k|bluray|x264|x265|hevc|web-dl|dvdrip|aac|mp3|brrip)\b.*',
        '',
        re.sub(r'[\._]', ' ', name)
    ).strip()
    return re.sub(r'\s+', ' ', t).title() or name


def format_runtime_display(minutes):
    """Format minutes into human-readable duration, e.g. '2 hr 5 min' or '45 min'."""
    if not minutes:
        return ""
    try:
        m = int(minutes)
    except (ValueError, TypeError):
        return ""
    if m <= 0:
        return ""
    hours = m // 60
    rem = m % 60
    if hours > 0 and rem > 0:
        return f"{hours} hr {rem} min"
    elif hours > 0:
        return f"{hours} hr"
    return f"{rem} min"


def format_bytes_display(size_bytes):
    """Format byte integer into human-readable size, e.g. '15 MB' or '2.1 GB'."""
    if not size_bytes or size_bytes <= 0:
        return ""
    size = float(size_bytes)
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size < 1024.0 or unit == 'TB':
            if unit in ['B', 'KB']:
                return f"{int(size)} {unit}"
            return f"{size:.1f} {unit}"
        size /= 1024.0
    return ""


def format_eta(seconds):
    """Format remaining seconds into human readable ETA string."""
    if seconds is None or not (seconds == seconds):  # NaN check
        return "Calculating..."
    rem = int(max(0, seconds))
    rem_h = rem // 3600
    rem_m = (rem % 3600) // 60
    rem_s = rem % 60
    if rem_h > 0:
        return f"{rem_h}h {rem_m}m"
    elif rem_m > 0:
        return f"{rem_m}m {rem_s}s"
    return f"{rem_s}s"

