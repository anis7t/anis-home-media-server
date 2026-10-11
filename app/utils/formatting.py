"""String, duration, byte size, and ETA formatting utilities."""
import re
from datetime import date, datetime, timezone
from pathlib import Path


#: The canonical database timestamp rendering. SQLite's ``CURRENT_TIMESTAMP``
#: produces exactly this shape, so normalizing to it keeps the SQLite response
#: contract byte-identical while making PostgreSQL ``TIMESTAMPTZ`` values behave
#: the same way.
DB_TIMESTAMP_FORMAT = '%Y-%m-%d %H:%M:%S'

_TS_HEAD_RE = re.compile(
    r'^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})'
)


def parse_db_timestamp(value):
    """Coerce a database timestamp into a timezone-aware UTC ``datetime``.

    Accepts both backends' shapes:

    * ``str`` - SQLite's ``'YYYY-MM-DD HH:MM:SS'``, the ISO ``'T'`` separator,
      fractional seconds, and an optional UTC offset or ``Z`` suffix.
    * ``datetime`` / ``date`` - what psycopg returns for ``TIMESTAMPTZ``.

    Timezone semantics: an aware datetime is converted to UTC; a **naive**
    datetime or string is *interpreted as UTC*, matching SQLite's
    ``CURRENT_TIMESTAMP`` (always UTC) and preserving the historical behaviour of
    ``format_time_ago``. A value is never read as local time.

    Returns ``None`` when the value is absent or not a recognisable timestamp.
    """
    if value is None or isinstance(value, bool):
        return None

    if isinstance(value, datetime):
        dt = value
    elif isinstance(value, date):
        dt = datetime(value.year, value.month, value.day)
    elif isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        # Normalize the ISO 'T' separator so one parse path covers both shapes.
        if len(text) > 10 and text[10] == 'T':
            text = text[:10] + ' ' + text[11:]
        if text.endswith(('Z', 'z')):
            text = text[:-1] + '+00:00'
        try:
            dt = datetime.fromisoformat(text)
        except ValueError:
            # Fractional seconds carrying more precision than microseconds.
            head = _TS_HEAD_RE.match(text)
            if not head:
                return None
            try:
                dt = datetime.fromisoformat(head.group(1))
            except ValueError:
                return None
    else:
        return None

    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def format_db_timestamp(value, default=''):
    """Render a database timestamp as the canonical ``'YYYY-MM-DD HH:MM:SS'`` UTC string.

    This is the compatibility boundary between the two backends: callers receive
    exactly the string SQLite has always produced, so template string slicing,
    lexicographic sorting in the routes, and JSON responses behave identically on
    both backends. Returns *default* when the value is absent or unparseable.
    """
    dt = parse_db_timestamp(value)
    if dt is None:
        return default
    return dt.strftime(DB_TIMESTAMP_FORMAT)


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

