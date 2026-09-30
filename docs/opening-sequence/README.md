# Anis' Home Media Server — opening sequence

A 3.00-second branded opening: build-up → logo impact → two-note motif → wordmark →
**the curtain parts and the app itself is there**, already loaded and already usable.
Original synthesized score, no licensed material, no dependencies at runtime.

**What the outro reveals is the real page, not a picture of it.** The layer is injected
*over* the running app, so when the curtain opens the user sees the app's own header,
its own posters and its own telemetry — live, interactive, untouched. There is no
snapshot, no iframe, no copy: the page underneath was rendered by the app itself.

```
intro-overlay.html      the overlay layer (inject this)         42 KB
serve_with_intro.py     read-only injection proxy (demo)         6.4 KB
cdp_local.py            headless-Edge CDP driver                 7.5 KB
capture_overlay_frames.py  frame capture, both orientations      4.3 KB
encode_videos.py        frames + score -> MP4                    4.3 KB
verify_overlay.py       12 behavioural checks                    7.0 KB
convert_to_overlay.py   asserted record of the conversion        12 KB
render_intro_theme.py   score renderer (stdlib only)             12 KB
intro-theme.wav         score master, 3.070 s, −1.01 dBFS        529 KB
intro-demo.mp4          1920×1080, 90 frames, 3.000 s            2.3 MB
intro-demo-portrait.mp4 1080×1920, 90 frames, 3.000 s            2.5 MB
intro.html              pre-overlay source (input to the conversion)
frames/ frames-portrait/  90 + 90 source frames
still-*.png             key stills at 0.70 / 1.50 / 2.90 s
```

## 1. The sequence

| t | what happens |
| --- | --- |
| 0.00 | black, room tone |
| 0.12 | build-up: light beams, particles converge on the mark, riser |
| 0.62 | **impact** — logo lands, flash, shockwave, camera shake, first note |
| 0.74 | specular sheen sweeps the mark |
| 0.80 / 0.92 | wordmark rises, letter by letter: "Anis'" then "Home Media Server" |
| 1.12 | second note a fifth up, bell layer, pad swells |
| 1.24 / 1.42 | "PLAY • ORGANIZE • ENJOY" letterspaces in; the red rule draws |
| 1.95 | **the curtain parts** |
| 2.26 | halves off-screen; vignette, grain and embers gone |
| 2.57 | lockup fully dismissed — **the app is clickable again** |
| 2.75 – 3.00 | settled hold (frames 2.80–2.97 are byte-identical) |

The whole thing is one deterministic function, `renderAt(t)`, so the same code drives live
playback (rAF) and frame-accurate capture (`INTRO.renderAt(t)`).

## 2. How it sits over the app

`body.intro-mode` puts `#stage` at `z-index:2147483000` — far above the app's own stack
(which tops out at 101) — full-viewport, `position:fixed`, and **transparent wherever it is
not drawing**. The veils are opaque, so nothing of the app shows while they are closed;
when they part, what comes through is the app itself.

Handover is explicit and observable:

- while the layer draws, it owns the pointer, so the app cannot be clicked *through* the intro;
- at **2.57 s**, once the last of it is off-screen, `#stage.handover` drops `pointer-events`,
  so the app is usable the instant it is visible;
- at **3.00 s**, `finish()` sets `display:none` on the layer — nothing of the intro is left
  in the page.

## 3. Modes

| URL | what it does |
| --- | --- |
| `/` (default `gate`) | the click-to-start card, so the theme plays **with sound** |
| `?intro=auto` | straight in; silent until the page is first touched |
| `?intro=capture` | still page: the capture harness drives `renderAt()` itself |
| `?intro=off` | the app untouched — use it to sanity-check the app itself |

The gate exists because browsers refuse to start audio without a gesture: a real trusted
click is what makes the score audible (verified — the AudioContext reads `running`).

## 4. Serving it over the app (read-only)

`serve_with_intro.py` forwards every request to the running app and appends the overlay to
HTML responses. It writes nothing into the app and changes nothing about it — `?intro=off`
is byte-identical to the app's own response.

```bash
python serve_with_intro.py --port 8001 --app http://127.0.0.1:8000
# http://127.0.0.1:8001/   the app wearing the intro
```

