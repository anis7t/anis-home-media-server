import json
import logging
import os
import time
from pathlib import Path
import requests
from app import config

logger = logging.getLogger(__name__)

TMDB_API = "https://api.themoviedb.org/3"
TMDB_IMAGE = "https://image.tmdb.org/t/p"


def load_token():
    """Load TMDB API v4 read token from environment variable or .env file."""
    token = os.environ.get("TMDB_API_TOKEN")
    if token:
        return token.strip().strip('"').strip("'")
    env_file = config.BASE_DIR / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            if line.startswith("TMDB_API_TOKEN="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    return None


def download_poster(tmdb_id, poster_path, backdrop=False):
    """Download poster or backdrop image from TMDB into local cache."""
    # Delegate to posters module to maintain test patches on posters.download_poster
    try:
        import posters
        return posters.download_poster(tmdb_id, poster_path, backdrop=backdrop)
    except Exception:
        pass

    if not poster_path:
        return False
    directory = config.BACKDROP_CACHE if backdrop else config.POSTER_CACHE
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / f"{tmdb_id}.jpg"
    if destination.exists() and destination.stat().st_size > 1000:
        return True

    image_size = "w1280" if backdrop else "w500"
    url = f"{TMDB_IMAGE}/{image_size}{poster_path}"
    headers = {"User-Agent": "Mozilla/5.0", "Accept": "image/*", "Connection": "close"}
    try:
        resp = requests.get(url, headers=headers, timeout=30)
        if resp.status_code == 200 and resp.content:
            destination.write_bytes(resp.content)
            return True
    except Exception:
        pass
    return False


def get_movie_details(session, token, tmdb_id):
    """Fetch complete movie details from TMDB."""
    try:
        import scanner
        return scanner.get_movie_details(session, token, tmdb_id)
    except Exception:
        return None


def refresh_movie_metadata(conn, session, token, movie_row, force=False, max_age_seconds=None):
    """Refresh TMDb metadata for a single movie record if eligible.

    Returns True if updated, False if skipped or failed.
    """
    if max_age_seconds is None:
        max_age_seconds = config.METADATA_REFRESH_INTERVAL

    tmdb_id = movie_row["tmdb_id"] if hasattr(movie_row, "__getitem__") else getattr(movie_row, "tmdb_id", None)
    filename = movie_row["filename"] if hasattr(movie_row, "__getitem__") else getattr(movie_row, "filename", None)
    if not tmdb_id or not filename:
        return False

    # Check last refresh timestamp unless force is True
    last_refresh = None
    if hasattr(movie_row, "keys") and "last_metadata_refresh" in movie_row.keys():
        last_refresh = movie_row["last_metadata_refresh"]
    elif isinstance(movie_row, dict):
        last_refresh = movie_row.get("last_metadata_refresh")

    now = int(time.time())
    if not force and last_refresh and (now - int(last_refresh)) < max_age_seconds:
        return False

    details = get_movie_details(session, token, tmdb_id)
    if not details or not isinstance(details, dict) or "id" not in details:
        return False

    genres = ", ".join(genre["name"] for genre in details.get("genres", []))
    release_date = details.get("release_date", "")

    cert = ""
    for r in details.get("release_dates", {}).get("results", []):
        if r.get("iso_3166_1") in ("US", "IN"):
            for rel in r.get("release_dates", []):
                if rel.get("certification"):
                    cert = rel["certification"]
                    break
            if cert:
                break

    cast = [
        {"name": c.get("name"), "character": c.get("character"), "profile_path": c.get("profile_path")}
        for c in details.get("credits", {}).get("cast", [])[:20]
    ]
    directors = [c.get("name") for c in details.get("credits", {}).get("crew", []) if c.get("job") == "Director"]
    writers = [c.get("name") for c in details.get("credits", {}).get("crew", []) if c.get("job") in ("Writer", "Screenplay")]
    production = [p.get("name") for p in details.get("production_companies", [])]
    trailer_key = ""
    for v in details.get("videos", {}).get("results", []):
        if v.get("site") == "YouTube" and v.get("type") in ("Trailer", "Teaser"):
            trailer_key = v.get("key")
            break

    details_json = json.dumps({
        "tagline": details.get("tagline", ""),
        "imdb_id": details.get("imdb_id", ""),
        "certification": cert,
        "cast": cast,
        "directors": directors,
        "writers": writers,
        "production": production,
        "trailer_key": trailer_key,
    })

    poster_path = details.get("poster_path")
    backdrop_path = details.get("backdrop_path")
    vote_avg = details.get("vote_average")
    runtime = details.get("runtime")
    overview = details.get("overview")

    conn.execute(
        """
        UPDATE movies
        SET vote_average = COALESCE(?, vote_average),
            runtime = COALESCE(?, runtime),
            overview = COALESCE(?, overview),
            genres = COALESCE(?, genres),
            release_date = COALESCE(?, release_date),
            details_json = ?,
            poster_path = COALESCE(?, poster_path),
            backdrop_path = COALESCE(?, backdrop_path),
            last_metadata_refresh = ?,
            updated_at = ?
        WHERE filename = ?
        """,
        (
            vote_avg,
            runtime,
            overview,
            genres,
            release_date,
            details_json,
            poster_path,
            backdrop_path,
            now,
            now,
            filename,
        ),
    )
    conn.commit()

    if poster_path:
        download_poster(tmdb_id, poster_path)
    if backdrop_path:
        download_poster(tmdb_id, backdrop_path, backdrop=True)

    return True


def refresh_all_library_metadata(force=False, max_age_seconds=None, conn=None, session=None, token=None):
    """Refresh TMDb metadata for all indexed movies in the database."""
    if token is None:
        token = load_token()
    if not token:
        logger.info("TMDb token not available; skipping metadata refresh.")
        return 0

    close_conn = False
    if conn is None:
        from app.db import get_db
        conn = get_db()
        close_conn = True

    close_session = False
    if session is None:
        session = requests.Session()
        close_session = True

    updated_count = 0
    try:
        rows = conn.execute("SELECT * FROM movies WHERE tmdb_id IS NOT NULL").fetchall()
        for row in rows:
            if config.SHUTDOWN_EVENT.is_set():
                break
            try:
                did_update = refresh_movie_metadata(
                    conn, session, token, row, force=force, max_age_seconds=max_age_seconds
                )
                if did_update:
                    updated_count += 1
                    # Gentle throttle between TMDB requests
                    time.sleep(0.25)
            except Exception as e:
                logger.warning(f"Error refreshing metadata for movie {row['filename']}: {e}")
    finally:
        if close_session:
            session.close()
        if close_conn:
            conn.close()

    if updated_count > 0:
        logger.info(f"TMDb metadata refreshed for {updated_count} movie(s).")
    return updated_count

