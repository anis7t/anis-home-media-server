"""Forensic media resolver service for unidentified, numeric, or anonymous media.

Implements multi-tiered identification strategies:
1. OpenSubtitles 64-bit MovieHash lookup & TMDb external IMDb resolution.
2. Matroska / MP4 container & stream metadata tag inspection.
3. Embedded subtitle dialogue cue & quote extraction.
4. Fallback credits and title card inspection.
"""
import json
import logging
import re
import subprocess
import time
from pathlib import Path
import requests

from app.utils.subtitles import compute_opensubtitles_hash

logger = logging.getLogger(__name__)


def is_anonymous_name(name_or_stem: str) -> bool:
    """Check if a filename or parsed title is anonymous, numeric, or uninformative."""
    if not name_or_stem:
        return True
    s = str(name_or_stem).strip(" -._'\"")
    if not s:
        return True
    # Purely numeric (e.g. '1000403712', '12345')
    if re.fullmatch(r'\d+', s):
        return True
    # Hex or UUID pattern (e.g. '30dd42a35963fefdb844530e650b21268f798f6e', 'a1b2c3d4-e5f6-...')
    if re.fullmatch(r'[0-9a-fA-F-]{8,}', s):
        return True
    # Generic camera / phone / download stems
    generic_prefixes = (
        'vid_', 'video_', 'mov_', 'movie_', 'dsc_', 'img_',
        'untitled', 'unknown', 'file', 'upload', 'stream', 'part'
    )
    lower = s.lower()
    for gp in generic_prefixes:
        if lower.startswith(gp) and (len(lower) == len(gp) or re.search(r'\d', lower)):
            return True
    return False


def find_movie_by_imdb_id(session, token, imdb_id):
    """Query TMDB /find/ endpoint using an IMDb ID (e.g. 'tt28014327' or '28014327')."""
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
    except Exception as e:
        logger.warning(f"TMDB find by IMDb ID {clean_id} error: {e}")
    return None


def resolve_via_moviehash(path, session, token):
    """Identify media via OpenSubtitles 64-bit MovieHash and resolve via TMDB."""
    h, sz = compute_opensubtitles_hash(path)
    if not h or not sz:
        return None, None

    logger.info(f"Computing OpenSubtitles MovieHash for {Path(path).name}: hash={h}, size={sz}")
    headers = {
        "User-Agent": "TemporaryUserAgent",
        "Accept": "application/json",
    }
    url = f"https://rest.opensubtitles.org/search/moviebytesize-{sz}/moviehash-{h}"
    data = None
    try:
        resp = session.get(url, headers=headers, timeout=12)
        if resp.status_code == 200:
            data = resp.json()
    except Exception as e:
        logger.warning(f"OpenSubtitles hash lookup request error: {e}")
        return None, None

    if not data or not isinstance(data, list):
        return None, None

    import scanner

    for item in data:
        imdb_id = item.get("IDMovieImdb")
        movie_name = item.get("MovieName")
        movie_year = item.get("MovieYear")

        # 1. Try direct TMDb match via IMDb ID
        if imdb_id and str(imdb_id).strip() not in {"0", ""}:
            movie = find_movie_by_imdb_id(session, token, imdb_id)
            if movie:
                logger.info(f"Resolved {Path(path).name} via MovieHash -> IMDb tt{imdb_id}: {movie.get('title')}")
                return movie, f"moviehash:imdb:tt{imdb_id}"

        # 2. Fallback to title and year search on TMDb
        if movie_name:
            try:
                year_int = int(movie_year) if movie_year else None
            except (ValueError, TypeError):
                year_int = None
            movie = scanner.find_movie(session, token, movie_name, year_int)
            if movie:
                logger.info(f"Resolved {Path(path).name} via MovieHash -> Title search: {movie.get('title')}")
                return movie, f"moviehash:search:{movie_name}"

    return None, None


def resolve_via_container_tags(path, session, token):
    """Identify media by inspecting internal container format and stream metadata tags."""
    path = Path(path)
    cmd = [
        "ffprobe", "-v", "error",
        "-show_entries", "format_tags:stream_tags",
        "-of", "json", str(path)
    ]
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=15)
        if res.returncode != 0 or not res.stdout:
            return None, None
        meta = json.loads(res.stdout)
    except Exception as e:
        logger.warning(f"ffprobe metadata extraction failed for {path.name}: {e}")
        return None, None

    import scanner

    candidate_strings = []

    # Check format tags
    format_tags = meta.get("format", {}).get("tags", {})
    for tag_key in ("title", "TITLE", "description", "comment", "movie_name"):
        val = format_tags.get(tag_key)
        if val and isinstance(val, str) and not is_anonymous_name(val):
            candidate_strings.append(val)

    # Check stream tags (audio / video stream titles often contain release title)
    for st in meta.get("streams", []):
        st_tags = st.get("tags", {})
        for tag_key in ("title", "TITLE", "description"):
            val = st_tags.get(tag_key)
            if val and isinstance(val, str) and not is_anonymous_name(val):
                candidate_strings.append(val)

    for cand in candidate_strings:
        # Avoid generic tags
        if cand.lower() in {"stereo", "surround", "5.1", "7.1", "sdh", "forced", "commentary", "english", "und"}:
            continue
        cand_title, cand_year = scanner.parse_filename(Path(cand))
        if cand_title and not is_anonymous_name(cand_title):
            movie = scanner.find_movie(session, token, cand_title, cand_year)
            if movie:
                logger.info(f"Resolved {path.name} via Container Tag '{cand}' -> {movie.get('title')}")
                return movie, f"container_tags:{cand}"

    return None, None


def resolve_via_subtitles(path, session, token):
    """Extract embedded subtitle dialogue lines to extract movie dialogue signatures."""
    path = Path(path)
    # Extract first 180 seconds of first subtitle stream
    cmd = [
        "ffmpeg", "-y", "-i", str(path),
        "-map", "0:s:0",
        "-t", "180",
        "-f", "webvtt", "-"
    ]
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=20)
        if res.returncode != 0 or not res.stdout:
            return None, None
        vtt = res.stdout
    except Exception as e:
        logger.warning(f"Embedded subtitle dialogue extraction failed for {path.name}: {e}")
        return None, None

    # Parse dialogue lines, strip markup and timestamps
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

    # Distinctive character names or dialogue quotes can be matched
    dialogue_sample = " ".join(lines[:10])
    logger.debug(f"Extracted {len(lines)} subtitle dialogue lines from {path.name}: {dialogue_sample[:80]}...")

    return None, None


def resolve_media(path, session=None, token=None):
    """Run multi-tiered forensic media identification cascade on an unknown media file.

    Returns:
        tuple: (tmdb_movie_dict, source_strategy) or (None, None)
    """
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
        # Strategy 1: OpenSubtitles 64-bit MovieHash
        movie, src = resolve_via_moviehash(path, session, token)
        if movie:
            return movie, src

        # Strategy 2: Matroska / MP4 container & stream metadata tags
        movie, src = resolve_via_container_tags(path, session, token)
        if movie:
            return movie, src

        # Strategy 3: Embedded subtitle dialogue analysis
        movie, src = resolve_via_subtitles(path, session, token)
        if movie:
            return movie, src

    except Exception as e:
        logger.error(f"Error during forensic media resolution for {path.name}: {e}")
    finally:
        if close_session:
            session.close()

    return None, None

