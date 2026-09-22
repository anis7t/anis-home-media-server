"""Live, visible browser check of the healed Spider-Man HLS stream.

Drives the running service (port 8000) in a real Chrome window, seeks to the chunk boundaries
that used to be destroyed (the 8.44s / 7.24s packet gaps sat at multiples of 60s), and proves
each position plays: currentTime advances after the seek, readyState recovers, and the console
carries no demuxer/decode errors. Saves screenshots as evidence.
"""
import json
import sys
import time
import urllib.parse
from pathlib import Path

from selenium import webdriver
from selenium.webdriver.chrome.options import Options

MOVIE = "Spider-Man- Brand New Day 2026.1080p.HQ Pre.Multi.AAC 2.0.x264.mkv"
OUT = Path(r"C:\MediaServer\_browser_evidence")
OUT.mkdir(exist_ok=True)
url = f"http://127.0.0.1:8000/watch/{urllib.parse.quote(MOVIE)}"
# boundaries that held the biggest holes before the heal (85 gaps, all at multiples of 60s)
SEEKS = [100, 1680, 2700, 3600, 3720, 4260, 4680, 5460, 7200]

opts = Options()
opts.add_argument("--window-size=1440,900")
opts.add_argument("--mute-audio")
opts.add_argument("--autoplay-policy=no-user-gesture-required")
opts.set_capability("goog:loggingPrefs", {"browser": "ALL"})
driver = webdriver.Chrome(options=opts)
driver.set_page_load_timeout(30)

results = []
try:
    driver.get(url)
    time.sleep(3)
    ready = driver.execute_script(
        "const v=document.querySelector('video'); return v ? {rs: v.readyState, d: v.duration} : null;")
    print("player:", ready)
    driver.execute_script("document.querySelector('video')?.play().catch(()=>{});")
    time.sleep(2)

    for target in SEEKS:
        driver.execute_script(f"""
            const v = document.querySelector('video');
            v.currentTime = {target};
            if (typeof window.checkPreparing === 'function') window.checkPreparing({target});
        """)
        row = {"seek": target}
        st = None
        for _ in range(24):                       # up to 12s to land and start playing
            st = driver.execute_script("""
                const v = document.querySelector('video');
                if (!v) return null;
                let buf = 0;
                try { for (let i = 0; i < v.buffered.length; i++)
                    if (v.buffered.start(i) <= v.currentTime && v.currentTime <= v.buffered.end(i))
                        buf = v.buffered.end(i) - v.currentTime; } catch (e) {}
                return {t: v.currentTime, rs: v.readyState, buf: buf, paused: v.paused, err: v.error ? v.error.code : 0};
            """)
            if st and st["t"] >= target - 2.0 and st["rs"] >= 2:
                break
            time.sleep(0.5)
        row.update(st or {})
        # does it actually advance from here?  (a hole in the HLS stalls or jumps instead)
        t0 = driver.execute_script("return document.querySelector('video').currentTime;")
        time.sleep(2.5)
        t1 = driver.execute_script("return document.querySelector('video').currentTime;")
        row["advanced_s"] = round(t1 - t0, 2)
        row["ok"] = (row.get("t", 0) >= target - 2.0 and row["advanced_s"] >= 0.3 and row.get("err", 0) == 0)
        results.append(row)
        print(json.dumps(row))
        if target in (1680, 3720, 7200):
            driver.save_screenshot(str(OUT / f"seek_{target}.png"))

    logs = [e.get("message", "") for e in driver.get_log("browser")]
    bad = [m for m in logs if any(k in m for k in
           ("DEMUXER_ERROR", "not in DTS sequence", "MEDIA_ERR_DECODE", "bufferStalledError"))]
    print("\nscreenshot dir:", OUT)
    print("console errors:", bad[:5] if bad else "none")
    failed = [r for r in results if not r["ok"]]
    print(f"RESULT: {len(results) - len(failed)}/{len(results)} seeks played cleanly")
    if failed:
        print("FAILED:", json.dumps(failed, indent=1))
    sys.exit(1 if (failed or bad) else 0)
finally:
    driver.quit()