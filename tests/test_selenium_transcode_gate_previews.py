"""Selenium E2E verification for Transcode 100% Completion Gate & Seekbar Frame Previews (Phase 5)."""
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
from app.services import media_service, transcode_service
from flask import jsonify

def test_transcode_gate_and_previews_e2e():
    app = create_app()
    with app.app_context():
        init_db()

    # Add mock routes for transcoding incomplete media
    @app.route('/api/media-info/mock_transcoding_test.mkv')
    def mock_transcode_info():
        return jsonify({
            'filename': 'mock_transcoding_test.mkv',
            'container': 'matroska',
            'duration': 5400,
            'direct_play': False,
            'needs_transcode': True,
            'is_transcode_ready': False,
            'video_codec': 'hevc',
            'audio_codec': 'ac3',
        })

    @app.route('/api/transcode-status/mock_transcoding_test.mkv')
    def mock_transcode_status():
        return jsonify({
            'status': 'transcoding',
            'percent': 68,
            'remaining': 115,
            'encoded': 3672,
            'duration': 5400,
            'speed': 2.4,
        })

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
        # =========================================================================
        # PART 1: Direct Play Media (100% Ready) - Seekbar Previews (Paused & Playing)
        # =========================================================================
        print("\n--- Testing Direct Play & Seekbar Frame Previews ---")
        movies = media_service.get_movies()
        if not movies:
            raise RuntimeError("No movies found in database/media root for testing.")

        test_movie = movies[0]['filename']
        print(f"Loading direct play media: {test_movie}")
        driver.get(f"http://127.0.0.1:{port}/watch/{test_movie}")

        # Wait for player shell and video element
        shell = WebDriverWait(driver, 15).until(
            EC.presence_of_element_located((By.ID, "shell"))
        )
        video = WebDriverWait(driver, 15).until(
            EC.presence_of_element_located((By.ID, "video"))
        )
        seek_track = WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.ID, "seekTrack"))
        )
        assert shell.is_displayed(), "#shell must be displayed for 100% ready media"

        # Verify #transcodeGate is NOT rendered for 100% ready direct play
        transcode_gates = driver.find_elements(By.ID, "transcodeGate")
        assert len(transcode_gates) == 0, "#transcodeGate must NOT be displayed for ready media"
        print("[SUCCESS] Direct play media bypasses #transcodeGate directly to player.")

        # Ensure video is paused to test paused frame preview hover
        driver.execute_script("arguments[0].pause();", video)
        time.sleep(0.5)
        is_paused = driver.execute_script("return arguments[0].paused;", video)
        assert is_paused is True, "Video should be paused for paused-state test"

        # 1. Test Frame Previews in PAUSED State on Seekbar Hover
        actions = ActionChains(driver)
        actions.move_to_element_with_offset(seek_track, 150, 10).perform()
        time.sleep(0.5)

        seek_preview = driver.find_element(By.ID, "seekPreview")
        assert seek_preview.is_displayed(), "#seekPreview must be displayed on seekbar hover while PAUSED"
        preview_time = driver.find_element(By.CSS_SELECTOR, ".seek-preview-time").text
        assert len(preview_time) > 0, "Seek preview must display timestamp badge while paused"
        print(f"[SUCCESS] Seekbar hover frame preview verified in PAUSED state (Time: {preview_time}).")

        # 2. Test Frame Previews in PLAYING State on Seekbar Hover
        driver.execute_script("arguments[0].play();", video)
        time.sleep(0.5)
        # Re-hover seek track at another offset
        actions.move_to_element_with_offset(seek_track, 300, 10).perform()
        time.sleep(0.5)

        assert seek_preview.is_displayed(), "#seekPreview must be displayed on seekbar hover while PLAYING"
        playing_preview_time = driver.find_element(By.CSS_SELECTOR, ".seek-preview-time").text
        assert len(playing_preview_time) > 0, "Seek preview must display timestamp badge while playing"
        print(f"[SUCCESS] Seekbar hover frame preview verified in PLAYING state (Time: {playing_preview_time}).")

        # 3. Test Scrubbing / Dragging Previews
        seek_input = driver.find_element(By.ID, "seek")
        actions.click_and_hold(seek_input).move_by_offset(50, 0).perform()
        time.sleep(0.3)
        assert seek_preview.is_displayed(), "#seekPreview must remain visible during scrub drag"
        actions.release().perform()
        time.sleep(0.3)
        print("[SUCCESS] Seekbar scrubbing preview drag verified.")

        # Re-hover over seekbar to capture active floating preview card in screenshot
        actions.move_to_element_with_offset(seek_track, 320, 5).perform()
        time.sleep(0.5)

        # Capture direct stream preview screenshot with active floating card
        os.makedirs("tests/screenshots", exist_ok=True)
        screenshot_path = "tests/screenshots/transcode_gate_previews_verified.png"
        driver.save_screenshot(screenshot_path)
        print(f"[SUCCESS] Direct play seek preview screenshot saved to {screenshot_path}")

        # Clean up video media pipeline before navigating
        driver.execute_script("""
            const v = document.getElementById('video');
            if (v) {
                v.pause();
                v.removeAttribute('src');
                v.load();
            }
        """)
        time.sleep(0.5)

        # =========================================================================
        # PART 2: Media Requiring Transcode (Not 100% Ready) - TranscodeGate Verification
        # =========================================================================
        print("\n--- Testing Transcode 100% Gate for Incomplete Media ---")
        driver.get(f"http://127.0.0.1:{port}/watch/mock_transcoding_test.mkv")

        # 1. Verify Transcode Gate is displayed
        gate = WebDriverWait(driver, 15).until(
            EC.visibility_of_element_located((By.ID, "transcodeGate"))
        )
        assert gate.is_displayed(), "#transcodeGate must be visible when media is not 100% transcoded"

        # 2. Verify Hardware Dual AMD GPU Badge
        gpu_badge = gate.find_element(By.XPATH, ".//span[contains(text(), 'Dual AMD GPU Transcoder Active')]")
        assert gpu_badge is not None, "Hardware Dual AMD GPU badge must be present in TranscodeGate"
        print("[SUCCESS] Hardware Dual AMD GPU badge verified in TranscodeGate.")

        # 3. Verify Progress Bar and HUD Metrics
        gate_fill = driver.find_element(By.ID, "transcodeGateFill")
        fill_style = gate_fill.get_attribute("style") or ""
        assert "68%" in fill_style, f"Expected gate fill style to contain '68%', got: '{fill_style}'"

        gate_text = gate.text
        assert "68%" in gate_text, f"Expected 68% in gate text: {gate_text}"
        assert "2.4×" in gate_text, f"Expected 2.4× speed in gate text: {gate_text}"
        assert "1m 55s" in gate_text or "115" in gate_text or "ETA:" in gate_text, f"Expected ETA in gate text: {gate_text}"
        print(f"[SUCCESS] Transcode Gate telemetry metrics verified (68% transcoded, 2.4x speed, ETA).")

        # 4. Verify Shell and Video are strictly locked/hidden
        shell_el = driver.find_element(By.ID, "shell")
        shell_display = shell_el.value_of_css_property("display")
        assert shell_display == "none", f"#shell must have display: none while transcoding, got: {shell_display}"

        # 5. Verify Seek Preview is NOT present / disabled
        previews = driver.find_elements(By.ID, "seekPreview")
        if previews:
            assert not previews[0].is_displayed(), "Seek preview must not be visible when transcoding"
        print("[SUCCESS] Playback and frame previews strictly locked behind 100% completion gate.")

        # Capture transcode gate screenshot
        gate_screenshot_path = "tests/screenshots/transcode_gate_verified.png"
        driver.save_screenshot(gate_screenshot_path)
        print(f"[SUCCESS] Transcode Gate screenshot saved to {gate_screenshot_path}")

        # Copy screenshots to artifact directory
        artifact_dir = Path(r"C:\Users\anis7\.gemini\antigravity-ide\brain\d6ece144-72e7-43ad-824d-98cd5c158b9e")
        if artifact_dir.exists():
            shutil.copy2(screenshot_path, artifact_dir / "transcode_gate_previews_verified.png")
            shutil.copy2(gate_screenshot_path, artifact_dir / "transcode_gate_verified.png")
            print(f"[SUCCESS] Copied screenshots to brain artifact directory: {artifact_dir}")

    finally:
        driver.quit()
        server.shutdown()
        server_thread.join(timeout=2)

if __name__ == "__main__":
    test_transcode_gate_and_previews_e2e()
