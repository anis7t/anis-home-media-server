"""Conservative forensic identification for anonymous media files."""
import difflib
import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import requests

from app.utils.subtitles import compute_opensubtitles_hash

logger = logging.getLogger(__name__)

GENERIC_TAG_VALUES = {"stereo", "surround", "5.1", "7.1", "sdh", "forced", "commentary", "english", "und"}
RUNTIME_TOLERANCE_SECONDS = 180
RUNTIME_TOLERANCE_RATIO = 0.12


def is_anonymous_name(name_or_stem: str) -> bool:
    if not name_or_stem:
        return True
    s = str(name_or_stem).strip(" -._'\"")
    if not s or re.fullmatch(r"\d+", s) or re.fullmatch(r"[0-9a-fA-F-]{8,}", s):
        return True
    prefixes = ("vid_", "video_", "mov_", "movie_", "dsc_", "img_", "untitled", "unknown", "file", "upload", "stream", "part")
    lower = s.lower()
    return any(lower.startswith(p) and (len(lower) == len(p) or re.search(r"\d", lower)) for p in prefixes)


def _normalize_title(value):
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9]+", " ", str(value or "").lower())).strip()


def _title_similarity(left, right):
    a, b = _normalize_title(left), _normalize_title(right)
    if not a or not b:
        return 0.0
    if a == b:
        return 1.0
    ta, tb = set(a.split()), set(b.split())
    token_score = len(ta & tb) / max(len(ta | tb), 1)
    return max(token_score, difflib.SequenceMatcher(None, a, b).ratio())


def _probe_duration_seconds(path):
    try:
        result = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", str(path)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=15, check=False)
        value = float((result.stdout or "").strip())
        return value if value > 0 else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def _runtime_score(path, movie, session, token):
    import scanner
    local = _probe_duration_seconds(path)
    if local is None or not movie.get("id"):
        return 0.0
    try:
        runtime = scanner.get_movie_details(session, token, movie["id"]).get("runtime")
        if not runtime:
            return 0.0
    except Exception:
        return 0.0
    expected = float(runtime) * 60
    delta = abs(local - expected)
    tolerance = max(RUNTIME_TOLERANCE_SECONDS, expected * RUNTIME_TOLERANCE_RATIO)
    if delta > tolerance:
        return 0.0
    ratio = delta / max(expected, 1.0)
    return max(0.0, 2.0 - (ratio / max(RUNTIME_TOLERANCE_RATIO, 0.001)))


def find_movie_by_imdb_id(session, token, imdb_id):
    if not token or not imdb_id:
        return None
    import scanner
    clean_id = f"tt{str(imdb_id).lstrip('t')}"
    try:
        data = scanner.tmdb_get(session, token, f"{scanner.TMDB_API}/find/{clean_id}", params={"external_source": "imdb_id"})
        results = data.get("movie_results", [])
        return results[0] if results else None
    except Exception as exc:
        logger.warning("TMDB find by IMDb ID %s failed: %s", clean_id, exc)
        return None


def _search_candidate(session, token, title, year=None):
    import scanner
    if not title or is_anonymous_name(title):
        return None
    movie = scanner.find_movie(session, token, title, year)
    if not movie:
        return None
    result_title = movie.get("title") or movie.get("original_title") or ""
    similarity = _title_similarity(title, result_title)
    if similarity < 0.65:
        return None
    return movie


