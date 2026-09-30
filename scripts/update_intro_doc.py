import sys

path = "docs/OPENING_SEQUENCE.md"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

NL = "\n"

# === Section 2 ===
old_s2_lines = [
    "## 2. Where the artifacts live", "",
    "Nothing in this document has been applied to the app: no application file was changed for it, and",
    "the overlay is served over the app by a read-only proxy. Everything is in",
    "`C:\\Users\\anis7\\Documents\\Anis-Media-Server-Intro\\`:", "",
    "| File | What it is |", "|---|---|",
    "| `intro-overlay.html` | **the deliverable** \u2014 the overlay layer to inject (42,859 bytes, self-contained) |",
    "| `serve_with_intro.py` | read-only injection proxy \u2014 forwards every request, rewrites only `text/html` |",
    "| `cdp_local.py` | headless-Edge CDP driver (launch, attach, evaluate, real clicks, clipped captures) |",
    "| `capture_overlay_frames.py` | 90-frame capture per orientation, resumable, with a duplicate-run audit |",
    "| `encode_videos.py` | normalises rasters and encodes both cuts with the score |",
    "| `render_intro_theme.py` | the score's source (standard library only) |",
    "| `verify_overlay.py` | 12 behavioural checks against the running server |",
    "| `convert_to_overlay.py` | asserted, reproducible record of the standalone\u2192overlay conversion |",
    "| `intro.html` | pre-overlay source, kept as the conversion's input |",
    "| `intro-theme.wav` | score master \u2014 3.070 s, 44.1 kHz stereo, peak \u22121.01 dBFS |",
    "| `intro-demo.mp4` | 1920\u00d71080, 30 fps, 90 frames, 3.000 s, H.264 CRF 17 + AAC 192 kbps |",
    "| `intro-demo-portrait.mp4` | 1080\u00d71920, same encoding \u2014 for the Flutter client |",
    "| `README.md` | full specs, integration notes, capture realities, verification table |",
    "| `frames/`, `frames-portrait/` | 90 PNGs each, captured over the live app (regenerable) |",
]
new_s2_lines = [
    "## 2. Where the artifacts live", "",
    "Everything for this work lives inside the repository in `docs/opening-sequence/`:", "",
    "| Path | What it is |", "|---|---|",
    "| `docs/opening-sequence/scripts/serve_with_intro.py` | read-only injection proxy \u2014 forwards every request, rewrites only `text/html` |",
    "| `docs/opening-sequence/scripts/cdp_local.py` | headless-Edge CDP driver (launch, attach, evaluate, real clicks, clipped captures) |",
    "| `docs/opening-sequence/scripts/capture_overlay_frames.py` | 90-frame capture per orientation, resumable, with a duplicate-run audit |",
    "| `docs/opening-sequence/scripts/encode_videos.py` | normalises rasters and encodes both cuts with the score |",
    "| `docs/opening-sequence/scripts/render_intro_theme.py` | the score's source (standard library only) |",
    "| `docs/opening-sequence/scripts/verify_overlay.py` | 12 behavioural checks against the running server |",
    "| `docs/opening-sequence/scripts/verify_app_integration.py` | live-service verifier \u2014 drives the real app, all checks pass |",
    "| `docs/opening-sequence/scripts/convert_to_overlay.py` | asserted, reproducible record of the standalone\u2192overlay conversion |",
    "| `docs/opening-sequence/source/intro.html` | pre-overlay source, kept as the conversion's input |",
    "| `docs/opening-sequence/source/intro-overlay.html` | copy of the overlay layer (canonical copy is `templates/intro-overlay.html`) |",
    "| `docs/opening-sequence/assets/intro-theme.wav` | score master \u2014 3.070 s, 44.1 kHz stereo, peak \u22121.01 dBFS |",
    "| `docs/opening-sequence/assets/intro-demo.mp4` | 1920\u00d71080, 30 fps, 90 frames, 3.000 s, H.264 CRF 17 + AAC 192 kbps |",
    "| `docs/opening-sequence/assets/intro-demo-portrait.mp4` | 1080\u00d71920, same encoding \u2014 for the Flutter client |",
    "| `docs/opening-sequence/assets/stills/` | keystills from the encoded videos |",
    "| `docs/opening-sequence/frames/` | 90 PNGs landscape, captured over the live app (regenerable) |",
    "| `docs/opening-sequence/frames-portrait/` | 90 PNGs portrait |",
    "| `docs/opening-sequence/README.md` | full specs, integration notes, capture realities, verification table |",
]
old_s2 = NL.join(old_s2_lines) + NL
new_s2 = NL.join(new_s2_lines) + NL
assert old_s2 in content, "S2 FAIL"
content = content.replace(old_s2, new_s2)
print("S2 OK")

