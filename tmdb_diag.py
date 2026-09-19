"""Small TMDb diagnostic helper.

Set TMDB_API_TOKEN in the environment before running.
"""

import os
import requests

token = os.environ.get("TMDB_API_TOKEN")
if not token:
    raise SystemExit("TMDB_API_TOKEN is not set")

headers = {
    "Authorization": f"Bearer {token}",
    "User-Agent": "MediaServer-TMDb-Diagnostic",
}

movies = [
    ("Oculus", 2013),
    ("Grand Theft Auto VI", 2026),
    ("Spider-Man Brand New Day", 2026),
]

print("=== TESTING TMDB API ===")

for title, year in movies:
    print(f"\nSearching: {title} ({year})")
    try:
        r = requests.get(
            "https://api.themoviedb.org/3/search/movie",
            headers=headers,
            params={"query": title, "year": year, "language": "en-US"},
            timeout=20,
        )
        print("HTTP:", r.status_code)
        results = r.json().get("results", [])
        if results:
            movie = results[0]
            print("Match:", movie.get("title"))
            print("TMDB ID:", movie.get("id"))
            print("Poster:", movie.get("poster_path"))
        else:
            print("No match")
    except Exception as e:
        print("API ERROR:", repr(e))

print("\n=== TESTING IMAGE SERVER ===")

poster_path = "/As3eTQXF BZ e2Gzf9ZzjFVULIIL.jpg".replace(" ", "")
try:
    r = requests.get(
        f"https://image.tmdb.org/t/p/w500{poster_path}",
        headers=headers,
        timeout=20,
    )
    print("Image HTTP:", r.status_code)
    print("Image bytes:", len(r.content))
except Exception as e:
    print("IMAGE ERROR:", repr(e))
