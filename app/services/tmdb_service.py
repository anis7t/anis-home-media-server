"""TMDB metadata and image asset service."""
import os
import requests
from pathlib import Path
from app import config

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