def _collect_moviehash(path, session, token):
    h, size = compute_opensubtitles_hash(path)
    if not h or not size:
        return []
    url = f"https://rest.opensubtitles.org/search/moviebytesize-{size}/moviehash-{h}"
    try:
        resp = session.get(url, headers={"User-Agent": "TemporaryUserAgent", "Accept": "application/json"}, timeout=12)
        if resp.status_code != 200:
            return []
        data = resp.json()
    except Exception as exc:
        logger.warning("OpenSubtitles hash lookup failed: %s", exc)
        return []
    if not isinstance(data, list):
        return []

    import scanner
    candidates = {}
    for item in data:
        movie = None
        source = None
        imdb_id = item.get("IDMovieImdb")
        if imdb_id and str(imdb_id).strip() not in {"0", ""}:
            movie = find_movie_by_imdb_id(session, token, imdb_id)
            source = f"moviehash:imdb:tt{imdb_id}"
        if movie is None and item.get("MovieName"):
            try:
                year = int(item.get("MovieYear")) if item.get("MovieYear") else None
            except (TypeError, ValueError):
                year = None
            movie = _search_candidate(session, token, item.get("MovieName"), year)
            source = f"moviehash:search:{item.get('MovieName')}"
        if not movie:
            continue
        runtime_score = _runtime_score(path, movie, session, token)
        if runtime_score <= 0:
            continue
        key = movie.get("id")
        rec = candidates.setdefault(key, {"movie": movie, "sources": set(), "count": 0, "runtime_score": runtime_score})
        rec["sources"].add(source)
        rec["count"] += 1
        rec["runtime_score"] = max(rec["runtime_score"], runtime_score)
    return list(candidates.values())


def resolve_via_moviehash(path, session, token):
    """Return the strongest validated MovieHash candidate without blindly trusting the first result."""
    candidates = _collect_moviehash(path, session, token)
    if not candidates:
        return None, None
    candidates.sort(key=lambda c: (c["count"] > 1, c["runtime_score"], c["count"]), reverse=True)
    best = candidates[0]
    return best["movie"], next(iter(best["sources"]))


def resolve_via_container_tags(path, session, token):
    """Resolve using embedded format/stream title metadata."""
    try:
        result = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format_tags:stream_tags", "-of", "json", str(path)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=15, check=False)
        if result.returncode != 0 or not result.stdout:
            return None, None
        meta = json.loads(result.stdout)
    except Exception as exc:
        logger.warning("ffprobe metadata extraction failed: %s", exc)
        return None, None
    import scanner
    values = []
    for key in ("title", "TITLE", "description", "comment", "movie_name"):
        value = meta.get("format", {}).get("tags", {}).get(key)
        if isinstance(value, str) and value and not is_anonymous_name(value):
            values.append(value)
    for stream in meta.get("streams", []):
        tags = stream.get("tags", {}) or {}
        for key in ("title", "TITLE", "description"):
            value = tags.get(key)
            if isinstance(value, str) and value and not is_anonymous_name(value):
                values.append(value)
    seen = set()
    best = None
    for value in values:
        cleaned = value.strip()
        if cleaned.lower() in GENERIC_TAG_VALUES or cleaned.lower() in seen:
            continue
        seen.add(cleaned.lower())
        title, year = scanner.parse_filename(Path(cleaned))
        movie = _search_candidate(session, token, title, year)
        if not movie:
            continue
        similarity = _title_similarity(title, movie.get("title") or movie.get("original_title"))
        if best is None or similarity > best[0]:
            best = (similarity, movie, cleaned)
    if best and best[0] >= 0.65:
        return best[1], f"container_tags:{best[2]}"
    return None, None


def resolve_via_sidecar_subtitles(path, session, token):
    """Use meaningful sidecar subtitle filenames as independent title evidence."""
    import scanner
    suffixes = {".srt", ".vtt", ".ass", ".ssa"}
    try:
        files = sorted(path.parent.iterdir())
    except OSError:
        return None, None
    best = None
    for sidecar in files:
        if not sidecar.is_file() or sidecar.suffix.lower() not in suffixes:
            continue
        title, year = scanner.parse_filename(sidecar)
        if is_anonymous_name(title) or title.lower() == path.stem.lower():
            continue
        movie = _search_candidate(session, token, title, year)
        if not movie:
            continue
        sim = _title_similarity(title, movie.get("title") or movie.get("original_title"))
        if best is None or sim > best[0]:
            best = (sim, movie, sidecar.name)
    if best and best[0] >= 0.80:
        return best[1], f"sidecar_subtitle:{best[2]}"
    return None, None


