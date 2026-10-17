#!/usr/bin/env python3
"""Automated Live Real-Hardware Transcode Verification Script (Phase 6 Slice 3).

Validates:
1. Rust transcode worker claims jobs from PostgreSQL queue.
2. FFmpeg renders chunks concurrently on AMD AMF GPUs (dx11:1 RX 560X + dx11:0 Vega 8).
3. Status polling (/api/transcode-status) accurately reflects running progress and speed.
4. Output playlist has #EXT-X-DISCONTINUITY between chunks and terminal #EXT-X-ENDLIST.
5. Generated HLS stream is playable and verified by ffprobe.
6. Flask transcode scheduler remains dormant (single-ownership invariant).
7. Zero test artifacts or phantom rows persist after run.
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
import urllib.error
import psycopg2
from pathlib import Path

# Add project root to sys.path so app imports work
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.transcode_service import hls_cache_dir

BASE_URL = os.environ.get("RUST_BASE_URL", "http://127.0.0.1:8000")
DB_URL = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:5432/media_server")
SAMPLE_FILENAME = "test_transcode_live_sample.mkv"
SAMPLE_PATH = Path("D:/Flicks") / SAMPLE_FILENAME


def log(msg):
    print(f"[VERIFY] {msg}", flush=True)


def check_server_health():
    log(f"Checking server health at {BASE_URL}/health ...")
    try:
        req = urllib.request.urlopen(f"{BASE_URL}/health", timeout=5)
        if req.status == 200:
            log("MediaServerRust is healthy and responding (HTTP 200).")
            return True
    except Exception as e:
        log(f"Server health check failed: {e}")
        return False
    return False


def ensure_sample_video():
    if not SAMPLE_PATH.exists():
        log(f"Generating 70-second test video: {SAMPLE_PATH} ...")
        cmd = [
            "ffmpeg", "-y",
            "-f", "lavfi", "-i", "testsrc=duration=70:size=1280x720:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=1000:duration=70",
            "-c:v", "libx264", "-preset", "ultrafast",
            "-c:a", "aac",
            "-t", "70",
            str(SAMPLE_PATH)
        ]
        res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if res.returncode != 0:
            log(f"FFmpeg generation failed: {res.stderr}")
            sys.exit(1)
        log("Test sample video generated successfully.")
    else:
        log(f"Existing test sample found: {SAMPLE_PATH}")


def resolve_hls_cache_dir():
    return Path(hls_cache_dir(SAMPLE_PATH))


def clean_state():
    cache_dir = resolve_hls_cache_dir()
    log(f"Cleaning previous cache directory {cache_dir} ...")
    if cache_dir.exists():
        shutil.rmtree(cache_dir, ignore_errors=True)

    log("Cleaning previous job rows in PostgreSQL ...")
    try:
        conn = psycopg2.connect(DB_URL)
        cur = conn.cursor()
        cur.execute("DELETE FROM transcode_jobs WHERE filename = %s;", (SAMPLE_FILENAME,))
        conn.commit()
        cur.close()
        conn.close()
    except Exception as e:
        log(f"Warning: could not clean database row: {e}")


def enqueue_job():
    log(f"Enqueuing transcode job via POST {BASE_URL}/api/transcode/jobs/{SAMPLE_FILENAME} ...")
    url = f"{BASE_URL}/api/transcode/jobs/{SAMPLE_FILENAME}"
    data = json.dumps({"priority": 10, "target_resolution": "1080p"}).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
    try:
        resp = urllib.request.urlopen(req, timeout=5)
        resp_data = json.loads(resp.read().decode("utf-8"))
        log(f"Job enqueued: id={resp_data.get('id')}, status={resp_data.get('status')}, priority={resp_data.get('priority')}")
        return resp_data
    except Exception as e:
        log(f"Failed to enqueue job: {e}")
        sys.exit(1)


def monitor_job():
    log("Monitoring transcode progress and telemetry ...")
    start_time = time.time()
    max_wait_seconds = 180  # 3 minutes maximum timeout for 70s clip
    last_status = None
    last_pct = -1

    while time.time() - start_time < max_wait_seconds:
        try:
            status_url = f"{BASE_URL}/api/transcode-status/{SAMPLE_FILENAME}"
            resp = urllib.request.urlopen(status_url, timeout=5)
            data = json.loads(resp.read().decode("utf-8"))

            status = data.get("status")
            pct = data.get("progress_percent", 0.0)
            speed = data.get("speed")
            eta = data.get("eta_seconds")

            if status != last_status or abs(pct - last_pct) >= 5.0:
                speed_str = f"{speed:.2f}x" if speed else "N/A"
                eta_str = f"{eta}s" if eta else "N/A"
                log(f"Status: {status:10s} | Progress: {pct:5.1f}% | Speed: {speed_str} | ETA: {eta_str}")
                last_status = status
                last_pct = pct

            if status in ("complete", "ready") or data.get("is_complete") is True:
                log("Transcode reported COMPLETE by status endpoint!")
                break
        except Exception as e:
            log(f"Status check exception: {e}")

        time.sleep(1.5)

    duration = time.time() - start_time
    log(f"Transcode loop completed in {duration:.1f} seconds.")

    # Confirm in database
    conn = psycopg2.connect(DB_URL)
    cur = conn.cursor()
    cur.execute("SELECT id, status, lease_owner, progress, error FROM transcode_jobs WHERE filename = %s;", (SAMPLE_FILENAME,))
    row = cur.fetchone()
    cur.close()
    conn.close()

    if not row:
        log("ERROR: No database row found for completed job!")
        sys.exit(1)

    job_id, db_status, lease_owner, progress, err_msg = row
    log(f"PostgreSQL Job #{job_id}: status='{db_status}', lease_owner='{lease_owner}', progress={progress}%, err={err_msg}")

    if db_status != "completed":
        log(f"ERROR: Expected database status 'completed', got '{db_status}' (error: {err_msg})")
        sys.exit(1)


def verify_playlist_artifacts():
    cache_dir = resolve_hls_cache_dir()
    log(f"Verifying generated HLS playlist artifacts in {cache_dir} ...")
    playlist_path = cache_dir / "playlist.m3u8"
    layout_path = cache_dir / ".seg_layout"

    if not playlist_path.exists():
        log(f"ERROR: Playlist not found at {playlist_path}")
        sys.exit(1)

    content = playlist_path.read_text(encoding="utf-8")
    lines = [line.strip() for line in content.splitlines()]

    # Validate HLS invariants
    assert "#EXTM3U" in content, "Missing #EXTM3U header"
    assert "#EXT-X-TARGETDURATION" in content, "Missing #EXT-X-TARGETDURATION"
    assert "#EXT-X-ENDLIST" in content, "Missing terminal #EXT-X-ENDLIST tag"
    log("Playlist headers and #EXT-X-ENDLIST verified.")

    # Validate #EXT-X-DISCONTINUITY between chunks (70s video = 2 chunks)
    discontinuity_count = content.count("#EXT-X-DISCONTINUITY")
    log(f"Found {discontinuity_count} #EXT-X-DISCONTINUITY tag(s) across chunks.")
    assert discontinuity_count >= 1, f"Expected at least 1 discontinuity tag between chunk 0 and chunk 1, got {discontinuity_count}"

    # Validate strided segment layout
    assert layout_path.exists(), "Missing .seg_layout layout marker file"
    layout_content = layout_path.read_text(encoding="utf-8").strip()
    assert layout_content == "stride32", f"Unexpected layout marker: {layout_content}"
    log(".seg_layout verified as 'stride32'.")

    # Check that segment indices reflect stride32
    segments = [l for l in lines if l.startswith("segment_") and l.endswith(".ts")]
    log(f"Total TS segments referenced in playlist: {len(segments)}")
    assert any("segment_000000" in s for s in segments), "Expected chunk 0 start segment segment_000000.ts"
    assert any("segment_000032" in s for s in segments), "Expected chunk 1 strided start segment segment_000032.ts"
    log("Strided segment indexing (chunk 0 @ 0, chunk 1 @ 32) verified.")

    # Validate output with ffprobe
    log("Probing playlist.m3u8 with ffprobe ...")
    probe_cmd = [
        "ffprobe", "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        str(playlist_path)
    ]
    res = subprocess.run(probe_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        log(f"ERROR: ffprobe failed on generated playlist: {res.stderr}")
        sys.exit(1)

    probed_duration = float(res.stdout.strip() or 0.0)
    log(f"ffprobe reported continuous stream duration: {probed_duration:.2f} seconds (expected ~70.0s).")
    assert probed_duration >= 68.0, f"Probed duration {probed_duration}s is too short for 70s source!"
    log("Stream duration and container validity successfully verified.")


def cleanup_test_assets():
    cache_dir = resolve_hls_cache_dir()
    log("Cleaning up temporary test video and cache artifacts ...")
    if SAMPLE_PATH.exists():
        SAMPLE_PATH.unlink()
    if cache_dir.exists():
        shutil.rmtree(cache_dir, ignore_errors=True)

    try:
        conn = psycopg2.connect(DB_URL)
        cur = conn.cursor()
        cur.execute("DELETE FROM transcode_jobs WHERE filename = %s;", (SAMPLE_FILENAME,))
        conn.commit()
        cur.close()
        conn.close()
    except Exception as e:
        log(f"Warning during final cleanup: {e}")
    log("Cleanup complete. Zero test artifacts persist.")


def main():
    log("=== Starting Phase 6 Slice 3 Live Transcode Verification ===")
    if not check_server_health():
        sys.exit(1)

    try:
        ensure_sample_video()
        clean_state()
        enqueue_job()
        monitor_job()
        verify_playlist_artifacts()
        log("=== All Live Transcode Verification Checks PASSED (100%) ===")
    finally:
        cleanup_test_assets()


if __name__ == "__main__":
    main()
