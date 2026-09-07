from pathlib import Path
import requests

env = {}

for line in Path(".env").read_text().splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")

token = env["TMDB_API_TOKEN"]

r = requests.get(
    "https://api.themoviedb.org/3/movie/15067",
    headers={
        "Authorization": f"Bearer {token}"
    },
    timeout=20
)

print("HTTP:", r.status_code)
print(r.text[:1000])
