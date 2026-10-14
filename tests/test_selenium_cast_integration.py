"""Selenium E2E verification for LAN Cast & DLNA Remote Playback Integration (Phase 6)."""
import os
import shutil
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.chrome.options import Options
from werkzeug.serving import make_server
import threading
from app import create_app
from app.db import init_db
from app.services import media_service
from flask import jsonify, request

def test_cast_integration_e2e():
    app = create_app()
    with app.app_context():
        init_db()

    # Mock cast registry for predictable E2E testing
    from app.services import cast_service
    from app.routes import cast as cast_routes

    class MockRegistry:
        def devices(self, force=False):
            return {
                'ok': True,
                'devices': [
                    {
                        'id': 'dlna:mock-samsung-qled-1',
                        'name': 'Living Room TV (Samsung QLED)',
                        'kind': 'dlna',
                        'model': 'Samsung QLED 4K',
                        'ip': '192.168.1.105',
                    },
                    {
                        'id': 'cast:mock-chromecast-2',
                        'name': 'Bedroom Chromecast',
                        'kind': 'cast',
                        'model': 'Chromecast with Google TV',
                        'ip': '192.168.1.110',
                    },
                ],
                'scanning': False,
                'errors': {},
                'scanned_at': time.time(),
            }

        def play(self, device_id, filename, position=None, origin=None):
            return {
                'ok': True,
                'device': 'Living Room TV (Samsung QLED)',
                'url': 'http://192.168.1.50:8000/media/movie.mp4',
                'kind': 'dlna',
            }

        def status(self, device_id):
            return {
                'ok': True,
                'state': 'playing',
                'position': 285.0,
                'duration': 5400.0,
                'volume': 75.0,
                'muted': False,
                'title': '2001',
            }

        def control(self, device_id, action, value=None):
            return {'ok': True}

    mock_reg = MockRegistry()
    cast_service.registry = lambda: mock_reg
    cast_routes.registry = lambda: mock_reg

    server = make_server('127.0.0.1', 0, app)
    port = server.port
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    options = Options()
    options.add_argument('--headless=new')
    options.add_argument('--no-sandbox')
    options.add_argument('--disable-dev-shm-usage')
    options.add_argument('--window-size=1400,1000')

    driver = webdriver.Chrome(options=options)
    try:
        movies = media_service.get_movies()
        if not movies:
            raise RuntimeError("No movies found in library for E2E testing.")

        test_movie = movies[0]['filename']
        print(f"Loading player route: /watch/{test_movie}")
        driver.get(f"http://127.0.0.1:{port}/watch/{test_movie}")

        # 1. Wait for video element and player shell
        shell = WebDriverWait(driver, 15).until(
            EC.presence_of_element_located((By.ID, "shell"))
        )
        assert shell.is_displayed(), "#shell must be displayed for ready media"

        # 2. Verify Cast button #castBtn in controls row
        cast_btn = WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.ID, "castBtn"))
        )
        assert cast_btn is not None, "#castBtn must exist in DOM controls row"
        print("[SUCCESS] Cast button #castBtn verified in player controls.")

        # 3. Click #castBtn to open CastModal
        driver.execute_script("arguments[0].click();", cast_btn)
        time.sleep(0.5)

        cast_modal = WebDriverWait(driver, 10).until(
            EC.visibility_of_element_located((By.ID, "castModal"))
        )
        assert cast_modal.is_displayed(), "#castModal must be visible upon clicking #castBtn"
        modal_title = driver.find_element(By.ID, "castModalTitle").text
        assert "Cast to Device" in modal_title, f"Expected 'Cast to Device' title, got: {modal_title}"
        print("[SUCCESS] Cast picker modal dialog opened with title 'Cast to Device'.")

        # 4. Verify discovered LAN devices rendered in dialog
        tv_item = WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.XPATH, "//*[contains(text(), 'Living Room TV')]"))
        )
        assert tv_item is not None, "Discovered DLNA TV must be visible in list"
        assert driver.find_element(By.XPATH, "//*[contains(text(), 'Bedroom Chromecast')]") is not None, "Chromecast must be visible in list"
        print("[SUCCESS] Discovered DLNA TV and Google Cast devices rendered in modal list.")

        # Capture modal screenshot
        os.makedirs("tests/screenshots", exist_ok=True)
        modal_screenshot_path = "tests/screenshots/cast_modal_verified.png"
        driver.save_screenshot(modal_screenshot_path)
        print(f"[SUCCESS] Cast modal screenshot saved to {modal_screenshot_path}")

        # 5. Connect to Living Room TV
        tv_button = driver.find_element(By.XPATH, "//button[contains(., 'Living Room TV')]")
        driver.execute_script("arguments[0].click();", tv_button)
        time.sleep(0.8)

        # 6. Verify CastBar Active Remote HUD is displayed
        cast_bar = WebDriverWait(driver, 10).until(
            EC.visibility_of_element_located((By.ID, "castBar"))
        )
        time.sleep(1.2)
        cast_text = cast_bar.text.lower()
        assert "playing" in cast_text or "connecting" in cast_text, f"Expected state in cast_bar text, got: {cast_bar.text}"
        print(f"[SUCCESS] Active Cast remote control HUD (#castBar) verified. State: {cast_text.splitlines()[:3]}")

        # 7. Verify Local Shell and Video are hidden
        shell_display = shell.value_of_css_property("display")
        assert shell_display == "none", f"#shell must have display: none during cast, got: {shell_display}"
        print("[SUCCESS] Local video shell strictly hidden while casting to second-screen.")

        # Capture active cast controller screenshot
        cast_bar_screenshot_path = "tests/screenshots/cast_integration_verified.png"
        driver.save_screenshot(cast_bar_screenshot_path)
        print(f"[SUCCESS] CastBar HUD screenshot saved to {cast_bar_screenshot_path}")

        # 8. Test Remote Transport Commands (Play/Pause, Disconnect)
        play_pause_btn = driver.find_element(By.ID, "castPlayPauseBtn")
        driver.execute_script("arguments[0].click();", play_pause_btn)
        time.sleep(0.3)
        print("[SUCCESS] Remote play/pause command dispatched.")

        # 9. Disconnect Cast and verify return to local player
        disconnect_btn = driver.find_element(By.ID, "castDisconnectBtn")
        driver.execute_script("arguments[0].click();", disconnect_btn)
        time.sleep(0.8)

        # CastBar dismissed, Shell restored
        remaining_cast_bars = driver.find_elements(By.ID, "castBar")
        assert len(remaining_cast_bars) == 0, "#castBar must be unmounted from DOM after disconnect"
        shell_restored = WebDriverWait(driver, 10).until(
            EC.visibility_of_element_located((By.ID, "shell"))
        )
        assert shell_restored.is_displayed(), "#shell must return to visible state after disconnect"
        print("[SUCCESS] Cast disconnected cleanly; local player shell restored.")

        # Copy screenshots to artifact directory
        artifact_dir = Path(r"C:\Users\anis7\.gemini\antigravity-ide\brain\d6ece144-72e7-43ad-824d-98cd5c158b9e")
        if artifact_dir.exists():
            shutil.copy2(modal_screenshot_path, artifact_dir / "cast_modal_verified.png")
            shutil.copy2(cast_bar_screenshot_path, artifact_dir / "cast_integration_verified.png")
            print(f"[SUCCESS] Copied screenshots to brain artifact directory: {artifact_dir}")

    finally:
        driver.quit()
        server.shutdown()
        server_thread.join(timeout=2)

if __name__ == "__main__":
    test_cast_integration_e2e()
