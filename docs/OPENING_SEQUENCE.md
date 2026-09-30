# Opening Sequence — Brand Sting for Anis' Home Media Server

Last reviewed: 2026-09-30
Status: **delivered standalone — not wired into the application**
Artifacts: `C:\Users\anis7\Documents\Anis-Media-Server-Intro\` (deliberately outside this repository)

---

## 1. What it is

A 3.00-second branded opening for the server: build-up → logo impact → two-note motif → wordmark →
the curtain parts onto the app itself. The score is an original composition synthesized from scratch
(no samples, nothing licensed); the whole animation is one deterministic function of time,
`renderAt(t)`, so the same code drives live playback and frame-accurate video rendering.

**The outro reveals the real page, not a copy of it.** The sequence is injected *over* the running
app, so when the curtain opens the user sees the app's own header, its own posters and its own
telemetry — live, interactive and untouched. An earlier cut rendered a script-stripped snapshot of
the library into a sandboxed iframe; the owner rejected that outright ("I don't like the idea of
having a library snapshot… it reveals the app itself ready to use"), and both the snapshot file and
its builder were deleted.

## 2. Where the artifacts live

Nothing in this document has been applied to the app: no application file was changed for it, and
the overlay is served over the app by a read-only proxy. Everything is in
`C:\Users\anis7\Documents\Anis-Media-Server-Intro\`:

| File | What it is |
|---|---|
| `intro-overlay.html` | **the deliverable** — the overlay layer to inject (42,859 bytes, self-contained) |
| `serve_with_intro.py` | read-only injection proxy — forwards every request, rewrites only `text/html` |
| `cdp_local.py` | headless-Edge CDP driver (launch, attach, evaluate, real clicks, clipped captures) |
| `capture_overlay_frames.py` | 90-frame capture per orientation, resumable, with a duplicate-run audit |
| `encode_videos.py` | normalises rasters and encodes both cuts with the score |
| `render_intro_theme.py` | the score's source (standard library only) |
| `verify_overlay.py` | 12 behavioural checks against the running server |
| `convert_to_overlay.py` | asserted, reproducible record of the standalone→overlay conversion |
| `intro.html` | pre-overlay source, kept as the conversion's input |
| `intro-theme.wav` | score master — 3.070 s, 44.1 kHz stereo, peak −1.01 dBFS |
| `intro-demo.mp4` | 1920×1080, 30 fps, 90 frames, 3.000 s, H.264 CRF 17 + AAC 192 kbps |
| `intro-demo-portrait.mp4` | 1080×1920, same encoding — for the Flutter client |
| `README.md` | full specs, integration notes, capture realities, verification table |
| `frames/`, `frames-portrait/` | 90 PNGs each, captured over the live app (regenerable) |

## 3. The sequence

| t (s) | Cue | On screen |
|---|---|---|
| 0.00 | — | black, room tone |
| 0.12 | `streak` | light beams build; particles converge on the mark; riser |
| 0.62 | `impact` | logo lands — flash, shockwave, camera shake, first note |
| 0.74 | `sheen` | specular sweep across the mark |
| 0.80 / 0.92 | `w1` / `w2` | "Anis'" then "Home Media Server" rise, letter by letter |
| 1.12 | `hit2` | second note a fifth up, bell layer, pad swells |
| 1.24 / 1.42 | `sub` / `rule` | PLAY • ORGANIZE • ENJOY letterspaces in; the red rule draws |
| 1.95 | `curtain` | **the curtain parts** |
| 2.26 | `curtainEnd` | halves off-screen; vignette, grain and embers gone |
| 2.57 | — | lockup fully dismissed — **the app is clickable again** |
| 2.75 – 3.00 | — | settled hold (frames 2.80 – 2.97 are byte-identical) |

## 4. How it sits over the app

- `body.intro-mode` puts the layer at `z-index:2147483000`, `position:fixed; inset:0`, and
  **transparent wherever it is not drawing** — well above the app's own stack (which tops out at 101).
  The veils are opaque, so nothing of the app shows until they part; after that, the app is what comes
  through.
- While it draws, the layer owns the pointer, so the app cannot be clicked *through* the intro. At
  `T.curtain+0.62` (2.57 s), `#stage.handover` releases `pointer-events`; at 3.00 s `finish()` hides
  the root and clears the capture class, leaving nothing of the intro in the page.
- **The layer must not skin the document.** A standalone page styles `html,body`; injected, those
  rules override the app's own (measured: the app's `#090b10` body background was replaced and its
  scrolling stopped). Every rule is scoped to `body.intro-mode …`, and because injected rules come
  after the app's they win at equal specificity.

### Modes (query string on any HTML request)

| URL | Behaviour |
|---|---|
| `/` (default `gate`) | the click-to-start card, so the theme plays **with sound** |
| `?intro=auto` | straight in; silent until the page is first touched |
| `?intro=capture` | still page — the capture harness drives `renderAt()` itself |
| `?intro=off` | the app untouched, byte-for-byte — used to prove the proxy adds nothing else |

The gate exists because browsers refuse to start audio without a gesture; a real trusted click is what
makes the score audible (verified: the AudioContext reads `running`).

## 5. Wiring it in (not done)

```bash
# see it over the running app without changing anything
python serve_with_intro.py --port 8001 --app http://127.0.0.1:8000
# http://127.0.0.1:8001/          the app wearing the intro
# http://127.0.0.1:8001/?intro=off  the app bare, for comparison
```

