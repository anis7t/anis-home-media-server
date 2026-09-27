"""Headless Selenium E2E test verifying multi-seek across chunk boundaries on Coyote vs. Acme.

Ensures no DEMUXER_ERROR_COULD_NOT_PARSE, no DTS sequence errors, and no auto-reset to beginning.

By default this test serves the application itself on an ephemeral port, using the isolated cache
and database that tests/conftest.py points the app at. Set MEDIA_SERVER_LIVE_TESTS=1 to run it
against the live production service on port 8000 instead (it then drives - and writes to - the
real instance).
"""
import os
import sys
import time
import threading
from pathlib import Path
from werkzeug.serving import make_server
from selenium import webdriver
from selenium.webdriver.chrome.options import Options

# Add project root to sys.path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app import create_app


class ServerThread(threading.Thread):
    def __init__(self, app, port=0):
        super().__init__(daemon=True)
        self.server = make_server("127.0.0.1", port, app)
        self.ctx = app.app_context()
        self.ctx.push()

    @property
    def port(self):
        """The port actually bound (0 requests an ephemeral one)."""
        return self.server.server_port

    def run(self):
        self.server.serve_forever()

    def shutdown(self):
        self.server.shutdown()


def test_coyote_multi_seek_no_reset():
    """Verify multiple forward seeks across chunk boundaries on Coyote vs. Acme without auto-reset to 0:00."""
    import pytest
    import app as app_module
    from app.services.media_service import safe_path
    from app.services.transcode_service import hls_cache_dir

    app_module.CACHE_DIR = app_module.config.CACHE_DIR
    coyote_path = safe_path("Coyote.vs.Acme.2026.1080p.HEVC.x265.RMTeam.mkv")
    if not coyote_path:
        pytest.skip("Coyote vs. Acme media file not present on test host")

    server = None

    # This test must never drive the production service. It used to prefer a live server on port
    # 8000 whenever one answered, which pointed a real browser at production and wrote watch
    # history into the live database (verified 2026-09-27: device_watch_history rows appeared
    # during a suite run). It now always starts its own in-process app - conftest points that app
    # at the throwaway cache/database tree - and only uses the live service on explicit opt-in.
    live_opt_in = os.environ.get("MEDIA_SERVER_LIVE_TESTS") == "1"
    if live_opt_in:
        port = 8000
    else:
        app = create_app()
        # Seeking here needs the rendered HLS cache, and the isolated cache holds no Coyote
        # segments. Skip honestly instead of failing: the in-process mode exists to be host-safe,
        # not to pretend the production cache is present.
        try:
            isolated_hls_ready = (hls_cache_dir(coyote_path) / "playlist.m3u8").exists()
        except Exception:
            isolated_hls_ready = False
        if not isolated_hls_ready:
            pytest.skip(
                "Coyote HLS cache is absent from the isolated test cache - run with "
                "MEDIA_SERVER_LIVE_TESTS=1 to exercise the live cache"
            )
        server = ServerThread(app)
        server.start()
        port = server.port
        time.sleep(1)

    driver = None
    try:
        opts = Options()
        opts.add_argument("--headless=new")
        opts.add_argument("--disable-gpu")
        opts.add_argument("--window-size=1280,800")
        opts.add_argument("--mute-audio")
        opts.add_argument("--autoplay-policy=no-user-gesture-required")
        opts.set_capability('goog:loggingPrefs', {'browser': 'ALL'})

        driver = webdriver.Chrome(options=opts)
        driver.set_page_load_timeout(25)

        target_url = f"http://127.0.0.1:{port}/watch/Coyote.vs.Acme.2026.1080p.HEVC.x265.RMTeam.mkv"
        driver.get(target_url)
        time.sleep(2)

        # Start playback
        # Wait up to 10s for video readiness
        for _ in range(20):
            ready = driver.execute_script("const v = document.querySelector('video'); return v && (v.readyState >= 1 || (v.duration && v.duration > 0));")
            if ready:
                break
            time.sleep(0.5)

        driver.execute_script("document.querySelector('video')?.play().catch(()=>{});")
        time.sleep(1.5)

        seek_points = [60, 180, 360, 450, 600]
        for seek_to in seek_points:
            # Perform seek via seek slider and video currentTime
            driver.execute_script(f"""
                const v = document.querySelector('video');
                v.currentTime = {seek_to};
                if (typeof window.checkPreparing === 'function') window.checkPreparing({seek_to});
            """)

            # Bounded polling up to 6s for seek to apply
            cur_time = 0.0
            for _ in range(12):
                cur_time = float(driver.execute_script("return document.querySelector('video').currentTime || 0;"))
                if cur_time >= seek_to - 2.0:
                    break
                time.sleep(0.5)

            # Video currentTime must be at or past the seek target, and not reset to near 0 (< 10)
            assert cur_time >= seek_to - 2.0, f"Seek to {seek_to}s failed; currentTime={cur_time}s"
            assert cur_time > 10.0, f"Video reset to beginning; currentTime={cur_time}s"

        # Check console logs for demuxer errors
        logs = driver.get_log('browser')
        for entry in logs:
            msg = entry.get('message', '')
            assert "DEMUXER_ERROR_COULD_NOT_PARSE" not in msg, f"Demuxer error in console: {msg}"
            assert "Parsed buffers not in DTS sequence" not in msg, f"DTS sequence error in console: {msg}"

    finally:
        if driver:
            try:
                driver.quit()
            except Exception:
                pass
        try:
            server.shutdown()
        except Exception:
            pass


if __name__ == '__main__':
    test_coyote_multi_seek_no_reset()
    print("ALL TESTS PASSED!")