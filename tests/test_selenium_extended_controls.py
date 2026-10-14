"""Selenium E2E verification for Extended Controls & Telemetry Parity (Phase 3)."""
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.chrome.options import Options
from werkzeug.serving import make_server
import threading
from app import create_app
from app.db import init_db

def test_extended_controls_e2e():
    app = create_app()
    with app.app_context():
        init_db()

    server = make_server('127.0.0.1', 0, app)
    port = server.port
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    options = Options()
    options.add_argument('--headless=new')
    options.add_argument('--no-sandbox')
    options.add_argument('--disable-dev-shm-usage')
    options.add_argument('--window-size=1280,800')

    driver = webdriver.Chrome(options=options)
    try:
        # 1. Load home page first to ensure library and device sessions initialize
        driver.get(f"http://127.0.0.1:{port}/")
        time.sleep(1.5)

        cards = driver.find_elements(
            By.CSS_SELECTOR,
            "a[data-testid='movie-card'], a.card[href*='/movie/'], a[href*='/movie/']",
        )
        if cards:
            details_href = cards[0].get_attribute("href")
            driver.get(details_href)
            time.sleep(1.5)

            play_btn = driver.find_element(
                By.CSS_SELECTOR,
                "a[data-testid='play-button'], #playBtn, a[href*='/watch/']",
            )
            watch_href = play_btn.get_attribute("href")
            driver.get(watch_href)
        else:
            from app.services.media_service import get_movies
            movies = get_movies()
            if not movies:
                import pytest
                pytest.skip("No video cards or movies found in media root; skipping E2E selenium test.")
            driver.get(f"http://127.0.0.1:{port}/watch/{movies[0]['filename']}")

        time.sleep(2)

        # Wait for video element
        video = WebDriverWait(driver, 15).until(
            EC.presence_of_element_located((By.ID, "video"))
        )
        assert video is not None, "Video element must be present"

        # 2. Check for all Phase 3 buttons
        aspect_btn = WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.ID, "aspectBtn"))
        )
        rotate_btn = driver.find_element(By.ID, "rotateBtn")
        pip_btn = driver.find_element(By.ID, "pipBtn")
        nerd_btn = driver.find_element(By.ID, "nerdStatsBtn")
        shortcuts_btn = driver.find_element(By.ID, "shortcutsBtn")

        assert aspect_btn.is_displayed(), "#aspectBtn must be visible"
        assert rotate_btn.is_displayed(), "#rotateBtn must be visible"
        assert pip_btn.is_displayed(), "#pipBtn must be visible"
        assert nerd_btn.is_displayed(), "#nerdStatsBtn must be visible"
        assert shortcuts_btn.is_displayed(), "#shortcutsBtn must be visible"
        print("[SUCCESS] All Phase 3 control buttons are present and visible.")

        # 3. Test Aspect Ratio switching
        initial_classes = video.get_attribute("class") or ""
        assert "aspect-fit" in initial_classes, f"Expected initial aspect-fit class, got: {initial_classes}"

        driver.execute_script("arguments[0].click();", aspect_btn)
        time.sleep(0.4)
        crop_classes = video.get_attribute("class") or ""
        assert "aspect-crop" in crop_classes, f"Expected aspect-crop class, got: {crop_classes}"

        hud = driver.find_element(By.ID, "playerHud")
        assert "Aspect: Crop (Zoom)" in hud.text, f"Expected HUD to show 'Aspect: Crop (Zoom)', got: '{hud.text}'"
        print("[SUCCESS] Aspect ratio toggle verified via #aspectBtn.")

        # Test Aspect Ratio keyboard shortcut 'a'
        driver.find_element(By.TAG_NAME, "body").send_keys("a")
        time.sleep(0.4)
        stretch_classes = video.get_attribute("class") or ""
        assert "aspect-stretch" in stretch_classes, f"Expected aspect-stretch class, got: {stretch_classes}"
        print("[SUCCESS] Aspect ratio shortcut 'a' verified.")

        # 4. Test Video Rotation
        driver.execute_script("arguments[0].click();", rotate_btn)
        time.sleep(0.4)
        rot_classes = video.get_attribute("class") or ""
        assert "rotate-90" in rot_classes, f"Expected rotate-90 class, got: {rot_classes}"
        assert "90°" in hud.text, f"Expected HUD to show 90°, got: '{hud.text}'"
        print("[SUCCESS] Screen rotation toggle verified via #rotateBtn.")

        # 5. Test Nerd Stats HUD
        assert len(driver.find_elements(By.ID, "nerdStatsHud")) == 0 or not driver.find_element(By.ID, "nerdStatsHud").is_displayed()
        driver.execute_script("arguments[0].click();", nerd_btn)
        time.sleep(0.5)

        nerd_hud = WebDriverWait(driver, 5).until(
            EC.visibility_of_element_located((By.ID, "nerdStatsHud"))
        )
        assert nerd_hud.is_displayed(), "Nerd Stats HUD must be visible"

        ns_file = driver.find_element(By.ID, "nsFile").text
        ns_codecs = driver.find_element(By.ID, "nsCodecs").text
        assert ns_file != "-", f"nsFile should be populated, got: '{ns_file}'"
        assert ns_codecs != "-", f"nsCodecs should be populated, got: '{ns_codecs}'"
        print(f"[SUCCESS] Nerd Stats HUD verified with file: '{ns_file}' and codecs: '{ns_codecs}'.")

        # Close Nerd Stats HUD via #closeNerdStats
        close_nerd = driver.find_element(By.ID, "closeNerdStats")
        driver.execute_script("arguments[0].click();", close_nerd)
        time.sleep(0.3)
        assert len(driver.find_elements(By.ID, "nerdStatsHud")) == 0, "Nerd stats HUD should be unmounted"
        print("[SUCCESS] Nerd Stats HUD closed successfully.")

        # 6. Test Shortcuts Cheat Sheet Modal
        driver.execute_script("arguments[0].click();", shortcuts_btn)
        time.sleep(0.5)

        sc_modal = WebDriverWait(driver, 5).until(
            EC.visibility_of_element_located((By.ID, "shortcutsModal"))
        )
        assert sc_modal.is_displayed(), "Shortcuts modal must be visible"
        sc_grid = sc_modal.find_element(By.CLASS_NAME, "shortcuts-grid")
        assert sc_grid is not None, "Shortcuts grid must be present"
        print("[SUCCESS] Shortcuts modal verified with grid categories.")

        # Dismiss via Escape key
        driver.find_element(By.TAG_NAME, "body").send_keys(Keys.ESCAPE)
        time.sleep(0.4)
        assert len(driver.find_elements(By.ID, "shortcutsModal")) == 0, "Shortcuts modal should be unmounted"
        print("[SUCCESS] Shortcuts modal dismissed via Escape key.")

        # 7. Open Nerd Stats again and capture screenshot
        driver.execute_script("arguments[0].click();", nerd_btn)
        time.sleep(0.5)

        screenshots_dir = Path(__file__).resolve().parent / "screenshots"
        screenshots_dir.mkdir(parents=True, exist_ok=True)
        screenshot_path = screenshots_dir / "extended_controls_verified.png"
        driver.save_screenshot(str(screenshot_path))
        print(f"[SUCCESS] E2E screenshot saved to {screenshot_path}")

    finally:
        driver.quit()
        server.shutdown()

if __name__ == '__main__':
    test_extended_controls_e2e()
