"""Minimal TMDb details API smoke test.

Set TMDB_API_TOKEN in the environment before running.
"""

import os
import requests

token = os.environ.get("TMDB_API_TOKEN")
if not token:
    raise SystemExit("TMDB_API_TOKEN is not set")

r = requests.get(
    "https://api.themoviedb.org/3/movie/15067",
    headers={"Authorization": f"Bearer {token}"},
    timeout=20,
)

print("HTTP:", r.status_code)
print(r.text[:1000])
