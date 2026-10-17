from pathlib import Path
import os
import sqlite3
import requests
import re
import time
import json
import sys
from dotenv import load_dotenv

BASE_DIR = Path(os.environ.get("MEDIA_SERVER_BASE_DIR", Path(__file__).parent)).resolve()
ENV_FILE = BASE_DIR / ".env"
if "pytest" in sys.modules or os.environ.get("MEDIA_SERVER_MEDIA_ROOT"):
    load_dotenv(ENV_FILE, override=False)
else:
    load_dotenv(ENV_FILE, override=True)

MEDIA_ROOT = Path(os.environ.get("MEDIA_SERVER_MEDIA_ROOT", "D:/Flicks" if os.name == "nt" else "/home/iamroot/Media/Movies")).resolve()
DB_PATH = Path(os.environ.get("MEDIA_SERVER_DATABASE", BASE_DIR / "media.db"))
DATABASE_URL = os.environ.get("DATABASE_URL")
if not DATABASE_URL and ENV_FILE.exists():
    for line in ENV_FILE.read_text().splitlines():
        if line.startswith("DATABASE_URL="):
            DATABASE_URL = line.split("=", 1)[1].strip().strip('"').strip("'")
            break

_CACHE_DIR = Path(os.environ.get("MEDIA_SERVER_CACHE_DIR") or (BASE_DIR / "cache"))
POSTER_DIR = _CACHE_DIR / "posters"
BACKDROP_DIR = _CACHE_DIR / "backdrops"

def download_poster(tmdb_id, poster_path, backdrop=False):
    if not poster_path:
        return False

    directory = BACKDROP_DIR if backdrop else POSTER_DIR
    directory.mkdir(parents=True, exist_ok=True)

    destination = directory / f"{tmdb_id}.jpg"
    if destination.exists() and destination.stat().st_size > 1000:
        return True

    image_size = "w1280" if backdrop else "w500"
    url = f"https://image.tmdb.org/t/p/{image_size}{poster_path}"
    headers = {
        "User-Agent": "Mozilla/5.0",
        "Accept": "image/*",
        "Connection": "close",
    }

    for attempt in range(1, 4):
        try:
            response = requests.get(url, headers=headers, timeout=30)
            response.raise_for_status()
            if len(response.content) < 1000:
                return False
            destination.write_bytes(response.content)
            return True
        except Exception:
            time.sleep(1)
    return False

def get_backend():
    return "postgres" if DATABASE_URL else "sqlite"

def get_db():
    if DATABASE_URL:
        import psycopg
        return psycopg.connect(DATABASE_URL)
    return sqlite3.connect(DB_PATH)

def _exec(conn, sql, params=()):
    if get_backend() == "postgres":
        sql_pg = sql.replace("?", "%s")
        cur = conn.cursor()
        cur.execute(sql_pg, params)
        return cur
    return conn.execute(sql, params)

def is_anonymous_name(name_or_stem: str) -> bool:
    if not name_or_stem:
        return True
    s = str(name_or_stem).strip(" -._'\"")
    if not s or re.fullmatch(r"\d+", s) or re.fullmatch(r"[0-9a-fA-F-]{8,}", s):
        return True
    prefixes = ("vid_", "video_", "mov_", "movie_", "dsc_", "img_", "untitled", "unknown", "file", "upload", "stream", "part")
    lower = s.lower()
    return any(lower.startswith(p) and (len(lower) == len(p) or re.search(r"\d", lower)) for p in prefixes)

def get_rel_path(path, media_root=None):
    root = Path(media_root or MEDIA_ROOT).resolve()
    try:
        return path.resolve().relative_to(root).as_posix()
    except Exception:
        return path.name

TMDB_API = "https://api.themoviedb.org/3"

VIDEO_EXTENSIONS = {
    ".mp4",
    ".mkv",
    ".webm",
    ".mov",
    ".avi",
    ".m4v",
}


# ---------------------------------------------------------
# Configuration
# ---------------------------------------------------------

MAX_RETRIES = 4
RETRY_DELAY = 3


# ---------------------------------------------------------
# Load TMDB token
# ---------------------------------------------------------

