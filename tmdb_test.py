from pathlib import Path
import requests

env = {}

for line in Path(".env").read_text().splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")

token = env["TMDB_API_TOKEN"]

r = requests.get(
    "https://api.themoviedb.org/3/search/movie",
    headers={"Authorization": f"Bearer {token}"},
    params={
        "query": "Oculus",
        "year": 2013,
        "language": "en-US"
    }
)

print("HTTP:", r.status_code)
print(r.text[:3000])
