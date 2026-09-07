from pathlib import Path
import os
import sqlite3
import requests
import time

BASE_DIR = Path(os.environ.get("MEDIA_SERVER_BASE_DIR", Path(__file__).parent)).resolve()
DB_PATH = Path(os.environ.get("MEDIA_SERVER_DATABASE", BASE_DIR / "media.db"))
POSTER_DIR = BASE_DIR / "cache" / "posters"
BACKDROP_DIR = BASE_DIR / "cache" / "backdrops"

TMDB_IMAGE = "https://image.tmdb.org/t/p/w500"

MAX_RETRIES = 5


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

    for attempt in range(1, MAX_RETRIES + 1):

        try:
            print(
                f"    Downloading poster "
                f"(attempt {attempt}/{MAX_RETRIES})..."
            )

            response = requests.get(
                url,
                headers=headers,
                timeout=30,
            )

            response.raise_for_status()

            if not response.content:
                raise RuntimeError("Empty response")

            destination.write_bytes(response.content)

            print(
                f"    Saved: {destination}"
            )

            return True

        except Exception as e:

            print(f"    Failed: {e}")

            if attempt < MAX_RETRIES:
                delay = attempt * 3
                print(f"    Retrying in {delay}s...")
                time.sleep(delay)

    return False


def main():

    if not DB_PATH.exists():
        print("media.db not found.")
        return

    conn = sqlite3.connect(DB_PATH)

    movies = conn.execute("""
        SELECT
            filename,
            title,
            tmdb_id,
            poster_path,
            backdrop_path
        FROM movies
        WHERE tmdb_id IS NOT NULL
    """).fetchall()

    print(f"Found {len(movies)} movies with metadata.")
    print()

    successful = 0
    failed = 0

    for index, (filename, title, tmdb_id, poster_path, backdrop_path) in enumerate(
        movies, 1
    ):

        print(
            f"[{index}/{len(movies)}] {title}"
        )

        if not poster_path:
            print("    No poster available from TMDB.")
            failed += 1
        elif download_poster(tmdb_id, poster_path):
            successful += 1
        else:
            failed += 1

        if backdrop_path:
            download_poster(tmdb_id, backdrop_path, backdrop=True)

        print()

        # Small pause between movies
        time.sleep(2)

    conn.close()

    print("--------------------------------")
    print("Poster download complete.")
    print(f"Successful: {successful}")
    print(f"Failed:     {failed}")
    print("--------------------------------")


if __name__ == "__main__":
    main()