def resolve_via_visual_ocr(path, session, token):
    """Best-effort title-card OCR; skipped when Tesseract is unavailable."""
    tesseract = shutil.which("tesseract")
    ffmpeg = shutil.which("ffmpeg")
    if not tesseract or not ffmpeg:
        return None, None
    import scanner
    with tempfile.TemporaryDirectory(prefix="media-ident-") as td:
        frame_dir = Path(td)
        # Sample several early frames. Repeated title-card text is much safer than one frame.
        for idx, seconds in enumerate((8, 20, 40, 70)):
            target = frame_dir / f"frame_{idx}.jpg"
            try:
                proc = subprocess.run([ffmpeg, "-y", "-ss", str(seconds), "-i", str(path), "-frames:v", "1", "-q:v", "3", str(target)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False)
                if proc.returncode != 0 or not target.is_file():
                    continue
                ocr = subprocess.run([tesseract, str(target), "stdout", "--psm", "11"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=15, check=False)
                text = ocr.stdout or ""
            except Exception:
                continue
            for line in text.splitlines():
                title = re.sub(r"[^A-Za-z0-9'&:!?., -]", " ", line).strip(" -._")
                if not 2 <= len(title.split()) <= 8 or is_anonymous_name(title):
                    continue
                movie = _search_candidate(session, token, title, None)
                if not movie:
                    continue
                sim = _title_similarity(title, movie.get("title") or movie.get("original_title"))
                if sim >= 0.80:
                    return movie, f"visual_ocr:{title}"
    return None, None


def resolve_via_subtitles(path, session, token):
    """Inspect embedded subtitles for useful evidence without guessing from dialogue."""
    try:
        result = subprocess.run(["ffmpeg", "-y", "-i", str(path), "-map", "0:s:0", "-t", "180", "-f", "webvtt", "-"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=20, check=False)
        if result.returncode != 0 or not result.stdout:
            return None, None
        lines = []
        for line in result.stdout.splitlines():
            line = re.sub(r"<[^>]+>", "", line).strip()
            if line and "-->" not in line and not line.startswith("WEBVTT") and not line.isdigit() and len(line) > 10:
                lines.append(line)
        if lines:
            logger.debug("Subtitle evidence extracted for %s (%d lines)", path.name, len(lines))
    except Exception as exc:
        logger.debug("Subtitle evidence extraction failed for %s: %s", path.name, exc)
    return None, None


def resolve_media(path, session=None, token=None):
    """Identify anonymous media by combining independent evidence sources."""
    path = Path(path)
    import scanner
    close_session = False
    if session is None:
        session = requests.Session()
        close_session = True
    if token is None:
        token = scanner.load_token()
    if not token:
        if close_session:
            session.close()
        return None, None

    evidence = []
    try:
        methods = (
            (resolve_via_container_tags, 5.0),
            (resolve_via_sidecar_subtitles, 5.0),
            (resolve_via_moviehash, 3.0),
            (resolve_via_visual_ocr, 2.0),
        )
        for method, weight in methods:
            try:
                movie, source = method(path, session, token)
            except Exception as exc:
                logger.warning("Resolver strategy %s failed for %s: %s", method.__name__, path.name, exc)
                continue
            if movie:
                evidence.append((movie, source, weight))

        if not evidence:
            return None, None

        grouped = {}
        for movie, source, weight in evidence:
            key = movie.get("id")
            if not key:
                continue
            rec = grouped.setdefault(key, {"movie": movie, "sources": [], "score": 0.0})
            rec["sources"].append(source)
            rec["score"] += weight

        ranked = sorted(grouped.values(), key=lambda r: r["score"], reverse=True)
        if not ranked:
            return None, None
        best = ranked[0]
        second_score = ranked[1]["score"] if len(ranked) > 1 else 0.0
        # Single-source hash/OCR guesses must be clearly stronger than alternatives.
        if best["score"] < 3.0 or (second_score and best["score"] - second_score < 1.0):
            logger.warning("Ambiguous identification for %s; evidence=%s", path.name, [(r["movie"].get("title"), r["score"]) for r in ranked])
            return None, None
        source = "consensus:" + ",".join(best["sources"])
        logger.info("Resolved %s -> %s via %s", path.name, best["movie"].get("title"), source)
        return best["movie"], source
    finally:
        if close_session:
            session.close()
