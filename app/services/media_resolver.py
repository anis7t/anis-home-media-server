"""Forensic media resolver service for unidentified, numeric, or anonymous media.

Identification is deliberately conservative:
1. Container / stream metadata is checked before third-party MovieHash data.
2. OpenSubtitles MovieHash is only accepted when the matched TMDB title has a
   runtime compatible with the actual video duration.
3. Embedded subtitle extraction is retained as a future evidence source but
   does not silently invent a match when no reliable lookup is available.

The important rule is: an uncertain identification must remain unresolved
rather than attaching the wrong poster, subtitles, and TMDB record.
"""
import difflib
import json
import logging
import re
import subprocess
from pathlib import Path

import requests

from app.utils.subtitles import compute_opensubtitles_hash

logger = logging.getLogger(__name__)


GENERIC_TAG_VALUES = {
    "stereo", "surround", "5.1", "7.1", "sdh", "forced",
    "commentary", "english", "und",
}

RUNTIME_TOLERANCE_SECONDS = 180
RUNTIME_TOLERANCE_RATIO = 0.12


def is_anonymous_name(name_or_stem: str) -> bool:
    """Check if a filename or parsed title is anonymous, numeric, or uninformative."""
    if not name_or_stem:
        return True
    s = str(name_or_stem).strip(" -._'\"")
    if not s:
        return True
    if re.fullmatch(r"\d+", s):
        return True
    if re.fullmatch(r"[0-9a-fA-F-]{8,}", s):
        return True

    generic_prefixes = (
        "vid_", "video_", "mov_", "movie_", "dsc_", "img_",
        "untitled", "unknown", "file", "upload", "stream", "part",
    )
    lower = s.lower()
    for gp in generic_prefixes:
        if lower.startswith(gp) and (len(lower) == len(gp) or re.search(r"\d", lower)):
            return True
    return False


def _normalize_title(value: str) -> str:
    value = re.sub(r"[^a-z0-9]+", " ", str(value or "").lower())
    return re.sub(r"\s+", " ", value).strip()


def _title_similarity(left: str, right: str) -> float:
    a = _normalize_title(left)
    b = _normalize_title(right)
    if not a or not b:
        return 0.0
    if a == b:
        return 1.0
    a_tokens = set(a.split())
    b_tokens = set(b.split())
    token_score = len(a_tokens & b_tokens) / max(len(a_tokens | b_tokens), 1)
    sequence_score = difflib.SequenceMatcher(None, a, b).ratio()
    return max(token_score, sequence_score)