To make it permanent, copy `intro-overlay.html` into `templates/` and include it as the **last** thing
in the page, so the app's own scripts have already run and what the curtain opens onto is a fully
initialised page:

```jinja
{# templates/library.html — at the very end of the file #}
{% include 'intro-overlay.html' %}
```

Gate it per session if it should not play on every load:

```js
if (!sessionStorage.getItem('introSeen')) {
  INTRO.play();
  sessionStorage.setItem('introSeen', '1');
}
```

`window.INTRO` exposes `play()`, `skip()`, `replay()`, `finish()`, `renderAt(t)`, `pageMode()`,
`playback()`, `audio`, `timeline`, `duration`. The overlay needs no build step, no assets and no
network of its own; for the Flutter client, `intro-demo-portrait.mp4` is a finished 1080×1920 asset and
native playback has no autoplay restriction.

## 6. Re-rendering the videos

Captured with **local headless Edge over CDP** — same origin as the app, real input events, no `data:`
URLs and no cloud session to drop (Edge is on every Windows host, so no new dependency is needed).

```bash
python serve_with_intro.py --port 8001 &        # the app wearing the intro
python capture_overlay_frames.py landscape      # -> frames/           (resumable)
python capture_overlay_frames.py portrait       # -> frames-portrait/
python render_intro_theme.py                    # -> intro-theme.wav
python encode_videos.py                         # -> both MP4s
python verify_overlay.py                        # 12 behavioural checks
```

`capture_overlay_frames.py` sets the layout viewport with `Emulation.setDeviceMetricsOverride`, so the
app lays out at exactly the captured size — desktop 1920×1080 for landscape, and a 540×960 phone
viewport at DPR 2 (delivered as 1080×1920) for portrait, which makes the app render **its own** mobile
layout rather than a scaled desktop one.

## 7. Verification

`verify_overlay.py`, against the running server — 12/12 pass:

| Check | Result |
|---|---|
| layer fixed above the app, gate above the layer | z 2147483000 / 2147483001 |
| the layer paints nothing of its own | `background: rgba(0,0,0,0)` |
| the app's own page is beneath it | 11 cards, 11 posters, title "Anis' Home Media Server" |
| a real click starts the sequence | `playback: playing` |
| audio is really running | AudioContext `running` |
| veils cover the app mid-sequence | transform identity at 1.35 s |
| the layer removed itself at the end | `#stage` `display: none` |
| **a real click reaches the app afterwards** | `header input#q` took focus |
| capture mode stops the app's clock | `setInterval`/`setTimeout`/rAF are no-ops |
| the app is still rendered under the layer | 11 cards in capture mode |
| the hold is static / the sequence is not | f(2.90) ≡ f(2.95); f(1.70) differs |

Media: both videos `ffprobe` at 90 frames and `duration 3.000000` with a real AAC track (RMS −18.88 dB,
peak −3.08 dB; score master −19.00 / −2.98 dB). Frames: 90 + 90, 82 unique each, and the only identical
runs are the two intended holds (t 0.00 – 0.10 and 2.80 – 2.97). Independent visual verification (a
different model) on frames captured through this pipeline: at 1.35 s only the lockup on a dark field
with no library visible; at 2.90 s the real library — "Transcoder Standby · Idle · Ready", live
telemetry (Memory Bank 65.3 %, Storage Pool 88.9 %) — with no curtain or overlay left.

## 8. Rendering notes worth keeping

1. **A page's own clock must be stopped for reproducible frames.** The proxy injects, *before any page
   script*, a script that replaces `setInterval`/`setTimeout`/rAF with no-ops. A server-rendered page
   then renders fully from its own HTML and holds still — with a live app, no tail could be
   byte-identical.
2. **Canvas-only motion is invisible to the screenshot path.** Chrome's capture only refreshes when the
   DOM is damaged, so frames whose only change is on a `<canvas>` come back byte-identical. The capture
   hands the canvas over as a DOM `<img>` (in-page `toDataURL`) before each shot.
3. **Screenshots can be one frame stale.** One shot during live playback showed the finished state while
   the computed styles and a second shot both showed mid-flight. Prefer computed state + a repeat shot.
4. **`elementFromPoint` measures hit-testing, not painting.** With `pointer-events:none` on the layer it
   walks straight through to the app and looks exactly like a stacking bug; it is not evidence about
   what is painted. (`pointer-events` inherits, so `none` on the root silences the whole subtree.)
5. **`Emulation.*` is a page-domain method.** `setDeviceMetricsOverride` before the first navigation
   fails with *"wasn't found"*; create the page first.
6. **The capture mode must hide the gate.** The first capture run produced 90 identical frames because
   the opaque click-to-start card sat above the layer at z-index 2147483001 — the entire video was of
   the gate. Caught because three different times returned the same md5.

## 9. Honest notes

- Portrait frames are captured at 2160×3840 (DPR 2 × clip scale 2) and Lanczos-downscaled to 1080×1920
  — supersampled, hence slightly softer-edged than the landscape frames, which are a native 1:1 render
  of the app at 1920×1080.
- One library item (`IMG 5167`) has no artwork in the real library, so it shows the app's own
  placeholder. That is the app being accurate, not a capture defect.
- The videos show the library **as it stood at capture time**; re-run the capture + encode after
  library changes.
- Nothing was committed for this work, and no application behaviour depends on it.