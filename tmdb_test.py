"""Minimal TMDb API smoke test.

Set TMDB_API_TOKEN in the environment before running.
"""

import os
import requests

token = os.environ.get("TMDB_API_TOKEN")
if not token:
    raise SystemExit("TMDB_API_TOKEN is not set")

r = requests.get(
    "https://api.themoviedb.org/3/search/movie",
    headers={"Authorization": f"Bearer {token}"},
    params={"query": "Oculus", "year": 2013, "language": "en-US"},
    timeout=20,
)

print("HTTP:", r.status_code)
print(r.text[:3000])
