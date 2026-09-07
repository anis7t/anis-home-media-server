from pathlib import Path
import requests

env = {}

for line in Path(".env").read_text().splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")

token = env["TMDB_API_TOKEN"]

headers = {
    "Authorization": f"Bearer {token}",
    "User-Agent": "Mozilla/5.0",
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
            params={
                "query": title,
                "year": year,
                "language": "en-US",
            },
            timeout=20,
        )

        print("HTTP:", r.status_code)

        data = r.json()
        results = data.get("results", [])

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

try:
    r = requests.get(
        "https://image.tmdb.org/t/p/w500/As3eTQXF BZ e2Gzf9ZzjFVULIIL.jpg".replace(" ", ""),
        headers=headers,
        timeout=20,
    )

    print("Image HTTP:", r.status_code)
    print("Image bytes:", len(r.content))

except Exception as e:
    print("IMAGE ERROR:", repr(e))
