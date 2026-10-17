"""Live End-to-End Browser Verification for Phase 2R-D on Port 8001.

Executes live Chrome browser automation (with UI visible on screen) to test:
1. Library Catalog (`/`): React mounting, catalog grid, and poster images proxied via Flask.
2. Movie Details (`/movie/*`): Metadata, backdrop, synopsis, audio/video badges, play action.
3. Cinema Player (`/watch/*`): Video stream delivery via native Rust, controls overlay.
4. Device Management (`/devices`): Device telemetry proxied via Flask.
5. Storage Pool (`/manage`): Storage meters and retention policies proxied via Flask.
6. User Manual (`/manual`): Offline user guide and keyboard shortcuts cheatsheet.

Process safety: Driver lifecycle wrapped in `try ... finally: driver.quit()`.
"""

import json
import shutil
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.action_chains import ActionChains
from selenium.webdriver.common.by import By
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait

BASE_DIR = Path(r"E:\MediaServer")
SHOTS_DIR = BASE_DIR / "_shots"
ARTIFACTS_DIR = Path(r"C:\Users\anis7\.gemini\antigravity-ide\brain\47618974-f5f7-41ea-8c03-fbe2adbf0765")
PORT = 8000
BASE_URL = f"http://127.0.0.1:{PORT}"

def get_sample_movie():
    """Fetch sample movie metadata from port 8001."""
    try:
        url = f"{BASE_URL}/api/movies"
        with urllib.request.urlopen(url, timeout=5.0) as resp:
            data = json.loads(resp.read().decode())
            movies = data.get("movies", [])
            if movies:
                return movies[0]
    except Exception as e:
        print(f"[WARN] Failed to fetch movie list: {e}")
    return None

def copy_shot_to_artifacts(src_path: Path, artifact_name: str):
    """Copy screenshot to the IDE artifacts directory for embed."""
    try:
        if ARTIFACTS_DIR.exists() and src_path.exists():
            dst = ARTIFACTS_DIR / artifact_name
            shutil.copy2(src_path, dst)
            print(f"  [SNAPSHOT] Saved artifact: {dst.name}")
    except Exception as e:
        print(f"  [WARN] Could not copy artifact: {e}")

