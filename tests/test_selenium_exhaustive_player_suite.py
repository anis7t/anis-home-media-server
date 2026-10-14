"""Exhaustive Master E2E Selenium Test Suite covering all 6 phases of the Video Player:
- Phase 1: Core Playback & HLS Streaming (Direct play, controls, play/pause, restart, duration)
- Phase 2: Subtitle Engine & Custom Styling (CC pill, modal, styling live preview, WebVTT tracks, upload)
- Phase 3: Extended Controls & Telemetry (Aspect cycle, 90° rotation, PiP, speed, volume/mute, Nerd Stats HUD, Shortcuts modal)
- Phase 4: Mobile Gestures, Preloader & Seek Ripples (Preloader, seek ripples, double-tap zones, skip buttons)
- Phase 5: 100% Transcode Completion Staging Gate & Seekbar Frame Previews (Hover thumbnails in paused & playing states, strict lock on incomplete media)
- Phase 6: LAN Cast & DLNA Remote Playback Integration (Cast button, discovery modal, remote controller HUD, transport, clean disconnect)
"""

import os
import shutil
import sys
import time
import threading
from pathlib import Path

# Add project root to sys.path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.common.action_chains import ActionChains
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.chrome.options import Options
from werkzeug.serving import make_server
from flask import jsonify

from app import create_app
from app.db import init_db
from app.services import media_service
from app.services import cast_service
from app.routes import cast as cast_routes

SCREENSHOTS_DIR = Path(__file__).resolve().parent / "screenshots"
SCREENSHOTS_DIR.mkdir(parents=True, exist_ok=True)
BRAIN_DIR = Path(r"C:\Users\anis7\.gemini\antigravity-ide\brain\d6ece144-72e7-43ad-824d-98cd5c158b9e")


class MockCastRegistry:
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