To make it permanent in the app itself, include the fragment at the end of the page (so the
app's own scripts have already run) and let the layer be the last thing in the body:

```jinja
{# templates/library.html — at the very end of the file #}
{% include 'intro-overlay.html' %}
```

Gate it per session if you do not want it on every load:

```js
if (!sessionStorage.getItem('introSeen')) {
  INTRO.play();
  sessionStorage.setItem('introSeen', '1');
}
```

`INTRO` exposes `play()`, `skip()`, `replay()`, `finish()`, `renderAt(t)`, `pageMode()`,
`playback()`, `audio`, `timeline`, `duration`.

## 5. Re-rendering the videos

Captured with **local headless Edge over CDP** — same origin as the app, real input events,
no `data:` URLs, no cloud session to drop. `capture_overlay_frames.py` sets the layout
viewport with `Emulation.setDeviceMetricsOverride`, so the app lays out at exactly the
captured size (desktop 1920×1080 for landscape; a 540×960 phone viewport at DPR 2, delivered
as 1080×1920, for portrait).

```bash
python serve_with_intro.py --port 8001 &        # the app wearing the intro
python capture_overlay_frames.py landscape      # -> frames/           (resumable)
python capture_overlay_frames.py portrait       # -> frames-portrait/
python render_intro_theme.py                    # -> intro-theme.wav
python encode_videos.py                         # -> both MP4s
python verify_overlay.py                        # 12 behavioural checks
```

## 6. Verification

Behavioural, against the running app (`verify_overlay.py` — all 12 checks pass):

| check | result |
| --- | --- |
| layer fixed above the app, gate above the layer | z 2147483000 / 2147483001 |
| the layer paints nothing itself | `background: rgba(0,0,0,0)` |
| the app's own page is beneath it | 12 cards, 11 posters, title "Anis' Home Media Server" |
| the sequence is playing after a real click | `playback: playing` |
| audio is really running | AudioContext `running` |
| veils cover the app mid-sequence | transform identity at 1.35 s |
| the layer removed itself at the end | `#stage` `display: none` |
| a real click reaches the app afterwards | `header input#q` took focus |
| capture mode stops the app's clock | `setInterval`/`setTimeout`/rAF are no-ops |
| the app is still rendered under the layer | 12 cards in capture mode |
| the hold is static | frames 2.90 and 2.95 byte-identical |
| the sequence is not static | 1.70 differs from the hold |

Paint evidence (independent vision, on captured frames): at 1.35 s the frame shows **only**
the lockup on a dark field, no library; at 2.90 s it shows the **real library** — real
posters, "Transcoder Standby · Idle · Ready", live telemetry (Memory Bank 65.3 %, Storage
Pool 88.9 %) — with no curtain or overlay left.

Media:

- 90 + 90 frames, 82 unique each; the only identical runs are the two intended holds
  (t = 0.00–0.10 and t = 2.80–2.97).
- Both videos: H.264, 90 frames, `duration 3.000000`, AAC stereo 44.1 kHz 195 kb/s.
- Audio in the videos: RMS −18.88 dB, peak −3.08 dB (theme master: −19.00 / −2.98 dB).

Honest notes:

- Portrait frames were captured at 2160×3840 (DPR 2 × clip scale 2) and downscaled to
  1080×1920 with lanczos — supersampled, so slightly softer-edged than the landscape
  frames, which are a native 1:1 render of the app at 1920×1080.
- One library item (`IMG 5167`) has no artwork in the real library, so it shows the app's own
  placeholder. That is the app being honest, not a capture defect.
- A single mid-sequence screenshot taken during *live* playback once showed the finished
  state; two successive shots and the computed veil transform both contradicted it. The
  frames in `frames/` come from the still capture path, where the same find was impossible —
  see §7.

## 7. Capture realities (learned here)

1. **A page's own clock must be stopped for reproducible frames.** The proxy injects a script
   *before any page script* that replaces `setInterval`/`setTimeout`/rAF with no-ops, so the
   app renders from its server-rendered HTML and then holds perfectly still.
2. **Canvas-only motion is invisible to the screenshot path.** Chrome's capture only refreshes
   when the DOM is damaged, so frames whose only change is on a `<canvas>` come back
   byte-identical. The capture hands the canvas over as an `<img>` (in-page `toDataURL`)
   before each shot.
3. **Screenshots can be one frame stale** — prefer the computed state plus two shots over any
   single screenshot.
4. **`elementFromPoint` measures hit-testing, not painting.** With `pointer-events:none` on the
   layer it walks straight through to the app and looks exactly like a stacking bug. It is not
   evidence about what is painted.
5. **`Emulation.*` is a page-domain method.** `setDeviceMetricsOverride` before the first
   navigation fails with "wasn't found"; create the page first.
6. **The layer must not leak CSS onto the app.** The standalone file styles `html,body`
   (`height:100%`, `overflow:hidden`, its own background) — fine alone, wrong when injected: it
   overrode the app's body background (measured: `rgb(5,6,10)` instead of the app's `#090b10`)
   and stopped its scrolling. Skin the layer, not the document, when the document belongs to
   the app.

## 8. Applying it for real

Nothing here touches the app: `E:/MediaServer` is unmodified by this work (the only dirty
entries belong to another session's Flutter client). To apply, add the fragment include and
optionally the per-session gate from §4 — the overlay needs no build step, no assets and no
network of its own. For the Flutter client, `intro-demo-portrait.mp4` is a finished
1080×1920 asset and native playback has no autoplay restriction.