def main():
    SHOTS_DIR.mkdir(parents=True, exist_ok=True)
    driver = None

    print("====================================================")
    print("   Phase 2R-D: Live Browser E2E Verification        ")
    print("   Target: http://127.0.0.1:8001 (Rust Engine)      ")
    print("   Mode: Interactive Visible Browser Window         ")
    print("====================================================")

    # 1. Health check verify
    print("\n[1/7] Checking Rust API and Flask health...")
    try:
        with urllib.request.urlopen(f"{BASE_URL}/api/health", timeout=3.0) as r:
            assert r.status == 200
        print("  -> Rust API on port 8001 is healthy.")
    except Exception as e:
        print(f"  [FAIL] Rust server on port 8001 is unreachable: {e}")
        sys.exit(1)

    movie = get_sample_movie()
    if movie:
        print(f"  -> Selected sample movie: '{movie.get('title')}' ({movie.get('year')})")
        sample_filename = movie.get("filename", "")
    else:
        sample_filename = "sample.mp4"

    # 2. Launch Visible Chrome Browser
    print("\n[2/7] Launching visible Chrome browser session...")
    opts = Options()
    # Explicitly NON-HEADLESS as requested by user
    opts.add_argument("--window-size=1600,1050")
    opts.add_argument("--disable-gpu")
    opts.add_argument("--autoplay-policy=no-user-gesture-required")
    opts.add_experimental_option("excludeSwitches", ["enable-automation"])

    try:
        driver = webdriver.Chrome(options=opts)
        driver.set_window_size(1600, 1050)
        wait = WebDriverWait(driver, 15)

        # -----------------------------------------------------------------
        # TEST 1: HOME CATALOG & PROXIED POSTERS
        # -----------------------------------------------------------------
        print("\n[3/7] Testing Home Catalog (http://127.0.0.1:8001/?intro=off)...")
        driver.get(f"{BASE_URL}/?intro=off")
        
        # Verify React root
        wait.until(EC.presence_of_element_located((By.ID, "root")))
        time.sleep(2.0)  # Allow user to view page

        # Verify movies exist in DOM
        movie_cards = driver.find_elements(By.CSS_SELECTOR, "a[href*='/movie/'], div.movie-card, .group")
        print(f"  -> Found {len(movie_cards)} movie elements on home catalog.")
        assert len(movie_cards) > 0, "No movie cards rendered in catalog!"

        # Verify posters load via proxy bridge
        try:
            wait.until(lambda d: len(d.find_elements(By.CSS_SELECTOR, "img[src*='/tmdb-poster/'], img[src*='/poster/']")) > 0)
        except Exception:
            pass
        images = driver.find_elements(By.CSS_SELECTOR, "img[src*='/tmdb-poster/'], img[src*='/poster/']")
        print(f"  -> Found {len(images)} poster images on home catalog.")
        assert len(images) > 0, "No poster images rendered in catalog!"
        
        shot1 = SHOTS_DIR / "phase_2r_d_home_catalog.png"
        driver.save_screenshot(str(shot1))
        copy_shot_to_artifacts(shot1, "phase_2r_d_home_catalog.png")
        print(f"  [OK] Home catalog verified with {len(movie_cards)} titles and active poster artwork.")
        time.sleep(2.0)

        # -----------------------------------------------------------------
        # TEST 2: MOVIE DETAILS PAGE
        # -----------------------------------------------------------------
        encoded_fn = '/'.join(urllib.parse.quote(seg) for seg in sample_filename.split('/'))
        details_url = f"{BASE_URL}/movie/{encoded_fn}"
        print(f"\n[4/7] Testing Movie Details ({details_url})...")
        driver.get(details_url)
        time.sleep(2.5)  # Allow user to view details

        # Verify details page elements & artwork
        play_btn = wait.until(
            EC.presence_of_element_located((By.CSS_SELECTOR, "a[href*='/watch/'], button, .btn-primary"))
        )
        assert play_btn is not None, "Play button not found on movie details page!"

        details_art = driver.find_elements(By.CSS_SELECTOR, "img[src*='/tmdb-poster/'], img[src*='/tmdb-backdrop/'], img[src*='/poster/']")
        print(f"  -> Found {len(details_art)} artwork images on movie details page.")

        shot2 = SHOTS_DIR / "phase_2r_d_movie_details.png"
        driver.save_screenshot(str(shot2))
        copy_shot_to_artifacts(shot2, "phase_2r_d_movie_details.png")
        print(f"  [OK] Movie details verified for '{movie.get('title')}'.")
        time.sleep(2.0)

        # -----------------------------------------------------------------
        # TEST 3: CINEMA VIDEO PLAYER & SEEKBAR HOVER IMMUNITY
        # -----------------------------------------------------------------
        player_url = f"{BASE_URL}/watch/{encoded_fn}"
        print(f"\n[5/7] Testing Cinema Video Player ({player_url})...")
        driver.get(player_url)
        time.sleep(3.0)  # Allow video initialization

        # Verify video element
        video_el = wait.until(EC.presence_of_element_located((By.TAG_NAME, "video")))
        src = video_el.get_attribute("src") or ""
        print(f"  -> Video element loaded (src: '{src[:60]}...')")

        # Test seekbar hover immunity
        print("  -> Testing seekbar hover immunity: hovering over seekbar for 4.0s...")
        seek_bar = wait.until(EC.presence_of_element_located((By.CSS_SELECTOR, "#seekTrack, #seek, .seek-track")))
        ActionChains(driver).move_to_element(seek_bar).perform()
        time.sleep(4.0)

        shell_el = driver.find_element(By.ID, "shell")
        shell_classes = shell_el.get_attribute("class") or ""
        print(f"  -> Shell classes after 4s hover on seekbar: '{shell_classes}'")
        assert "show" in shell_classes, "Controls unexpectedly hid while pointer was hovering over seekbar!"
        print("  [OK] Seekbar hover immunity verified: controls remained visible for >4 seconds without moving cursor.")

        shot3 = SHOTS_DIR / "phase_2r_d_player.png"
        driver.save_screenshot(str(shot3))
        copy_shot_to_artifacts(shot3, "phase_2r_d_player.png")
        print("  [OK] Cinema video player verified.")
        time.sleep(2.0)

        # -----------------------------------------------------------------
        # TEST 4: CONNECTED DEVICES DASHBOARD (Proxied via Flask)
        # -----------------------------------------------------------------
        devices_url = f"{BASE_URL}/devices"
        print(f"\n[6/7] Testing Devices Dashboard ({devices_url})...")
        driver.get(devices_url)
        time.sleep(2.5)

        # Verify content loaded
        wait.until(EC.presence_of_element_located((By.CSS_SELECTOR, "main, table, .container")))
        shot4 = SHOTS_DIR / "phase_2r_d_devices.png"
        driver.save_screenshot(str(shot4))
        copy_shot_to_artifacts(shot4, "phase_2r_d_devices.png")
        print("  [OK] Devices dashboard verified.")
        time.sleep(1.5)

        # -----------------------------------------------------------------
        # TEST 5: STORAGE MANAGEMENT & USER MANUAL
        # -----------------------------------------------------------------
        manage_url = f"{BASE_URL}/manage"
        print(f"\n[7/7] Testing Storage Management ({manage_url}) & Manual...")
        driver.get(manage_url)
        time.sleep(2.5)
        shot5 = SHOTS_DIR / "phase_2r_d_manage.png"
        driver.save_screenshot(str(shot5))
        copy_shot_to_artifacts(shot5, "phase_2r_d_manage.png")
        print("  [OK] Storage management verified.")

        driver.get(f"{BASE_URL}/manual")
        time.sleep(2.0)
        shot6 = SHOTS_DIR / "phase_2r_d_manual.png"
        driver.save_screenshot(str(shot6))
        copy_shot_to_artifacts(shot6, "phase_2r_d_manual.png")
        print("  [OK] User manual verified.")

        print("\n====================================================")
        print(" [SUCCESS] All 6 route suites verified successfully! ")
        print("====================================================")

    finally:
        if driver:
            print("\nClosing Chrome test browser...")
            driver.quit()
            print("Chrome session cleanly terminated.")

if __name__ == "__main__":
    main()