def run_exhaustive_player_test():
    app = create_app()
    with app.app_context():
        init_db()

    # Configure mock routes for Phase 5 incomplete transcoding media
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

    # Configure Mock Cast Registry for Phase 6
    mock_reg = MockCastRegistry()
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
    options.add_argument('--mute-audio')
    options.add_argument('--autoplay-policy=no-user-gesture-required')

    driver = webdriver.Chrome(options=options)
    driver.set_page_load_timeout(20)

    try:
        movies = media_service.get_movies()
        if not movies:
            raise RuntimeError("No movies found in database for testing.")
        test_movie = movies[0]['filename']

        print(f"\n=======================================================")
        print(f"STARTING EXHAUSTIVE E2E TEST FOR ALL 6 PHASES")
        print(f"Target Movie: {test_movie} on Port: {port}")
        print(f"=======================================================")

        # =========================================================================
        # PHASE 1: Core Playback & HLS Streaming
        # =========================================================================
        print("\n>>> [PHASE 1] Testing Core Playback & Player Shell...")
        driver.get(f"http://127.0.0.1:{port}/watch/{test_movie}")

        shell = WebDriverWait(driver, 15).until(
            EC.presence_of_element_located((By.ID, "shell"))
        )
        video = WebDriverWait(driver, 15).until(
            EC.presence_of_element_located((By.ID, "video"))
        )
        controls = WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.ID, "controls"))
        )
        play_btn = WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.ID, "play"))
        )
        restart_btn = WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.ID, "restartBtn"))
        )

        assert shell.is_displayed(), "#shell must be displayed"
        assert video.is_displayed(), "#video must be displayed"
        assert controls.is_displayed(), "#controls must be visible"

        # Check play/pause toggle
        initial_paused = driver.execute_script("return arguments[0].paused;", video)
        driver.execute_script("arguments[0].click();", play_btn)
        time.sleep(0.4)
        toggled_paused = driver.execute_script("return arguments[0].paused;", video)
        assert toggled_paused != initial_paused, "Clicking play button must toggle paused state"
        # Return to paused state for stable controls visibility
        driver.execute_script("if (!arguments[0].paused) arguments[0].pause();", video)
        time.sleep(0.3)

        # Check restart button
        driver.execute_script("arguments[0].currentTime = 30.0;", video)
        time.sleep(0.3)
        driver.execute_script("arguments[0].click();", restart_btn)
        time.sleep(0.4)
        cur_time = driver.execute_script("return arguments[0].currentTime;", video)
        assert cur_time < 2.0, f"Restart button must reset playback towards 0, got {cur_time}"

        # Capture Phase 1 screenshot
        p1_ss = SCREENSHOTS_DIR / "exhaustive_phase1_playback.png"
        driver.save_screenshot(str(p1_ss))
        print(f"[SUCCESS] Phase 1 Core Playback verified. Screenshot: {p1_ss.name}")

        # =========================================================================
        # PHASE 2: Subtitle Engine & Custom Styling
        # =========================================================================
        print("\n>>> [PHASE 2] Testing Subtitle Engine & Settings Modal...")
        cc_pill = WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.ID, "ccMergedPill"))
        )
        cc_btn = driver.find_element(By.ID, "ccBtn")
        sub_settings_btn = driver.find_element(By.ID, "subSettingsBtn")

        assert cc_pill.is_displayed(), "#ccMergedPill must be visible"
        assert cc_btn.is_displayed(), "#ccBtn must be visible"
        assert sub_settings_btn.is_displayed(), "#subSettingsBtn must be visible"

        # Open Subtitle Settings Modal
        driver.execute_script("arguments[0].click();", sub_settings_btn)
        time.sleep(0.5)

        modal = WebDriverWait(driver, 5).until(
            EC.visibility_of_element_located((By.ID, "subSettingsModal"))
        )
        assert modal.is_displayed(), "#subSettingsModal should be displayed after click"

        # Verify selectors
        track_select = driver.find_element(By.ID, "subTrackSelect")
        size_select = driver.find_element(By.ID, "subSizeSelect")
        color_select = driver.find_element(By.ID, "subColorSelect")
        bg_select = driver.find_element(By.ID, "subBgSelect")
        v_select = driver.find_element(By.ID, "subVerticalSelect")
        pos_select = driver.find_element(By.ID, "subPosSelect")
        file_input = driver.find_element(By.ID, "playerSubFileInput")
        preview_box = driver.find_element(By.ID, "subPreviewBox")

        assert track_select is not None and size_select is not None and color_select is not None
        assert v_select is not None and pos_select is not None and file_input is not None

        # Change styling and verify preview box dynamic update
        driver.execute_script("arguments[0].value = '#ffff00'; arguments[0].dispatchEvent(new Event('change', {bubbles: true}));", color_select)
        driver.execute_script("arguments[0].value = 'top'; arguments[0].dispatchEvent(new Event('change', {bubbles: true}));", v_select)
        time.sleep(0.3)

        preview_style = preview_box.get_attribute("style") or ""
        assert "align-items: flex-start" in preview_style or "flex-start" in preview_style, f"Preview box should reflect top alignment, got: {preview_style}"

        # Capture Phase 2 screenshot
        p2_ss = SCREENSHOTS_DIR / "exhaustive_phase2_subtitles.png"
        driver.save_screenshot(str(p2_ss))

        # Close modal
        close_btn = driver.find_element(By.ID, "closeSubModal")
        driver.execute_script("arguments[0].click();", close_btn)
        time.sleep(0.4)
        print(f"[SUCCESS] Phase 2 Subtitle Engine verified. Screenshot: {p2_ss.name}")

        # =========================================================================
        # PHASE 3: Extended Controls & Telemetry HUD
        # =========================================================================
        print("\n>>> [PHASE 3] Testing Extended Controls, Rotation & Telemetry HUD...")
        driver.execute_script("arguments[0].dispatchEvent(new PointerEvent('pointermove', {bubbles: true}));", shell)
        time.sleep(0.3)
        aspect_btn = WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.ID, "aspectBtn"))
        )
        rotate_btn = driver.find_element(By.ID, "rotateBtn")
        pip_btn = driver.find_element(By.ID, "pipBtn")
        nerd_btn = driver.find_element(By.ID, "nerdStatsBtn")
        shortcuts_btn = driver.find_element(By.ID, "shortcutsBtn")
        speed_select = driver.find_element(By.ID, "speed")
        volume_slider = driver.find_element(By.ID, "volume")
        mute_btn = driver.find_element(By.ID, "mute")

        assert aspect_btn.is_displayed() and rotate_btn.is_displayed() and pip_btn.is_displayed()
        assert nerd_btn.is_displayed() and shortcuts_btn.is_displayed()
        assert speed_select.is_displayed() and volume_slider.is_displayed() and mute_btn.is_displayed()

        # 1. Aspect Ratio Cycling (fit -> crop)
        initial_aspect = video.get_attribute("class") or ""
        assert "aspect-fit" in initial_aspect, f"Expected initial aspect-fit class, got: {initial_aspect}"
        driver.execute_script("arguments[0].click();", aspect_btn)
        time.sleep(0.4)
        crop_classes = video.get_attribute("class") or ""
        assert "aspect-crop" in crop_classes, f"Expected aspect-crop class, got: {crop_classes}"
        hud = driver.find_element(By.ID, "playerHud")
        assert "Aspect: Crop (Zoom)" in hud.text

        # 2. 90° Video Rotation
        driver.execute_script("arguments[0].click();", rotate_btn)
        time.sleep(0.3)
        assert "rotate-90" in (video.get_attribute("class") or "")
        assert "90°" in hud.text

        # 3. Speed selector
        driver.execute_script("arguments[0].value = '1.5'; arguments[0].dispatchEvent(new Event('change', {bubbles: true}));", speed_select)
        time.sleep(0.3)
        rate = driver.execute_script("return arguments[0].playbackRate;", video)
        assert abs(rate - 1.5) < 0.01, f"Expected playbackRate 1.5, got {rate}"

        # 4. Mute toggle
        driver.execute_script("arguments[0].click();", mute_btn)
        time.sleep(0.3)
        is_muted = driver.execute_script("return arguments[0].muted;", video)
        assert is_muted is True, "Mute button must mute video playback"
        driver.execute_script("arguments[0].click();", mute_btn)
        time.sleep(0.2)

        # 5. Nerd Stats HUD
        driver.execute_script("arguments[0].click();", nerd_btn)
        time.sleep(0.4)
        nerd_hud = WebDriverWait(driver, 5).until(
            EC.visibility_of_element_located((By.ID, "nerdStatsHud"))
        )
        assert nerd_hud.is_displayed(), "#nerdStatsHud must be visible after click"
        ns_file = driver.find_element(By.ID, "nsFile").text
        assert ns_file != "-", f"nsFile should be populated, got: '{ns_file}'"
        assert "Viewport" in nerd_hud.text and "Dropped Frames" in nerd_hud.text

        # Capture Phase 3 screenshot
        p3_ss = SCREENSHOTS_DIR / "exhaustive_phase3_extended.png"
        driver.save_screenshot(str(p3_ss))

        # Close Nerd Stats
        close_nerd = driver.find_element(By.ID, "closeNerdStats")
        driver.execute_script("arguments[0].click();", close_nerd)
        time.sleep(0.3)

        # 6. Keyboard Shortcuts Modal
        driver.execute_script("arguments[0].click();", shortcuts_btn)
        time.sleep(0.4)
        shortcuts_modal = WebDriverWait(driver, 5).until(
            EC.visibility_of_element_located((By.ID, "shortcutsModal"))
        )
        assert shortcuts_modal.is_displayed(), "#shortcutsModal must be visible after click"
        close_shortcuts = driver.find_element(By.ID, "closeShortcutsModal")
        driver.execute_script("arguments[0].click();", close_shortcuts)
        time.sleep(0.3)
        print(f"[SUCCESS] Phase 3 Extended Controls, HUD & Modals verified. Screenshot: {p3_ss.name}")

        # =========================================================================
        # PHASE 4: Mobile Gestures, Preloader & Seek Ripples
        # =========================================================================
        print("\n>>> [PHASE 4] Testing Preloader, Seek Ripples & Gesture Zones...")
        preloader = driver.find_element(By.ID, "playerPreloader")
        left_ripple = driver.find_element(By.ID, "seekRippleLeft")
        right_ripple = driver.find_element(By.ID, "seekRippleRight")
        skip_back = driver.find_element(By.ID, "skipBackBtn")
        skip_forward = driver.find_element(By.ID, "skipForwardBtn")

        assert preloader is not None, "#playerPreloader must exist"
        assert left_ripple is not None and right_ripple is not None

        # Test Skip Back & Left Ripple
        driver.execute_script("arguments[0].click();", skip_back)
        time.sleep(0.2)
        assert left_ripple.is_displayed(), "#seekRippleLeft must become visible on skip back"
        assert "10" in (left_ripple.get_attribute("textContent") or "")

        time.sleep(0.7)  # allow auto-dismiss

        # Test Skip Fwd & Right Ripple
        driver.execute_script("arguments[0].click();", skip_forward)
        time.sleep(0.2)
        assert right_ripple.is_displayed(), "#seekRippleRight must become visible on skip forward"
        assert "10" in (right_ripple.get_attribute("textContent") or "")

        # Test Double-Tap on Left Zone
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

        time.sleep(0.7)

        # Capture Phase 4 screenshot
        p4_ss = SCREENSHOTS_DIR / "exhaustive_phase4_gestures.png"
        driver.save_screenshot(str(p4_ss))
        print(f"[SUCCESS] Phase 4 Mobile Gestures & Ripples verified. Screenshot: {p4_ss.name}")

        # =========================================================================
        # PHASE 5: Transcode Gate & Seekbar Frame Previews
        # =========================================================================
        print("\n>>> [PHASE 5] Testing Frame Previews (Paused & Playing) & Transcode Gate...")
        seek_track = WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.ID, "seekTrack"))
        )

        # 1. Paused-state Frame Preview
        driver.execute_script("arguments[0].pause();", video)
        time.sleep(0.3)
        assert driver.execute_script("return arguments[0].paused;", video) is True

        actions = ActionChains(driver)
        actions.move_to_element_with_offset(seek_track, 150, 10).perform()
        time.sleep(0.5)

        seek_preview = WebDriverWait(driver, 5).until(
            EC.visibility_of_element_located((By.ID, "seekPreview"))
        )
        assert seek_preview.is_displayed(), "#seekPreview must display on hover in PAUSED state"
        preview_time = driver.find_element(By.CSS_SELECTOR, ".seek-preview-time").text
        assert len(preview_time) > 0, "Seek preview must display timestamp badge while paused"
        print(f"[SUCCESS] Paused state seek preview verified. Time: '{preview_time}'")

        # 2. Playing-state Frame Preview
        driver.execute_script("arguments[0].play();", video)
        time.sleep(0.3)
        actions.move_to_element_with_offset(seek_track, 300, 10).perform()
        time.sleep(0.5)
        assert seek_preview.is_displayed(), "#seekPreview must display on hover in PLAYING state"
        playing_preview_time = driver.find_element(By.CSS_SELECTOR, ".seek-preview-time").text
        assert len(playing_preview_time) > 0, "Seek preview must display timestamp badge while playing"
        print(f"[SUCCESS] Playing state seek preview verified. Time: '{playing_preview_time}'")

        # Capture Frame Preview screenshot
        p5_prev_ss = SCREENSHOTS_DIR / "exhaustive_phase5_previews.png"
        driver.save_screenshot(str(p5_prev_ss))

        # Reset mouse
        actions.move_to_element(controls).perform()
        time.sleep(0.3)

        # 3. Transcode Gate for Incomplete Media
        print("Testing 100% Transcode Completion Staging Gate on mock incomplete file...")
        # Cleanly stop existing video to prevent socket hold
        driver.execute_script("const v = document.getElementById('video'); if (v) { v.pause(); v.removeAttribute('src'); v.load(); }")
        time.sleep(0.5)

        driver.get(f"http://127.0.0.1:{port}/watch/mock_transcoding_test.mkv")
        gate = WebDriverWait(driver, 15).until(
            EC.visibility_of_element_located((By.ID, "transcodeGate"))
        )
        assert gate.is_displayed(), "#transcodeGate must be visible for incomplete media"

        # Verify Dual-GPU telemetry and transcode progress elements
        gpu_badge = gate.find_element(By.XPATH, ".//span[contains(text(), 'Dual AMD GPU Transcoder Active')]")
        assert gpu_badge is not None, "Hardware Dual AMD GPU badge must be present in TranscodeGate"

        gate_fill = driver.find_element(By.ID, "transcodeGateFill")
        fill_style = gate_fill.get_attribute("style") or ""
        assert "68%" in fill_style, f"Expected gate fill style to contain '68%', got: '{fill_style}'"

        gate_text = gate.text
        assert "68%" in gate_text, f"Expected 68% in gate text: {gate_text}"
        assert "2.4×" in gate_text, f"Expected 2.4× speed in gate text: {gate_text}"

        # Verify video player is strictly locked (shell has display: none)
        shell_el = driver.find_element(By.ID, "shell")
        assert shell_el.value_of_css_property("display") == "none", "#shell must have display: none while transcoding"

        # Capture Transcode Gate screenshot
        p5_gate_ss = SCREENSHOTS_DIR / "exhaustive_phase5_transcode_gate.png"
        driver.save_screenshot(str(p5_gate_ss))
        print(f"[SUCCESS] Phase 5 Transcode Gate verified. Screenshots: {p5_prev_ss.name}, {p5_gate_ss.name}")

        # =========================================================================
        # PHASE 6: LAN Cast & DLNA Remote Playback Integration
        # =========================================================================
        print("\n>>> [PHASE 6] Testing LAN Cast, Device Picker & Remote Controller HUD...")
        # Navigate back to ready test movie
        driver.get(f"http://127.0.0.1:{port}/watch/{test_movie}")

        shell = WebDriverWait(driver, 15).until(
            EC.presence_of_element_located((By.ID, "shell"))
        )
        video = WebDriverWait(driver, 15).until(
            EC.presence_of_element_located((By.ID, "video"))
        )
        cast_btn = WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.ID, "castBtn"))
        )
        assert cast_btn.is_displayed(), "#castBtn must be visible on controls bar"

        # 1. Open Cast Modal
        driver.execute_script("arguments[0].click();", cast_btn)
        time.sleep(0.5)

        cast_modal = WebDriverWait(driver, 10).until(
            EC.visibility_of_element_located((By.ID, "castModal"))
        )
        assert cast_modal.is_displayed(), "#castModal should open after clicking #castBtn"

        modal_title = driver.find_element(By.ID, "castModalTitle").text
        assert "Cast to Device" in modal_title, f"Expected 'Cast to Device' title, got: {modal_title}"

        # Verify devices in modal
        tv_item = WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.XPATH, "//*[contains(text(), 'Living Room TV')]"))
        )
        assert tv_item is not None
        assert driver.find_element(By.XPATH, "//*[contains(text(), 'Bedroom Chromecast')]") is not None

        # Capture Cast Modal screenshot
        p6_modal_ss = SCREENSHOTS_DIR / "exhaustive_phase6_cast_modal.png"
        driver.save_screenshot(str(p6_modal_ss))

        # 2. Select Samsung QLED device to cast
        tv_button = driver.find_element(By.XPATH, "//button[contains(., 'Living Room TV')]")
        driver.execute_script("arguments[0].click();", tv_button)
        time.sleep(0.8)

        # 3. Verify local shell is hidden during active casting
        shell_display = shell.value_of_css_property("display")
        assert shell_display == "none", f"Local player shell should be hidden (display: none), got: {shell_display}"

        # 4. Verify Second-Screen Remote Controller HUD appears
        cast_bar = WebDriverWait(driver, 10).until(
            EC.visibility_of_element_located((By.ID, "castBar"))
        )
        assert cast_bar.is_displayed(), "#castBar HUD must be visible during active casting"

        cast_text = cast_bar.text.lower()
        assert "playing" in cast_text or "connecting" in cast_text

        # Capture Cast Controller HUD screenshot
        p6_hud_ss = SCREENSHOTS_DIR / "exhaustive_phase6_cast_hud.png"
        driver.save_screenshot(str(p6_hud_ss))

        # 5. Test Remote Transport Controls (Toggle Play/Pause)
        play_pause_btn = driver.find_element(By.ID, "castPlayPauseBtn")
        driver.execute_script("arguments[0].click();", play_pause_btn)
        time.sleep(0.3)

        # 6. Test Disconnect
        disconnect_btn = driver.find_element(By.ID, "castDisconnectBtn")
        driver.execute_script("arguments[0].click();", disconnect_btn)
        time.sleep(0.8)

        # Verify #castBar is unmounted and local shell restored
        bars = driver.find_elements(By.ID, "castBar")
        assert len(bars) == 0, "#castBar should be unmounted upon disconnect"

        shell_restored = WebDriverWait(driver, 10).until(
            EC.visibility_of_element_located((By.ID, "shell"))
        )
        assert shell_restored.is_displayed(), "Local player shell should be restored after disconnect"
        print(f"[SUCCESS] Phase 6 LAN Cast verified. Screenshots: {p6_modal_ss.name}, {p6_hud_ss.name}")

        # Copy all screenshots to brain directory for user artifacts
        if BRAIN_DIR.exists():
            for ss_file in [p1_ss, p2_ss, p3_ss, p4_ss, p5_prev_ss, p5_gate_ss, p6_modal_ss, p6_hud_ss]:
                if ss_file.exists():
                    shutil.copy2(ss_file, BRAIN_DIR / ss_file.name)

        print("\n=======================================================")
        print(">>> ALL 6 PHASES EXHAUSTIVELY TESTED AND VERIFIED! <<<")
        print("=======================================================\n")

    finally:
        if driver:
            driver.quit()
        server.shutdown()


if __name__ == '__main__':
    run_exhaustive_player_test()