def load_token():
    token = os.environ.get("TMDB_API_TOKEN")
    if token:
        return token.strip().strip('"').strip("'")

    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            if line.startswith("TMDB_API_TOKEN="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")

    return None


# ---------------------------------------------------------
# Filename parser
# ---------------------------------------------------------

def parse_filename(path):
    name = path.stem

    # Remove download/copy prefixes and trailing duplicate markers
    name = re.sub(r"^(?:Copy\s+of\s+)+", "", name, flags=re.IGNORECASE)
    name = re.sub(r"\s*\(\d+\)$", "", name)
    name = re.sub(r"^[【\[].*?[】\]]\s*", "", name)

    # Replace dots and underscores with spaces
    name = re.sub(r"[._]+", " ", name)

    # Find year
    year_match = re.search(r"\b(19\d{2}|20\d{2})\b", name)

    year = None

    if year_match:
        year = int(year_match.group(1))
        name = name[:year_match.start()]

    # Remove common release tags
    tags = [
        r"\b1080p\b",
        r"\b2160p\b",
        r"\b4K\b",
        r"\b720p\b",
        r"\b480p\b",
        r"\bBluRay\b",
        r"\bBRRip\b",
        r"\bWEB[- ]?DL\b",
        r"\bWEBRip\b",
        r"\bHDRip\b",
        r"\bDVDRip\b",
        r"\bHDTV\b",
        r"\bx264\b",
        r"\bx265\b",
        r"\bHEVC\b",
        r"\bAVC\b",
        r"\bYIFY\b",
        r"\bRARBG\b",
    ]

    for tag in tags:
        name = re.sub(tag, "", name, flags=re.IGNORECASE)

    name = re.sub(r"\s+", " ", name).strip(" -._'\"")

    return name, year


# ---------------------------------------------------------
# Database
# ---------------------------------------------------------

def setup_database(conn):
    if get_backend() == "postgres":
        return

    conn.execute("""
        CREATE TABLE IF NOT EXISTS movies (
            filename TEXT PRIMARY KEY,
            title TEXT,
            year INTEGER,
            tmdb_id INTEGER,
            overview TEXT,
            poster_path TEXT,
            backdrop_path TEXT,
            runtime INTEGER,
            genres TEXT,
            vote_average REAL,
            updated_at INTEGER
        )
    """)

    try:
        columns = {row[1] for row in conn.execute("PRAGMA table_info(movies)")}
        if "release_date" not in columns:
            conn.execute("ALTER TABLE movies ADD COLUMN release_date TEXT")
        if "details_json" not in columns:
            conn.execute("ALTER TABLE movies ADD COLUMN details_json TEXT")
        if "last_metadata_refresh" not in columns:
            conn.execute("ALTER TABLE movies ADD COLUMN last_metadata_refresh INTEGER")
        conn.commit()
    except Exception:
        pass


# ---------------------------------------------------------
# Reliable HTTP request
# ---------------------------------------------------------

def tmdb_get(session, token, url, params=None):
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) LocalMediaServer/1.0",
    }

    for attempt in range(1, MAX_RETRIES + 1):

        try:
            response = session.get(
                url,
                headers=headers,
                params=params,
                timeout=20,
            )

            # Rate limited
            if response.status_code == 429:
                retry_after = response.headers.get("Retry-After", "5")

                try:
                    delay = int(retry_after)
                except ValueError:
                    delay = 5

                print(
                    f"    TMDB rate limit. "
                    f"Waiting {delay}s..."
                )

                time.sleep(delay)
                continue

            response.raise_for_status()

            return response.json()

        except requests.RequestException as e:

            print(
                f"    Connection failed "
                f"(attempt {attempt}/{MAX_RETRIES}): {e}"
            )

            if attempt < MAX_RETRIES:
                delay = RETRY_DELAY * attempt

                print(f"    Retrying in {delay}s...")
                time.sleep(delay)

    raise RuntimeError(
        "TMDB request failed after all retries"
    )


# ---------------------------------------------------------
# Search TMDB
# ---------------------------------------------------------

def find_movie_by_imdb_id(session, token, imdb_id):
    """Query TMDB external IDs endpoint via IMDb ID."""
    if not imdb_id or not token:
        return None
    clean_id = f"tt{str(imdb_id).lstrip('t')}"
    url = f"{TMDB_API}/find/{clean_id}"
    try:
        data = tmdb_get(session, token, url, params={"external_source": "imdb_id"})
        movie_results = data.get("movie_results", [])
        if movie_results:
            return movie_results[0]
    except Exception as e:
        print(f"    TMDB find by IMDb ID {clean_id} error: {e}")
    return None


def find_movie(session, token, title, year):

    params = {
        "query": title,
        "language": "en-US",
        "include_adult": "false",
    }

    if year:
        params["year"] = year

    data = tmdb_get(
        session,
        token,
        f"{TMDB_API}/search/movie",
        params,
    )

    results = data.get("results", [])

    if not results:
        return None

    # Prefer exact release-year match
    if year:

        for movie in results:
            release_date = movie.get("release_date", "")

            if release_date.startswith(str(year)):
                return movie

    # If there isn't an exact year match,
    # return the best TMDB result.
    return results[0]


# ---------------------------------------------------------
# Movie details
# ---------------------------------------------------------

def get_movie_details(session, token, tmdb_id):

    return tmdb_get(
        session,
        token,
        f"{TMDB_API}/movie/{tmdb_id}",
        {
            "language": "en-US",
            "append_to_response": "credits,release_dates,videos",
        },
    )


# ---------------------------------------------------------
# Scan library
# ---------------------------------------------------------