def _probe_duration_seconds(path: Path):
    """Return media duration in seconds using ffprobe, or None on failure."""
    try:
        result = subprocess.run(
            [
                "ffprobe", "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=15,
            check=False,
        )
        value = float((result.stdout or "").strip())
        return value if value > 0 else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def _runtime_compatible(path: Path, movie: dict, session, token) -> bool:
    """Validate a MovieHash candidate against the actual file duration."""
    import scanner

    local_duration = _probe_duration_seconds(path)
    if local_duration is None:
        logger.warning("Rejecting MovieHash candidate for %s: local duration unavailable", path.name)
        return False

    try:
        tmdb_id = movie.get("id")
        if not tmdb_id:
            return False
        details = scanner.get_movie_details(session, token, tmdb_id)
        tmdb_runtime = details.get("runtime")
        if not tmdb_runtime or tmdb_runtime <= 0:
            logger.warning("Rejecting MovieHash candidate %s: TMDB runtime unavailable", movie.get("title"))
            return False
    except Exception as exc:
        logger.warning("Rejecting MovieHash candidate %s: TMDB runtime check failed: %s", movie.get("title"), exc)
        return False

    expected = float(tmdb_runtime) * 60.0
    tolerance = max(RUNTIME_TOLERANCE_SECONDS, expected * RUNTIME_TOLERANCE_RATIO)
    delta = abs(local_duration - expected)
    compatible = delta <= tolerance
    logger.info(
        "MovieHash runtime check for %s -> %s: file=%.1fs tmdb=%ss delta=%.1fs tolerance=%.1fs compatible=%s",
        path.name, movie.get("title"), local_duration, tmdb_runtime, delta, tolerance, compatible,
    )
    return compatible


def find_movie_by_imdb_id(session, token, imdb_id):
    """Query TMDB /find/ endpoint using an IMDb ID."""
    if not token or not imdb_id:
        return None
    import scanner

    clean_id = f"tt{str(imdb_id).lstrip('t')}"
    url = f"{scanner.TMDB_API}/find/{clean_id}"
    try:
        data = scanner.tmdb_get(session, token, url, params={"external_source": "imdb_id"})
        movie_results = data.get("movie_results", [])
        if movie_results:
            return movie_results[0]
    except Exception as exc:
        logger.warning("TMDB find by IMDb ID %s error: %s", clean_id, exc)
    return None


def resolve_via_moviehash(path, session, token):
    """Identify media via OpenSubtitles MovieHash, with runtime validation."""
    path = Path(path)
    h, sz = compute_opensubtitles_hash(path)
    if not h or not sz:
        return None, None

    logger.info("Computing OpenSubtitles MovieHash for %s: hash=%s, size=%s", path.name, h, sz)
    headers = {"User-Agent": "TemporaryUserAgent", "Accept": "application/json"}
    url = f"https://rest.opensubtitles.org/search/moviebytesize-{sz}/moviehash-{h}"

    try:
        resp = session.get(url, headers=headers, timeout=12)
        if resp.status_code != 200:
            return None, None
        data = resp.json()
    except Exception as exc:
        logger.warning("OpenSubtitles hash lookup request error: %s", exc)
        return None, None

    if not data or not isinstance(data, list):
        return None, None

    import scanner

    for item in data:
        imdb_id = item.get("IDMovieImdb")
        movie_name = item.get("MovieName")
        movie_year = item.get("MovieYear")
        movie = None
        source = None

        if imdb_id and str(imdb_id).strip() not in {"0", ""}:
            movie = find_movie_by_imdb_id(session, token, imdb_id)
            source = f"moviehash:imdb:tt{imdb_id}"

        if movie is None and movie_name:
            try:
                year_int = int(movie_year) if movie_year else None
            except (ValueError, TypeError):
                year_int = None
            movie = scanner.find_movie(session, token, movie_name, year_int)
            source = f"moviehash:search:{movie_name}"

        if not movie:
            continue
        if not _runtime_compatible(path, movie, session, token):
            logger.warning("Ignoring MovieHash candidate for %s: %s", path.name, movie.get("title"))
            continue

        logger.info("Resolved %s via validated MovieHash -> %s", path.name, movie.get("title"))
        return movie, source

    logger.warning("No validated MovieHash match for %s; leaving media unresolved", path.name)
    return None, None


def resolve_via_container_tags(path, session, token):
    """Identify media using internal container and stream metadata tags."""
    path = Path(path)
    cmd = [
        "ffprobe", "-v", "error",
        "-show_entries", "format_tags:stream_tags",
        "-of", "json", str(path),
    ]
    try:
        res = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=15,
            check=False,
        )
        if res.returncode != 0 or not res.stdout:
            return None, None
        meta = json.loads(res.stdout)
    except Exception as exc:
        logger.warning("ffprobe metadata extraction failed for %s: %s", path.name, exc)
        return None, None

    import scanner

    candidate_strings = []
    format_tags = meta.get("format", {}).get("tags", {})
    for tag_key in ("title", "TITLE", "description", "comment", "movie_name"):
        val = format_tags.get(tag_key)
        if isinstance(val, str) and val and not is_anonymous_name(val):
            candidate_strings.append(val)

    for stream in meta.get("streams", []):
        stream_tags = stream.get("tags", {})
        for tag_key in ("title", "TITLE", "description"):
            val = stream_tags.get(tag_key)
            if isinstance(val, str) and val and not is_anonymous_name(val):
                candidate_strings.append(val)

    seen = set()
    for candidate in candidate_strings:
        candidate_key = candidate.strip().lower()
        if candidate_key in seen or candidate_key in GENERIC_TAG_VALUES:
            continue
        seen.add(candidate_key)

        cand_title, cand_year = scanner.parse_filename(Path(candidate))
        if not cand_title or is_anonymous_name(cand_title):
            continue

        movie = scanner.find_movie(session, token, cand_title, cand_year)
        if not movie:
            continue

        result_title = movie.get("title") or movie.get("original_title") or ""
        similarity = _title_similarity(cand_title, result_title)
        if similarity < 0.65:
            logger.warning(
                "Ignoring weak container-tag match for %s: tag=%r result=%r similarity=%.2f",
                path.name, cand_title, result_title, similarity,
            )
            continue

        logger.info(
            "Resolved %s via Container Tag %r -> %s (similarity %.2f)",
            path.name, candidate, result_title, similarity,
        )
        return movie, f"container_tags:{candidate}"

    return None, None


def resolve_via_subtitles(path, session, token):
    """Extract embedded subtitle dialogue without inventing a TMDB match."""
    path = Path(path)
    cmd = ["ffmpeg", "-y", "-i", str(path), "-map", "0:s:0", "-t", "180", "-f", "webvtt", "-"]
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=20, check=False)
        if res.returncode != 0 or not res.stdout:
            return None, None
        vtt = res.stdout
    except Exception as exc:
        logger.warning("Embedded subtitle extraction failed for %s: %s", path.name, exc)
        return None, None

    lines = []
    for line in vtt.splitlines():
        line = line.strip()
        if not line or line.startswith("WEBVTT") or "-->" in line or line.isdigit():
            continue
        clean_line = re.sub(r"<[^>]+>", "", line).strip()
        clean_line = re.sub(r"^[-–—]\s*", "", clean_line)
        if clean_line and len(clean_line) > 10:
            lines.append(clean_line)

    if not lines:
        return None, None

    logger.debug(
        "Extracted %d subtitle dialogue lines from %s: %s...",
        len(lines), path.name, " ".join(lines[:10])[:160],
    )
    return None, None


def resolve_media(path, session=None, token=None):
    """Run conservative multi-tiered forensic identification."""
    path = Path(path)
    import scanner

    close_session = False
    if session is None:
        session = requests.Session()
        close_session = True
    if token is None:
        token = scanner.load_token()

    if not token:
        logger.warning("resolve_media: TMDB token missing, cannot resolve.")
        if close_session:
            session.close()
        return None, None

    try:
        movie, src = resolve_via_container_tags(path, session, token)
        if movie:
            return movie, src

        movie, src = resolve_via_moviehash(path, session, token)
        if movie:
            return movie, src

        movie, src = resolve_via_subtitles(path, session, token)
        if movie:
            return movie, src
    except Exception as exc:
        logger.error("Error during forensic media resolution for %s: %s", path.name, exc)
    finally:
        if close_session:
            session.close()

    logger.warning("No reliable forensic match for %s", path.name)
    return None, None
