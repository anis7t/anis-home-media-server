import json
import os
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import urllib.error

BASE = "http://127.0.0.1:8001"
SAMPLE_CLIP = r"D:\Flicks\test_phase8_fmp4_sample.mkv"
CACHE_ROOT = r"E:\MediaServer\cache\hls"

print("==================================================================")
print(" Phase 8 Tier 3: Live Real-Hardware fMP4 Transcode Verification   ")
print("==================================================================")

try:
    # 1. Synthesize 40s sample clip with ffmpeg
    print(f"\n[Step 1] Synthesizing 40s 1080p sample clip: {SAMPLE_CLIP}")
    if os.path.exists(SAMPLE_CLIP):
        os.remove(SAMPLE_CLIP)

    gen_cmd = [
        "ffmpeg", "-y",
        "-f", "lavfi", "-i", "testsrc=size=1920x1080:rate=30:duration=40",
        "-f", "lavfi", "-i", "sine=frequency=1000:duration=40",
        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
        "-c:a", "aac",
        SAMPLE_CLIP
    ]
    subprocess.run(gen_cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert os.path.exists(SAMPLE_CLIP), "Failed to generate sample clip"
    clip_size = os.path.getsize(SAMPLE_CLIP)
    print(f"[OK] Generated sample clip ({clip_size} bytes)")

    # 2. Trigger on-demand transcode for 720p
    enc_name = urllib.parse.quote("test_phase8_fmp4_sample.mkv", safe="")
    start_url = f"{BASE}/api/transcode/start/{enc_name}?quality=720p"
    print(f"\n[Step 2] Triggering on-demand 720p transcode via {start_url}")
    req_start = urllib.request.Request(start_url, method="POST")
    with urllib.request.urlopen(req_start, timeout=10) as resp:
        start_res = json.loads(resp.read().decode())
        print(f"Start response: {start_res}")
        assert start_res.get("status") in ("queued", "transcoding", "ready")

    # 3. Poll transcode-status until completion
    print(f"\n[Step 3] Monitoring transcode progress...")
    status_url = f"{BASE}/api/transcode-status/{enc_name}?quality=720p"
    max_wait = 120
    start_time = time.time()
    completed = False

    while time.time() - start_time < max_wait:
        time.sleep(2)
        try:
            with urllib.request.urlopen(status_url, timeout=10) as resp:
                s_data = json.loads(resp.read().decode())
                elapsed = int(time.time() - start_time)
                status = s_data.get("status")
                pct = s_data.get("percent") or s_data.get("progress")
                fps = s_data.get("fps")
                speed = s_data.get("speed")
                is_comp = s_data.get("is_complete")
                print(f"  [{elapsed}s] status={status} percent={pct}% fps={fps} speed={speed}x is_complete={is_comp}")

                if is_comp or status == "complete":
                    completed = True
                    break
        except Exception as e:
            print(f"  Transient polling error: {e}")

    if not completed:
        print("[FAIL] Transcode timed out after 120 seconds!")
        sys.exit(1)

    print(f"[OK] Transcode completed successfully in {int(time.time() - start_time)} seconds!")

    # 4. Validate Delivery of Master Playlist & Tier Playlist over HTTP
    print(f"\n[Step 4] Validating HTTP Manifest endpoints...")
    master_url = f"{BASE}/hls/{enc_name}/master.m3u8"
    with urllib.request.urlopen(master_url, timeout=10) as resp:
        master_content = resp.read().decode()
    print("--- master.m3u8 ---")
    print(master_content.strip())
    print("-------------------")
    assert "#EXT-X-VERSION:7" in master_content, "master.m3u8 missing #EXT-X-VERSION:7"
    assert "RESOLUTION=1280x720" in master_content, "master.m3u8 missing 1280x720 stream inf"
    assert "720p/playlist.m3u8" in master_content, "master.m3u8 missing 720p/playlist.m3u8 subpath"
    print("[OK] master.m3u8 verified over HTTP")

    tier_url = f"{BASE}/hls/{enc_name}/720p/playlist.m3u8"
    with urllib.request.urlopen(tier_url, timeout=10) as resp:
        tier_content = resp.read().decode()
    print("--- 720p/playlist.m3u8 ---")
    print(tier_content.strip()[:500] + "\n...")
    print("--------------------------")
    assert "#EXT-X-VERSION:7" in tier_content, "720p playlist missing #EXT-X-VERSION:7"
    assert '#EXT-X-MAP:URI="init_chunk_0.mp4"' in tier_content, "720p playlist missing init_chunk_0.mp4 MAP header"
    assert "segment_000000.m4s" in tier_content, "720p playlist missing segment_000000.m4s"
    assert "#EXT-X-ENDLIST" in tier_content, "720p playlist missing #EXT-X-ENDLIST"
    print("[OK] 720p/playlist.m3u8 verified over HTTP")

    # 5. Locate Cache Directory on Disk & Validate fMP4 Segments with ffprobe
    print(f"\n[Step 5] Locating on-disk fMP4 cache artifacts...")
    found_cache_dir = None
    for entry in os.listdir(CACHE_ROOT):
        cand = os.path.join(CACHE_ROOT, entry)
        if os.path.isdir(cand):
            p720 = os.path.join(cand, "720p")
            if os.path.isdir(p720) and os.path.exists(os.path.join(p720, "init_chunk_0.mp4")):
                # Check modification time
                mtime = os.path.getmtime(p720)
                if time.time() - mtime < 300: # created in last 5 minutes
                    found_cache_dir = cand
                    break

    assert found_cache_dir, f"Could not find matching cache directory in {CACHE_ROOT}"
    print(f"Found cache directory: {found_cache_dir}")

    init_path = os.path.join(found_cache_dir, "720p", "init_chunk_0.mp4")
    seg_path = os.path.join(found_cache_dir, "720p", "segment_000000.m4s")
    assert os.path.exists(init_path), f"Missing {init_path}"
    assert os.path.exists(seg_path), f"Missing {seg_path}"
    print(f"  init chunk: {init_path} ({os.path.getsize(init_path)} bytes)")
    print(f"  segment 0:  {seg_path} ({os.path.getsize(seg_path)} bytes)")

    # Combine init + segment into temp inspection file
    temp_probe_file = os.path.join(found_cache_dir, "720p", "probe_check.mp4")
    with open(temp_probe_file, "wb") as f_out:
        with open(init_path, "rb") as f_in:
            f_out.write(f_in.read())
        with open(seg_path, "rb") as f_in:
            f_out.write(f_in.read())

    # Run ffprobe
    probe_cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=codec_name,width,height,pix_fmt",
        "-of", "json",
        temp_probe_file
    ]
    probe_run = subprocess.run(probe_cmd, capture_output=True, text=True, check=True)
    probe_meta = json.loads(probe_run.stdout)
    v_stream = probe_meta.get("streams", [{}])[0]
    print(f"ffprobe stream metadata: {v_stream}")

    assert v_stream.get("codec_name") == "h264", f"Expected h264, got {v_stream.get('codec_name')}"
    assert v_stream.get("width") == 1280, f"Expected width 1280, got {v_stream.get('width')}"
    assert v_stream.get("height") == 720, f"Expected height 720, got {v_stream.get('height')}"
    print(f"[OK] ffprobe verified 1280x720 H.264 stream in fMP4 container!")

    if os.path.exists(temp_probe_file):
        os.remove(temp_probe_file)

    print("\n--- ALL HARDWARE fMP4 TRANSCODE CHECKS PASSED ---")

finally:
    # 6. Teardown & Purge: Clean up sample clip and cache directory
    print(f"\n[Step 6] Teardown & Cleanup...")
    if os.path.exists(SAMPLE_CLIP):
        try:
            os.remove(SAMPLE_CLIP)
            print(f"[OK] Removed sample clip {SAMPLE_CLIP}")
        except Exception as e:
            print(f"Warning: could not delete {SAMPLE_CLIP}: {e}")

    if 'found_cache_dir' in locals() and found_cache_dir and os.path.exists(found_cache_dir):
        try:
            shutil.rmtree(found_cache_dir)
            print(f"[OK] Purged cache directory {found_cache_dir}")
        except Exception as e:
            print(f"Warning: could not delete cache {found_cache_dir}: {e}")

    print("Cleanup complete. Zero storage pollution remaining.")
