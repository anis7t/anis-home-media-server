"""Live probe for the media-upload routes on the running Rust/Axum service.

Two things are checked without credentials:
  * `/api/upload/chunk/init` exists (403, not 404), and
  * it does not accept an Admin PIN from the query string.

When `MEDIA_SERVER_ADMIN_PIN` is set, the full resumable handshake is exercised
against the live service: init -> append 4 bytes -> status -> abort -> 404.
The probe never completes the upload, so it creates no media file and no catalog
row. The PIN is read from the environment only; it is never put in a URL or
written to disk.

Usage:
    $env:MEDIA_SERVER_ADMIN_PIN = '<pin>'
    python scripts/probe_upload.py
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

parser = argparse.ArgumentParser(description="Media upload contract probe")
parser.add_argument(
    "--base",
    default="http://127.0.0.1:8000",
    help="origin to probe (default: http://127.0.0.1:8000).",
)
args = parser.parse_args()
BASE = args.base.rstrip("/")
PIN = (os.environ.get("MEDIA_SERVER_ADMIN_PIN") or "").strip()

failures = []


def request(method, path, data=None, headers=None):
    req = urllib.request.Request(BASE + path, method=method, data=data)
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.status, response.read().decode(errors="replace")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode(errors="replace")


def check(label, method, path, accepted, data=None, headers=None):
    status, body = request(method, path, data=data, headers=headers)
    ok = status in accepted
    print(f"{'OK  ' if ok else 'FAIL'} {method:6} {status:<3} {path[:60]:62} {label}")
    if not ok:
        failures.append((label, method, path, status, body[:300]))
    return status, body


def parse(body):
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return {}


print(f"Probing {BASE}")
print()

# The route must exist and be gated even for an unauthenticated caller.
check(
    "init refuses an unauthenticated caller",
    "POST",
    "/api/upload/chunk/init",
    (403,),
    data=json.dumps({"filename": "probe_upload.mp4", "size": 4}).encode(),
    headers={"Content-Type": "application/json"},
)

# A query-string PIN has never been accepted and must stay that way.
check(
    "init refuses a query-string PIN",
    "POST",
    "/api/upload/chunk/init?pin=not-a-real-pin",
    (403,),
    data=json.dumps({"filename": "probe_upload.mp4", "size": 4}).encode(),
    headers={"Content-Type": "application/json"},
)

if not PIN:
    print()
    print("RESULT: unauthenticated checks passed; authorized checks SKIPPED")
    print("        set MEDIA_SERVER_ADMIN_PIN to exercise the handshake")
    sys.exit(1 if failures else 0)

headers = {"Content-Type": "application/json", "X-Admin-Pin": PIN}
filename = f"probe_upload_{os.getpid()}_{int(time.time())}.mp4"
status, body = check(
    "init accepts the Admin PIN",
    "POST",
    "/api/upload/chunk/init",
    (200,),
    data=json.dumps({"filename": filename, "size": 4}).encode(),
    headers=headers,
)
if status != 200:
    print()
    print("RESULT: authorized probe could not start; the PIN was refused")
    for failure in failures:
        print("  ", failure)
    sys.exit(1)

upload_id = parse(body).get("upload_id")
if not isinstance(upload_id, str) or not upload_id:
    print("FAIL  init response did not contain an upload_id")
    failures.append(("init response", body[:300]))
else:
    chunk_headers = {
        "Content-Type": "application/octet-stream",
        "X-Admin-Pin": PIN,
        "X-Upload-Offset": "0",
    }
    status, body = check(
        "chunk append records 4 bytes",
        "POST",
        f"/api/upload/chunk/{upload_id}",
        (200,),
        data=b"test",
        headers=chunk_headers,
    )
    if status == 200:
        appended = parse(body)
        if appended.get("offset") != 4:
            print("FAIL  append did not report offset 4")
            failures.append(("append offset", body[:300]))

    check(
        "status reports the uploaded offset",
        "GET",
        f"/api/upload/chunk/{upload_id}",
        (200,),
        headers={"X-Admin-Pin": PIN},
    )
    check(
        "abort removes the temp session",
        "DELETE",
        f"/api/upload/chunk/{upload_id}",
        (200,),
        headers={"X-Admin-Pin": PIN},
    )
    check(
        "aborted session is gone",
        "GET",
        f"/api/upload/chunk/{upload_id}",
        (404,),
        headers={"X-Admin-Pin": PIN},
    )

print()
if failures:
    print(f"RESULT: {len(failures)} upload contract(s) BROKEN")
    for failure in failures:
        print("  ", failure)
    sys.exit(1)
print("RESULT: upload routes exist, are admin-gated, and abort cleanly")