# === Section 5 ===
old_s5 = "## 5. Wiring it in (not done)" + NL + NL + "```bash" + NL
old_s5 += "# see it over the running app without changing anything" + NL
old_s5 += "python serve_with_intro.py --port 8001 --app http://127.0.0.1:8000" + NL
old_s5 += "# http://127.0.0.1:8001/          the app wearing the intro" + NL
old_s5 += "# http://127.0.0.1:8001/?intro=off  the app bare, for comparison" + NL
old_s5 += "```" + NL + NL
old_s5 += "To make it permanent, copy `intro-overlay.html` into `templates/` and include it as the **last** thing" + NL
old_s5 += "in the page, so the app's own scripts have already run and what the curtain opens onto is a fully" + NL
old_s5 += "initialised page:" + NL + NL
old_s5 += "```jinja" + NL + "{# templates/library.html \u2014 at the very end of the file #}" + NL
old_s5 += "{% include 'intro-overlay.html' %}" + NL + "```" + NL + NL
old_s5 += "Gate it per session if it should not play on every load:" + NL + NL
old_s5 += "```js" + NL + "if (!sessionStorage.getItem('introSeen')) {" + NL
old_s5 += "  INTRO.play();" + NL + "  sessionStorage.setItem('introSeen', '1');" + NL + "}" + NL + "```" + NL + NL
old_s5 += "`window.INTRO` exposes `play()`, `skip()`, `replay()`, `finish()`, `renderAt(t)`, `pageMode()`," + NL
old_s5 += "`playback()`, `audio`, `timeline`, `duration`. The overlay needs no build step, no assets and no" + NL
old_s5 += "network of its own; for the Flutter client, `intro-demo-portrait.mp4` is a finished 1080\u00d71920 asset and" + NL
old_s5 += "native playback has no autoplay restriction."

new_s5 = "## 5. How it is wired into the app" + NL + NL
new_s5 += "The overlay is included as the **last** thing in `templates/library.html`, so the app's own scripts have" + NL
new_s5 += "already run and what the curtain opens onto is a fully initialised page:" + NL + NL
new_s5 += "```jinja" + NL + "{# templates/library.html \u2014 at the very end of the file #}" + NL
new_s5 += "{% include 'intro-overlay.html' %}" + NL + "```" + NL + NL
new_s5 += "It is gated **once per browser session** so it does not play on every load:" + NL + NL
new_s5 += "```js" + NL + "if (!sessionStorage.getItem('introSeen')) {" + NL
new_s5 += "  INTRO.play();" + NL + "  sessionStorage.setItem('introSeen', '1');" + NL + "}" + NL + "```" + NL + NL
new_s5 += "`window.INTRO` exposes `play()`, `skip()`, `replay()`, `finish()`, `renderAt(t)`, `pageMode()`," + NL
new_s5 += "`playback()`, `audio`, `timeline`, `duration`. The overlay needs no build step, no assets and no" + NL
new_s5 += "network of its own; for the Flutter client, `docs/opening-sequence/assets/intro-demo-portrait.mp4` is" + NL
new_s5 += "a finished 1080\u00d71920 asset and native playback has no autoplay restriction." + NL + NL
new_s5 += "To see it over the running app **without touching the app at all** (the read-only proxy, useful for" + NL
new_s5 += "re-verification after re-rendering):" + NL + NL
new_s5 += "```bash" + NL
new_s5 += "python docs/opening-sequence/scripts/serve_with_intro.py --port 8001 --app http://127.0.0.1:8000" + NL
new_s5 += "# http://127.0.0.1:8001/          the app wearing the intro" + NL
new_s5 += "# http://127.0.0.1:8001/?intro=off  the app bare, for comparison" + NL + "```"

assert old_s5 in content, "S5 FAIL"
content = content.replace(old_s5, new_s5)
print("S5 OK")

# === Section 6 ===
old_s6 = "```bash" + NL
old_s6 += "python serve_with_intro.py --port 8001 &        # the app wearing the intro" + NL
old_s6 += "python capture_overlay_frames.py landscape      # -> frames/           (resumable)" + NL
old_s6 += "python capture_overlay_frames.py portrait       # -> frames-portrait/" + NL
old_s6 += "python render_intro_theme.py                    # -> intro-theme.wav" + NL
old_s6 += "python encode_videos.py                         # -> both MP4s" + NL
old_s6 += "python verify_overlay.py                        # 12 behavioural checks" + NL + "```"

new_s6 = "```bash" + NL
new_s6 += "python docs/opening-sequence/scripts/serve_with_intro.py --port 8001 &        # the app wearing the intro" + NL
new_s6 += "python docs/opening-sequence/scripts/capture_overlay_frames.py landscape      # -> frames/           (resumable)" + NL
new_s6 += "python docs/opening-sequence/scripts/capture_overlay_frames.py portrait       # -> frames-portrait/" + NL
new_s6 += "python docs/opening-sequence/scripts/render_intro_theme.py                    # -> assets/intro-theme.wav" + NL
new_s6 += "python docs/opening-sequence/scripts/encode_videos.py                         # -> both MP4s" + NL
new_s6 += "python docs/opening-sequence/scripts/verify_overlay.py                        # 12 behavioural checks" + NL + "```"

assert old_s6 in content, "S6 FAIL"
content = content.replace(old_s6, new_s6)
print("S6 OK")

# === Section 9 last line ===
old_last = "- Nothing was committed for this work, and no application behaviour depends on it."
new_last = ("- The rendered artifacts (`frames/`, `frames-portrait/`, the MP4s and the WAV) are regenerable from\n  the scripts and the live app; they are kept here as the delivered deliverables and for re-verification.\n")
assert old_last in content, "S9 FAIL"
content = content.replace(old_last, new_last)
print("S9 OK")

with open(path, "w", encoding="utf-8", newline="") as f:
    f.write(content)
print("ALL DONE")