def scan_single_file(path, conn=None, session=None, token=None, media_root=None):
    if token is None:
        token = load_token()
    if not token:
        print("    TMDB_API_TOKEN not found.")
        return None

    path = Path(path)
    relative = get_rel_path(path, media_root=media_root)

    close_conn = False
    if conn is None:
        conn = get_db()
        close_conn = True

    close_session = False
    if session is None:
        session = requests.Session()
        close_session = True

    try:
        setup_database(conn)
        title, year = parse_filename(path)
        print(f"Scanning: {title}" + (f" ({year})" if year else ""))

        movie = None
        if not is_anonymous_name(title):
            movie = find_movie(session, token, title, year)

        if not movie:
            print(f"    Triggering forensic media resolution for: {path.name}")
            movie = None

        if not movie:
            print("    TMDB: no match")
            now_ts = int(time.time())
            _exec(
                conn,
                """
                INSERT INTO movies (
                    filename,
                    title,
                    year,
                    tmdb_id,
                    overview,
                    poster_path,
                    backdrop_path,
                    runtime,
                    genres,
                    vote_average,
                    updated_at,
                    release_date,
                    details_json,
                    last_metadata_refresh
                )
                VALUES (?, ?, ?, NULL, 'No TMDB metadata found', '', '', 0, '', 0.0, ?, ?, '{}', ?)
                ON CONFLICT (filename) DO NOTHING
                """,
                (relative, title, year, now_ts, str(year) if year else "", now_ts),
            )
            conn.commit()
            return None

        tmdb_id = movie["id"]
        print(f"    Match: {movie.get('title')} ({movie.get('release_date', '')[:4]})")

        details = get_movie_details(session, token, tmdb_id)
        genres = ", ".join(genre["name"] for genre in details.get("genres", []))
        release_date = details.get("release_date", "")
        actual_year = int(release_date[:4]) if release_date else year

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

        now_ts = int(time.time())
        _exec(
            conn,
            """
            INSERT INTO movies (
                filename,
                title,
                year,
                tmdb_id,
                overview,
                poster_path,
                backdrop_path,
                runtime,
                genres,
                vote_average,
                updated_at,
                release_date,
                details_json,
                last_metadata_refresh
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (filename) DO UPDATE SET
                title=excluded.title,
                year=excluded.year,
                tmdb_id=excluded.tmdb_id,
                overview=excluded.overview,
                poster_path=excluded.poster_path,
                backdrop_path=excluded.backdrop_path,
                runtime=excluded.runtime,
                genres=excluded.genres,
                vote_average=excluded.vote_average,
                updated_at=excluded.updated_at,
                release_date=excluded.release_date,
                details_json=excluded.details_json,
                last_metadata_refresh=excluded.last_metadata_refresh
            """,
            (
                relative,
                details.get("title"),
                actual_year,
                tmdb_id,
                details.get("overview"),
                details.get("poster_path"),
                details.get("backdrop_path"),
                details.get("runtime"),
                genres,
                details.get("vote_average"),
                now_ts,
                release_date,
                details_json,
                now_ts,
            ),
        )
        conn.commit()
        print(f"    Saved metadata (TMDB ID {tmdb_id})")

        if details.get("poster_path"):
            download_poster(tmdb_id, details["poster_path"])
        if details.get("backdrop_path"):
            download_poster(tmdb_id, details["backdrop_path"], backdrop=True)

        return details
    except Exception as e:
        print(f"    ERROR scanning {path.name}: {e}")
        return None
    finally:
        if close_session:
            session.close()
        if close_conn:
            conn.close()


def scan_unindexed(media_root=None, db_path=None, token=None):
    if token is None:
        token = load_token()
    if not token:
        print("TMDB_API_TOKEN not configured. Skipping scan.")
        return []

    roots = [Path(media_root or MEDIA_ROOT).resolve()]
    resolved_db_path = Path(db_path or DB_PATH).resolve()
    if db_path is not None and resolved_db_path != Path(DB_PATH).resolve():
        conn = sqlite3.connect(resolved_db_path)
    else:
        conn = get_db()

    try:
        setup_database(conn)

        video_files = []
        seen = set()
        for root in roots:
            if not root.exists():
                continue
            for path in sorted(root.rglob("*")):
                if path.is_file() and path.suffix.lower() in VIDEO_EXTENSIONS:
                    if path.name not in seen:
                        seen.add(path.name)
                        video_files.append(path)

        def _extract_filename(row):
            if hasattr(row, 'keys') or isinstance(row, dict):
                return row['filename']
            return row[0]

        indexed = {
            _extract_filename(row)
            for row in _exec(
                conn,
                "SELECT filename FROM movies"
            ).fetchall()
        }

        unindexed = []
        for p in video_files:
            rel = get_rel_path(p, media_root=media_root)
            if rel not in indexed and p.name not in indexed:
                unindexed.append(p)

        if not unindexed:
            return []

        print(f"Found {len(unindexed)} unindexed video files out of {len(video_files)} total.")

        session = requests.Session()
        scanned = []
        try:
            for p in unindexed:
                try:
                    res = scan_single_file(p, conn=conn, session=session, token=token, media_root=media_root)
                    if res:
                        scanned.append(res)
                except Exception as e:
                    print(f"Error scanning {p.name}: {e}")
                time.sleep(1)
            return scanned
        finally:
            session.close()
    finally:
        conn.close()


def scan():
    token = load_token()
    if not token:
        raise RuntimeError("TMDB_API_TOKEN not found in .env or environment")
    return scan_unindexed(token=token)


# ---------------------------------------------------------
# Main
# ---------------------------------------------------------

if __name__ == "__main__":
    scan()

