from pathlib import Path
import os
import sqlite3
import requests
import re
import time
import json
from posters import download_poster

BASE_DIR = Path(os.environ.get("MEDIA_SERVER_BASE_DIR", Path(__file__).parent)).resolve()
MEDIA_ROOT = Path(os.environ.get("MEDIA_SERVER_MEDIA_ROOT", "/home/iamroot/Media/Movies")).resolve()
DB_PATH = Path(os.environ.get("MEDIA_SERVER_DATABASE", BASE_DIR / "media.db"))
ENV_FILE = BASE_DIR / ".env"

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

    name = re.sub(r"\s+", " ", name).strip(" -._")

    return name, year


# ---------------------------------------------------------
# Database
# ---------------------------------------------------------

def setup_database(conn):
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

    columns = {row[1] for row in conn.execute("PRAGMA table_info(movies)")}
    if "release_date" not in columns:
        conn.execute("ALTER TABLE movies ADD COLUMN release_date TEXT")
    if "details_json" not in columns:
        conn.execute("ALTER TABLE movies ADD COLUMN details_json TEXT")

    conn.commit()


# ---------------------------------------------------------
# Reliable HTTP request
# ---------------------------------------------------------

def tmdb_get(session, token, url, params=None):
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "User-Agent": "LocalMediaServer/1.0",
        "Connection": "close",
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

    media_root = Path(media_root or MEDIA_ROOT).resolve()
    path = Path(path).resolve()
    try:
        relative = path.relative_to(media_root).as_posix()
    except ValueError:
        relative = path.name

    close_conn = False
    if conn is None:
        conn = sqlite3.connect(DB_PATH)
        setup_database(conn)
        close_conn = True

    close_session = False
    if session is None:
        session = requests.Session()
        close_session = True

    try:
        title, year = parse_filename(path)
        print(f"Scanning: {title}" + (f" ({year})" if year else ""))

        movie = find_movie(session, token, title, year)
        if not movie:
            print("    TMDB: no match")
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

        conn.execute(
            """
            INSERT OR REPLACE INTO movies (
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
                details_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                int(time.time()),
                release_date,
                details_json,
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

    media_root = Path(media_root or MEDIA_ROOT).resolve()
    db_path = Path(db_path or DB_PATH).resolve()

    if not media_root.exists():
        return []

    conn = sqlite3.connect(db_path)
    setup_database(conn)

    video_files = sorted(
        path
        for path in media_root.rglob("*")
        if path.is_file() and path.suffix.lower() in VIDEO_EXTENSIONS
    )

    indexed = {
        row[0]
        for row in conn.execute(
            "SELECT filename FROM movies WHERE tmdb_id IS NOT NULL"
        ).fetchall()
    }

    unindexed = [
        p for p in video_files
        if p.relative_to(media_root).as_posix() not in indexed
    ]

    if not unindexed:
        conn.close()
        return []

    print(f"Found {len(unindexed)} unindexed video files out of {len(video_files)} total.")

    session = requests.Session()
    scanned = []
    for p in unindexed:
        try:
            res = scan_single_file(p, conn=conn, session=session, token=token, media_root=media_root)
            if res:
                scanned.append(res)
        except Exception as e:
            print(f"Error scanning {p.name}: {e}")
        time.sleep(1)

    session.close()
    conn.close()
    return scanned


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

