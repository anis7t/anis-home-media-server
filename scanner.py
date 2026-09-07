from pathlib import Path
import sqlite3
import requests
import re
import time

MEDIA_ROOT = Path("/home/iamroot/Media/Movies").resolve()
BASE_DIR = Path("/home/iamroot/media-server").resolve()
DB_PATH = BASE_DIR / "media.db"
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
    if not ENV_FILE.exists():
        raise RuntimeError(".env file not found")

    for line in ENV_FILE.read_text().splitlines():
        if line.startswith("TMDB_API_TOKEN="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")

    raise RuntimeError("TMDB_API_TOKEN not found in .env")


# ---------------------------------------------------------
# Filename parser
# ---------------------------------------------------------

def parse_filename(path):
    name = path.stem

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
        },
    )


# ---------------------------------------------------------
# Scan library
# ---------------------------------------------------------

def scan():

    token = load_token()

    if not MEDIA_ROOT.exists():
        raise RuntimeError(
            f"Media directory does not exist: {MEDIA_ROOT}"
        )

    conn = sqlite3.connect(DB_PATH)

    setup_database(conn)

    video_files = sorted(
        path
        for path in MEDIA_ROOT.rglob("*")
        if path.is_file()
        and path.suffix.lower() in VIDEO_EXTENSIONS
    )

    print(f"Found {len(video_files)} video files.")
    print()

    # One HTTP session for the entire scan
    session = requests.Session()

    for index, path in enumerate(video_files, 1):

        relative = path.relative_to(MEDIA_ROOT).as_posix()

        existing = conn.execute(
            """
            SELECT tmdb_id, title
            FROM movies
            WHERE filename = ?
            """,
            (relative,),
        ).fetchone()

        if existing:
            print(
                f"[{index}/{len(video_files)}] "
                f"Already scanned: {existing[1]}"
            )
            continue

        title, year = parse_filename(path)

        print(
            f"[{index}/{len(video_files)}] "
            f"{title}"
            + (f" ({year})" if year else "")
        )

        try:

            # ---------------------------------------------
            # Search
            # ---------------------------------------------

            movie = find_movie(
                session,
                token,
                title,
                year,
            )

            if not movie:
                print("    TMDB: no match")
                print()
                continue

            tmdb_id = movie["id"]

            print(
                f"    Match: "
                f"{movie.get('title')} "
                f"({movie.get('release_date', '')[:4]})"
            )

            # ---------------------------------------------
            # Details
            # ---------------------------------------------

            details = get_movie_details(
                session,
                token,
                tmdb_id,
            )

            genres = ", ".join(
                genre["name"]
                for genre in details.get("genres", [])
            )

            release_date = details.get(
                "release_date",
                ""
            )

            if release_date:
                actual_year = int(release_date[:4])
            else:
                actual_year = year

            # ---------------------------------------------
            # Save immediately
            # ---------------------------------------------

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
                    updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                ),
            )

            conn.commit()

            print(
                f"    Saved metadata "
                f"(TMDB ID {tmdb_id})"
            )

        except Exception as e:

            print(
                f"    ERROR: {e}"
            )

        # Small pause between movies
        time.sleep(2)

        print()

    session.close()
    conn.close()

    print("Scan complete.")


# ---------------------------------------------------------
# Main
# ---------------------------------------------------------

if __name__ == "__main__":
    scan()
