import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
import urllib.error

parser = argparse.ArgumentParser(description="Probe Phase 8 Contracts")
parser.add_argument("--base", default=os.environ.get("BASE", "http://127.0.0.1:8000"), help="Base URL of server")
args, _ = parser.parse_known_args()
BASE = args.base.rstrip("/")

print(f"--- Probing Phase 8 Contracts against {BASE} ---")

# 1. Fetch library movies to find an MKV
req = urllib.request.Request(f"{BASE}/api/movies")
with urllib.request.urlopen(req, timeout=10) as resp:
    data = json.loads(resp.read().decode())
    movies = data.get("movies", [])

mkv_movie = next((m for m in movies if m["filename"].endswith(".mkv")), None)
if not mkv_movie:
    print("FAILED: No MKV found in library")
    sys.exit(1)

filename = mkv_movie["filename"]
enc_filename = "/".join(urllib.parse.quote(part, safe="") for part in filename.split("/"))
print(f"Selected test MKV: {filename}")

# 2. Web Client Simulation (Default)
web_url = f"{BASE}/api/media-info/{enc_filename}"
req_web = urllib.request.Request(web_url, headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})
with urllib.request.urlopen(req_web, timeout=10) as resp:
    assert resp.status == 200, f"Expected 200, got {resp.status}"
    info_web = json.loads(resp.read().decode())

print(f"Web client response:")
print(f"  direct_play: {info_web.get('direct_play')}")
print(f"  needs_transcode: {info_web.get('needs_transcode')}")
print(f"  quality_ladder count: {len(info_web.get('quality_ladder', []))}")
for q in info_web.get("quality_ladder", []):
    print(f"    - {q.get('quality')}: {q.get('label')} ({q.get('width')}x{q.get('height')})")

assert info_web.get("direct_play") is False, "Web MKV direct_play must be false"
assert info_web.get("needs_transcode") is True, "Web MKV needs_transcode must be true"
assert len(info_web.get("quality_ladder", [])) > 0, "quality_ladder must not be empty"

# Verify no upscaling in ladder
source_h = info_web.get("video", {}).get("height") or 1080
for q in info_web.get("quality_ladder", []):
    if q.get("height") and q.get("quality") != "source":
        assert q["height"] <= source_h, f"Ladder height {q['height']} exceeds source height {source_h}"

print("[OK] Web client probe passed: MKV correctly requires transcode and has quality ladder.")

# 3. Android Client Simulation (?client=android & X-Client-Platform: android)
android_url = f"{BASE}/api/media-info/{enc_filename}?client=android"
req_android = urllib.request.Request(
    android_url,
    headers={
        "User-Agent": "ExoPlayerLib/2.18.1 (Linux; Android 13; SM-G998B)",
        "X-Client-Platform": "android"
    }
)
with urllib.request.urlopen(req_android, timeout=10) as resp:
    assert resp.status == 200, f"Expected 200, got {resp.status}"
    info_android = json.loads(resp.read().decode())

print(f"Android client response:")
print(f"  direct_play: {info_android.get('direct_play')}")
print(f"  needs_transcode: {info_android.get('needs_transcode')}")
assert info_android.get("direct_play") is True, "Android MKV direct_play must be true"
assert info_android.get("needs_transcode") is False, "Android MKV needs_transcode must be false"

print("[OK] Android client probe passed: MKV correctly evaluated for zero-copy direct play.")

# 4. Quality-specific transcode status check
status_url = f"{BASE}/api/transcode-status/{enc_filename}?quality=720p"
with urllib.request.urlopen(status_url, timeout=10) as resp:
    assert resp.status == 200, f"Expected 200, got {resp.status}"
    status_data = json.loads(resp.read().decode())
    print("Transcode status for 720p:", status_data)
    assert "status" in status_data
    assert "is_complete" in status_data

print("[OK] Quality-specific status query passed.")

# 5. On-demand start contract with quality parameter
synthetic = "synthetic_phase8_probe_file.mkv"
start_url = f"{BASE}/api/transcode/start/{synthetic}?quality=720p"
req_start = urllib.request.Request(start_url, method="POST")
try:
    with urllib.request.urlopen(req_start, timeout=10) as resp:
        print(f"Unexpected status: {resp.status}")
        sys.exit(1)
except urllib.error.HTTPError as e:
    assert e.code == 404, f"Expected HTTP 404 for synthetic file, got {e.code}"
    print(f"[OK] Quality-specific start endpoint verified (HTTP 404 on synthetic target).")

print("\n--- ALL PHASE 8 API & CLIENT CONTRACT PROBES PASSED ---")
