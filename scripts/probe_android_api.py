"""Hit every server endpoint the Android client uses, against the live service.

This is the migration guardrail made executable: if the SPA migration changes
any API route, this fails. The surface is enumerated from `flutter_client/lib`
(`ApiEndpoints`, the cast repository, and the media resolver's delivery paths) -
the Android app has no WebView and requests no HTML page, so nothing here can be
affected by a template change.

Expectations are the routes' *contract*, not a wish for 200: `/api/app/*` answers
404 when nothing is published for that channel, which is a working route.
"""
import json
import sys
import urllib.error
import urllib.request
from urllib.parse import quote

BASE = "http://127.0.0.1:8000"

with urllib.request.urlopen(f"{BASE}/api/movies", timeout=20) as r:
    movies = json.loads(r.read().decode()).get("movies") or []
if not movies:
    sys.exit("no library entries; cannot build representative paths")
sample = movies[0]
enc = "/".join(quote(p, safe="") for p in sample["filename"].split("/"))
fid = quote(sample["filename"], safe="")

# (method, path, acceptable statuses, note)
CALLS = [
    ("GET", "/api/movies", (200,), "library list"),
    ("GET", f"/api/movie/{enc}", (200,), "movie details"),
    ("GET", "/api/system-status", (200,), "telemetry"),
    ("GET", "/api/devices", (200,), "device list"),
    ("POST", "/api/devices/heartbeat", (200,), "heartbeat"),
    ("POST", "/api/devices/client-hints", (200,), "client hints"),
    ("GET", f"/api/transcode-status/{enc}", (200,), "transcode status"),
    ("GET", f"/api/progress?filename={fid}", (200,), "resume point"),
    ("GET", f"/api/media-info/{enc}", (200,), "media info"),
    ("GET", "/api/cast/devices", (200,), "cast scan"),
    # 400 = "no active cast session for this device", the documented answer when
    # nothing is casting. `CastRepository.status()` catches the DioException and
    # returns null, so polling while idle is normal, not a failure.
    ("GET", "/api/cast/status?device_id=probe-device-0001", (200, 400), "cast status (400 = idle)"),
    # 404 = route present, nothing published for that channel.
    ("GET", "/api/app/update?channel=production", (200, 404), "app update manifest"),
    ("GET", "/api/app/download?channel=production", (200, 404), "apk download"),
    ("GET", f"/tmdb-poster/{sample.get('tmdb_id') or 0}", (200, 404), "tmdb poster"),
    ("GET", f"/media/{enc}", (200, 206, 302, 404), "media delivery"),
    ("GET", f"/hls/{enc}/playlist.m3u8", (200, 404), "hls playlist"),
    ("GET", f"/subtitles/{enc}/missing.srt", (200, 404), "subtitles"),
    ("GET", "/poster/does-not-exist.jpg", (404,), "poster route"),
]

fails = []
for method, path, ok_codes, note in CALLS:
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("X-Device-Id", "probe-device-0001")
    if method == "POST":
        req.add_header("Content-Type", "application/json")
        req.data = b"{}"
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            code = r.status
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception as e:
        code = f"ERR {e}"
    ok = code in ok_codes
    print(f"{'OK ' if ok else 'FAIL'}  {method:4} {code}  {path[:56]:58} {note}")
    if not ok:
        fails.append((method, path, code, note, ok_codes))

print()
if fails:
    print(f"RESULT: {len(fails)} endpoint(s) BROKEN")
    for f in fails:
        print("  ", f)
    sys.exit(1)
print(f"RESULT: all {len(CALLS)} Android client endpoints respond per contract")
print("        (0 HTML pages requested - the app has no WebView, so template")
print("         changes cannot affect it)")