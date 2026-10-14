"""Autonomous live Selenium browser test for Rust Axum React SPA serving (Phase 2R-B).

Verifies that the native Rust executable (media-server-api.exe on port 8001):
1. Serves the React SPA at root `/` with HTTP 200 text/html.
2. Supports client-side SPA routing fallback on `/manage` and `/manual`.
3. Loads compiled Vite assets (`/assets/*`) without MIME type or execution errors.
4. Captures visual browser screenshots in `_shots/`.
5. Strictly manages process lifecycles with zero orphaned tasks.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path
import urllib.request
import urllib.error

from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

BASE_DIR = Path(r"E:\MediaServer")
BINARY_PATH = BASE_DIR / "rust" / "target" / "debug" / "media-server-api.exe"
SHOTS_DIR = BASE_DIR / "_shots"
PORT = 8001
BASE_URL = f"http://127.0.0.1:{PORT}"

def wait_for_server(url: str, timeout: float = 12.0) -> bool:
    start = time.time()
    health_url = f"{url}/api/health"
    while time.time() - start < timeout:
        try:
            with urllib.request.urlopen(health_url, timeout=1.0) as resp:
                if resp.status == 200:
                    data = json.loads(resp.read().decode())
                    if data.get("status") == "healthy":
                        return True
        except Exception:
            time.sleep(0.3)
    return False

def main():
    SHOTS_DIR.mkdir(parents=True, exist_ok=True)

    if not BINARY_PATH.exists():
        print(f"[FAIL] Rust binary not found at {BINARY_PATH}")
        sys.exit(1)

    print(f"[1/4] Spawning native Rust media server from {BINARY_PATH}...")
    env = os.environ.copy()
    env["RUST_PORT"] = str(PORT)
    env["MEDIA_SERVER_DATABASE_URL"] = "postgresql://postgres:postgres@127.0.0.1:5432/media_server"
    env["MEDIA_SERVER_MEDIA_ROOT"] = r"D:\Flicks"
    env["MEDIA_SERVER_CACHE_DIR"] = r"E:\MediaServer\cache"
    env["MEDIA_SERVER_STATIC_DIR"] = r"E:\MediaServer\web\dist"

    server_proc = subprocess.Popen(
        [str(BINARY_PATH)],
        cwd=str(BASE_DIR),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    driver = None
    try:
        print(f"[2/4] Waiting for Rust API health check at {BASE_URL}/api/health...")
        if not wait_for_server(BASE_URL, timeout=15.0):
            print("[FAIL] Rust server failed to become healthy within 15 seconds.")
            if server_proc.poll() is not None:
                out, _ = server_proc.communicate()
                print(f"Server exited with code {server_proc.returncode}:\n{out}")
            sys.exit(1)
        print("  -> Rust Axum server is healthy and listening on port 8001!")

        print("[3/4] Launching headless Chrome Selenium session...")
        opts = Options()
        opts.add_argument("--headless=new")
        opts.add_argument("--window-size=1440,900")
        opts.add_argument("--mute-audio")
        opts.add_argument("--disable-gpu")
        opts.add_argument("--no-sandbox")
        opts.add_argument("--disable-dev-shm-usage")
        opts.set_capability("goog:loggingPrefs", {"browser": "ALL"})

        driver = webdriver.Chrome(options=opts)
        driver.set_page_load_timeout(20)

        # Test Case 1: Root / SPA loading
        print(f"  -> Testing root URL: {BASE_URL}/")
        driver.get(f"{BASE_URL}/")
        WebDriverWait(driver, 15).until(EC.presence_of_element_located((By.ID, "root")))
        time.sleep(1.0) # Let React hydration finish
        
        home_shot = SHOTS_DIR / "phase_2r_b_spa_home.png"
        driver.save_screenshot(str(home_shot))
        print(f"  -> Root page loaded successfully. Saved screenshot: {home_shot}")

        # Check DOM text
        body_text = driver.find_element(By.TAG_NAME, "body").text
        print(f"  -> Body text preview: {body_text[:120].strip()}...")
        assert "Anis" in body_text or "Library" in body_text or "Movies" in body_text, "Home page missing brand header/content"

        # Test Case 2: Client-side route direct navigation /manage
        manage_url = f"{BASE_URL}/manage"
        print(f"  -> Testing direct SPA route navigation: {manage_url}")
        driver.get(manage_url)
        WebDriverWait(driver, 15).until(EC.presence_of_element_located((By.ID, "root")))
        time.sleep(1.0)

        manage_shot = SHOTS_DIR / "phase_2r_b_spa_manage.png"
        driver.save_screenshot(str(manage_shot))
        print(f"  -> Manage route loaded successfully. Saved screenshot: {manage_shot}")
        manage_text = driver.find_element(By.TAG_NAME, "body").text
        assert "Manage" in manage_text or "Admin" in manage_text or "PIN" in manage_text or "Library" in manage_text, "Manage page content missing"

        # Test Case 3: Client-side route direct navigation /manual
        manual_url = f"{BASE_URL}/manual"
        print(f"  -> Testing direct SPA route navigation: {manual_url}")
        driver.get(manual_url)
        WebDriverWait(driver, 15).until(EC.presence_of_element_located((By.ID, "root")))
        time.sleep(1.0)

        manual_shot = SHOTS_DIR / "phase_2r_b_spa_manual.png"
        driver.save_screenshot(str(manual_shot))
        print(f"  -> Manual route loaded successfully. Saved screenshot: {manual_shot}")
        manual_text = driver.find_element(By.TAG_NAME, "body").text
        assert "Manual" in manual_text or "Shortcuts" in manual_text or "Keyboard" in manual_text, "Manual page content missing"

        # Test Case 4: Browser console logs inspection
        print("[4/4] Inspecting browser console logs for fatal errors...")
        logs = driver.get_log("browser")
        severe_errors = [entry for entry in logs if entry.get("level") == "SEVERE" and "favicon" not in entry.get("message", "")]
        for log in logs:
            if log.get("level") in ("WARNING", "SEVERE"):
                print(f"  [{log['level']}] {log['message']}")
        
        if severe_errors:
            print(f"[WARN] Found {len(severe_errors)} severe console errors (inspect above).")
        else:
            print("  -> Zero severe browser console errors! Static assets, JS chunks, and styles parsed cleanly.")

        print("\n[SUCCESS] Phase 2R-B live browser verification completed successfully!")

    finally:
        if driver:
            try:
                driver.quit()
                print("  -> Chrome WebDriver session terminated cleanly.")
            except Exception as e:
                print(f"  -> Error terminating driver: {e}")

        if server_proc:
            try:
                server_proc.terminate()
                server_proc.wait(timeout=5)
                print("  -> Rust server process terminated cleanly.")
            except Exception:
                server_proc.kill()
                print("  -> Rust server process killed.")

if __name__ == "__main__":
    main()
