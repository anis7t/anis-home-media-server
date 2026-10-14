"""Selenium E2E verification for Subtitle Engine and Subtitle Settings Modal."""
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
from app.db import get_db, init_db

def test_subtitles_e2e():
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

        # Check for ccMergedPill, ccBtn, subSettingsBtn
        cc_pill = WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.ID, "ccMergedPill"))
        )
        assert cc_pill.is_displayed(), "#ccMergedPill must be visible"

        cc_btn = driver.find_element(By.ID, "ccBtn")
        sub_settings_btn = driver.find_element(By.ID, "subSettingsBtn")
        assert cc_btn.is_displayed(), "#ccBtn must be visible"
        assert sub_settings_btn.is_displayed(), "#subSettingsBtn must be visible"
        print("[SUCCESS] Subtitle CC button and settings button are present and visible.")

        # Initially, subSettingsModal should be absent or not displayed
        modals = driver.find_elements(By.ID, "subSettingsModal")
        assert len(modals) == 0 or not modals[0].is_displayed(), "Modal should not be open initially"

        # Click #subSettingsBtn to open modal
        driver.execute_script("arguments[0].click();", sub_settings_btn)
        time.sleep(0.5)

        modal = WebDriverWait(driver, 5).until(
            EC.visibility_of_element_located((By.ID, "subSettingsModal"))
        )
        assert modal.is_displayed(), "#subSettingsModal should be visible after clicking settings button"
        print("[SUCCESS] Subtitle settings modal opened successfully.")

        # Verify modal controls exist
        track_select = driver.find_element(By.ID, "subTrackSelect")
        color_select = driver.find_element(By.ID, "subColorSelect")
        bg_select = driver.find_element(By.ID, "subBgSelect")
        size_select = driver.find_element(By.ID, "subSizeSelect")
        pos_select = driver.find_element(By.ID, "subPosSelect")
        vert_select = driver.find_element(By.ID, "subVerticalSelect")
        preview_box = driver.find_element(By.ID, "subPreviewBox")
        preview_sample = driver.find_element(By.ID, "subPreviewSample")
        drop_zone = driver.find_element(By.ID, "playerSubDropZone")
        file_input = driver.find_element(By.ID, "playerSubFileInput")

        assert track_select is not None
        assert color_select is not None
        assert bg_select is not None
        assert size_select is not None
        assert pos_select is not None
        assert vert_select is not None
        assert preview_box is not None
        assert preview_sample is not None
        assert drop_zone is not None
        assert file_input is not None
        print("[SUCCESS] All subtitle modal selectors and preview controls verified.")

        # Test changing color in preview
        driver.execute_script("arguments[0].value = '#ffff00'; arguments[0].dispatchEvent(new Event('change', { bubbles: true }));", color_select)
        time.sleep(0.3)
        sample_color = preview_sample.value_of_css_property("color")
        print(f"Preview sample color: {sample_color}")

        # Test closing modal via #closeSubModal
        close_btn = driver.find_element(By.ID, "closeSubModal")
        driver.execute_script("arguments[0].click();", close_btn)
        time.sleep(0.5)
        modals_after_close = driver.find_elements(By.ID, "subSettingsModal")
        assert len(modals_after_close) == 0 or not modals_after_close[0].is_displayed(), "Modal should be closed after clicking close button"
        print("[SUCCESS] Subtitle settings modal closed successfully.")

        # Test 'c' key shortcut toggling subtitles
        body = driver.find_element(By.TAG_NAME, "body")
        body.send_keys("c")
        time.sleep(0.5)

        hud = driver.find_elements(By.ID, "playerHud")
        if hud and hud[0].is_displayed():
            print(f"[SUCCESS] Player HUD triggered via shortcut: '{hud[0].text}'")

        # Capture verification screenshot
        screenshot_dir = Path("tests/screenshots")
        screenshot_dir.mkdir(parents=True, exist_ok=True)
        screenshot_path = screenshot_dir / "subtitle_engine_verified.png"
        driver.save_screenshot(str(screenshot_path))
        print(f"[SUCCESS] Saved screenshot to {screenshot_path}")

    finally:
        driver.quit()
        server.shutdown()

if __name__ == "__main__":
    test_subtitles_e2e()
