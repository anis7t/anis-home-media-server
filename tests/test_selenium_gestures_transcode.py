"""Selenium E2E verification for Preloader, Ripples, Transcode Telemetry & Touch Gestures (Phase 4)."""
import os
import shutil
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.common.action_chains import ActionChains
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.chrome.options import Options
from werkzeug.serving import make_server
import threading
from app import create_app
from app.db import init_db

def test_gestures_transcode_e2e():
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
    options.add_argument('--window-size=1400,1000')

    driver = webdriver.Chrome(options=options)
    try:
        # 1. Load home page first to ensure library and session initialize
        driver.get(f"http://127.0.0.1:{port}/")
        time.sleep(1.5)

        cards = driver.find_elements(
            By.CSS_SELECTOR,
            "a[data-testid='movie-card'], a.card[href*='/movie/'], a[href*='/movie/']",
        )
        if cards:
            details_href = cards[0].get_attribute("href")
            driver.get(details_href)

            play_btn = WebDriverWait(driver, 15).until(
                EC.element_to_be_clickable((By.CSS_SELECTOR, "a[href*='/watch/'], a[data-testid='play-button'], #playBtn"))
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

        # 2. Verify Video element and Shell container
        video = WebDriverWait(driver, 15).until(
            EC.presence_of_element_located((By.ID, "video"))
        )
        shell = WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.ID, "shell"))
        )
        assert video is not None, "Video element must be present"
        assert shell is not None, "Shell container must be present"

        # 3. Verify Player Preloader
        preloader = driver.find_element(By.ID, "playerPreloader")
        assert preloader is not None, "#playerPreloader must exist in DOM"
        preloader_msg = driver.find_element(By.ID, "playerPreloaderMsg")
        assert preloader_msg is not None, "#playerPreloaderMsg must exist"
        print(f"[SUCCESS] Player Preloader verified. Message: '{preloader_msg.text}'")

        # 4. Verify Seek Ripples Presence
        left_ripple = driver.find_element(By.ID, "seekRippleLeft")
        right_ripple = driver.find_element(By.ID, "seekRippleRight")
        assert left_ripple is not None, "#seekRippleLeft must exist in DOM"
        assert right_ripple is not None, "#seekRippleRight must exist in DOM"
        print("[SUCCESS] Seek ripples elements verified in shell container.")

        # 5. Verify Transcode Card elements
        tc_card = driver.find_element(By.ID, "playerTranscodeCard")
        assert tc_card is not None, "#playerTranscodeCard must exist in DOM"
        assert driver.find_element(By.ID, "ptcPulse") is not None, "#ptcPulse must exist"
        assert driver.find_element(By.ID, "ptcTitle") is not None, "#ptcTitle must exist"
        assert driver.find_element(By.ID, "ptcPct") is not None, "#ptcPct must exist"
        assert driver.find_element(By.ID, "ptcFill") is not None, "#ptcFill must exist"
        assert driver.find_element(By.ID, "ptcTime") is not None, "#ptcTime must exist"
        print("[SUCCESS] Transcode progress card telemetry elements verified.")

        # 6. Verify Skip buttons trigger Seek Ripples
        skip_back = driver.find_element(By.ID, "skipBackBtn")
        driver.execute_script("arguments[0].click();", skip_back)
        time.sleep(0.2)
        assert left_ripple.is_displayed(), "#seekRippleLeft must become visible on skip back"
        left_text = left_ripple.get_attribute("textContent") or ""
        assert "10" in left_text, f"Expected '10' in left ripple, got: '{left_text}'"
        print("[SUCCESS] Skip back button correctly triggered #seekRippleLeft.")

        time.sleep(0.7)  # allow ripple to auto-dismiss
        skip_forward = driver.find_element(By.ID, "skipForwardBtn")
        driver.execute_script("arguments[0].click();", skip_forward)
        time.sleep(0.2)
        assert right_ripple.is_displayed(), "#seekRippleRight must become visible on skip forward"
        right_text = right_ripple.get_attribute("textContent") or ""
        assert "10" in right_text, f"Expected '10' in right ripple, got: '{right_text}'"
        print("[SUCCESS] Skip forward button correctly triggered #seekRippleRight.")

        # 7. Verify Double-Tap Gestures on Left/Right Zones
        # Double click on left zone (20% of width)
        driver.execute_script("""
        const shell = arguments[0];
        const rect = shell.getBoundingClientRect();
        const clientX = rect.left + rect.width * 0.2;
        const clientY = rect.top + rect.height * 0.5;

        function fireClick() {
          shell.dispatchEvent(new MouseEvent('pointerdown', { bubbles: true, clientX, clientY }));
          shell.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX, clientY }));
        }

        fireClick();
        setTimeout(fireClick, 80);
        """, shell)
        time.sleep(0.3)
        assert left_ripple.is_displayed(), "Double-tap on left zone must trigger #seekRippleLeft"
        print("[SUCCESS] Double-tap on left zone successfully triggered rewind ripple.")

        time.sleep(0.7)  # allow left ripple to auto-dismiss

        # Double click on right zone (80% of width)
        driver.execute_script("""
        const shell = arguments[0];
        const rect = shell.getBoundingClientRect();
        const clientX = rect.left + rect.width * 0.8;
        const clientY = rect.top + rect.height * 0.5;

        function fireClick() {
          shell.dispatchEvent(new MouseEvent('pointerdown', { bubbles: true, clientX, clientY }));
          shell.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX, clientY }));
        }

        fireClick();
        setTimeout(fireClick, 80);
        """, shell)
        time.sleep(0.3)
        assert right_ripple.is_displayed(), "Double-tap on right zone must trigger #seekRippleRight"
        print("[SUCCESS] Double-tap on right zone successfully triggered fast-forward ripple.")

        time.sleep(0.7)

        # 8. Tap-to-Reveal Playback Interaction Invariant
        # Hide controls artificially
        driver.execute_script("arguments[0].classList.remove('show');", shell)
        time.sleep(0.1)

        # Single click on center video area (50% of width)
        driver.execute_script("""
        const shell = arguments[0];
        const rect = shell.getBoundingClientRect();
        const clientX = rect.left + rect.width * 0.5;
        const clientY = rect.top + rect.height * 0.5;
        shell.dispatchEvent(new MouseEvent('pointerdown', { bubbles: true, clientX, clientY }));
        shell.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX, clientY }));
        """, shell)
        time.sleep(0.4)

        # Controls must now be shown!
        shell_classes = shell.get_attribute("class") or ""
        assert "show" in shell_classes, "Single click when controls are hidden must reveal controls without toggling playback"
        print("[SUCCESS] Tap-to-reveal controls interaction verified.")

        # 9. Capture screenshot for walkthrough artifact
        driver.execute_script("arguments[0].scrollIntoView({behavior: 'instant', block: 'center'});", shell)
        time.sleep(0.1)
        skip_forward = driver.find_element(By.ID, "skipForwardBtn")
        driver.execute_script("arguments[0].click();", skip_forward)
        time.sleep(0.15)

        os.makedirs("tests/screenshots", exist_ok=True)
        screenshot_path = "tests/screenshots/gestures_transcode_verified.png"
        driver.save_screenshot(screenshot_path)
        print(f"[SUCCESS] Screenshot captured to {screenshot_path}")

        # Copy to brain artifact directory
        artifact_dir = Path(r"C:\Users\anis7\.gemini\antigravity-ide\brain\d6ece144-72e7-43ad-824d-98cd5c158b9e")
        if artifact_dir.exists():
            shutil.copy2(screenshot_path, artifact_dir / "gestures_transcode_verified.png")
            print(f"[SUCCESS] Copied screenshot to artifact directory: {artifact_dir / 'gestures_transcode_verified.png'}")

    finally:
        driver.quit()
        server.shutdown()
        server_thread.join(timeout=2)

if __name__ == "__main__":
    test_gestures_transcode_e2e()
