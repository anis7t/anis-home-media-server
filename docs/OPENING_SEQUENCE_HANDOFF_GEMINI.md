# Handoff: brand opening animation — in-tree and wired (session 20260928_014704_eb3daf)

**Repo:** `anis7t/anis-home-media-server` (https://github.com/anis7t/anis-home-media-server.git)
**Branch:** `feat/flutter-production-player` — HEAD `16c6920` (pushed; `origin` is ahead by 2 commits vs this branch base)
**Model pin:** `--model "gemini-3.8-flash-high" --effort high` (Antigravity `agy`). Do not drift to another model.
**What is done:** the opening-sequence artifacts were moved in-tree and the overlay is wired and live. Treat this as a maintenance/verification continuation, not a build-from-scratch.

---

## What you are picking up

Two commits already landed:

- `a10e9ef feat(intro): wire the brand opening sequence into the library page` — the overlay layer
  `templates/intro-overlay.html` was written, `templates/library.html` was modified to `{% include
  'intro-overlay.html' %}` at the very end of the file, and the per-session gate was added:

  ```js
  if (!sessionStorage.getItem('introSeen')) {
    INTRO.play();
    sessionStorage.setItem('introSeen', '1');
  }
  ```

  That commit also added `docs/OPENING_SEQUENCE.md`, a `PROJECT_STATUS.md` §0 pointer, and an `AGENTS.md`
  §1 pointer — but at that point the artifacts still lived **outside** the repo at
  `C:\Users\anis7\Documents\Anis-Media-Server-Intro\`.

- `16c6920 feat(intro): move opening-sequence artifacts in-tree and wire the overlay` — the session's
  migration commit. Everything moved into `docs/opening-sequence/` inside the repo, `docs/OPENING_SEQUENCE.md`
  was rewritten for in-repo paths (section 5 renamed from "Wiring it in (not done)" to "How it is wired into
  the app"), `PROJECT_STATUS.md` §0 and `AGENTS.md` §1 were updated, and `.gitignore` was left alone on purpose
  (the frames/videos/WAV are deliberately tracked).

The canonical overlay is `templates/intro-overlay.html`. A copy lives at
`docs/opening-sequence/source/intro-overlay.html` (asserted identical to the template copy).

---

## Where everything is now (ground truth)

In-repo layout under `docs/opening-sequence/`:

- `scripts/` — `serve_with_intro.py`, `cdp_local.py`, `capture_overlay_frames.py`, `encode_videos.py`,
  `render_intro_theme.py`, `verify_overlay.py`, `verify_app_integration.py`, `convert_to_overlay.py`
- `assets/` — `intro-theme.wav`, `intro-demo.mp4`, `intro-demo-portrait.mp4`, and `assets/stills/` (6 PNG
  keystills: `still-landscape-0.70/1.50/2.90.png`, `still-portrait-0.70/1.50/2.90.png`)
- `frames/` — 90 landscape PNGs (`f_0000.png` … `f_0089.png`)
- `frames-portrait/` — 90 portrait PNGs
- `source/` — `intro.html` (pre-overlay source / conversion input) and `intro-overlay.html` (copy of the
  layer)
- `README.md` — the folder's own full spec
- `scripts/update_intro_doc.py` — the migration script the stalled session wrote; it already ran and updated
  `docs/OPENING_SEQUENCE.md`. Do not re-run it: its `old_s2`/`old_s5`/`old_s6` assertions reference the old
  outside layout and would now fail.

Outside the repo, `C:\Users\anis7\Documents\Anis-Media-Server-Intro\` **still contains a full duplicate** of the
source tree at the same timestamps/contents (294 MB): the scripts, the two MP4s, the WAV, `intro-overlay.html`,
`intro.html`, the 6 stills, the two frame dirs, and `README.md`. That outside copy was the source for the move
and is now stale/duplicate — see Open items.

The wired overlay itself is `templates/intro-overlay.html` (43 KB, committed). It exposes
`window.INTRO = { timeline, duration, renderAt(t), play(), skip(), replay(), finish(), audio, reduced,
pageMode(), playback(), version: '1.2.0' }`. Modes are query-string driven: `/` (default `gate`), `?intro=auto`,
`?intro=capture`, `?intro=off`.

---

## What the overlay actually does (for continuity)

- 3.00 s branded opening: build-up → logo impact (0.62 s) → two-note motif → wordmark raises ("Anis'" then
  "Home Media Server") → PLAY • ORGANIZE • ENJOY letterspaces in with the red rule → curtain parts at 1.95 s →
  halves off-screen by 2.26 s → lockup fully dismissed at 2.57 s → settled hold to 3.00 s (frames 2.80–2.97 are
  byte-identical). Original synthesized score, no samples/licensed material, 3.070 s WAV master.
- The outro reveals the **real app page**, not a snapshot/copy. The layer sits at `z-index:2147483000`,
  `position:fixed; inset:0`, transparent except where it is drawing; the veils are opaque until they part.
- While drawing, the layer owns the pointer (`pointer-events` on), so the app cannot be clicked through the intro.
  At 2.57 s `#stage.handover` releases it; at 3.00 s `finish()` hides the root and clears the `intro-capture`
  class, leaving nothing of the intro in the page.
- The layer must not skin the document: every rule is scoped to `body.intro-mode …`, and injected rules come after
  the app's so they win at equal specificity.
- `?intro=off` is the control case: it must return the app's response byte-for-byte. **There is a known defect in
  the proxy's off-mode** — see Open items.

---

## Verification baseline (already established, re-run rather than trust)

`docs/opening-sequence/scripts/verify_overlay.py` — 12/12 behavioural checks against the running server, all pass:

- layer fixed above the app (z 2147483000 stage / 2147483001 gate); background `rgba(0,0,0,0)`
- app's own page beneath it (11 cards, 11 posters, title "Anis' Home Media Server")
- a real click starts the sequence (`playback: playing`); AudioContext reaches `running`
- veils cover the app mid-sequence (transform identity at 1.35 s)
- layer removes itself at the end (`#stage` `display: none`)
- a real click reaches the app afterwards (`header input#q` took focus)
- capture mode stops the app's clock (`setInterval`/`setTimeout`/rAF are no-ops); 11 cards still rendered
- hold is static / sequence is not: f(2.90) ≡ f(2.95); f(1.70) differs

Media: both videos ffprobe at 90 frames and `duration 3.000000` with a real AAC track (RMS −18.88 dB, peak
−3.08 dB; score master −19.00 / −2.98 dB). Frames: 90 + 90, 82 unique each; the only identical runs are the two
intended holds (t 0.00–0.10 and 2.80–2.97).

Independent visual verification (a different model) on captured frames: at 1.35 s only the lockup on a dark field,
no library; at 2.90 s the real library ("Transcoder Standby · Idle · Ready", live telemetry — Memory Bank 65.3 %,
Storage Pool 88.9 %) with no curtain or overlay left. At 2.90 s portrait, the app's own phone layout (stacked
header, 4-up poster grid).

---

## Capture harness (for re-rendering)

Local headless Edge over CDP — same origin as the app, real input events, no `data:` URLs, no cloud session to
drop. Edge ships on Windows; `websockets` is already installed; no new dependency. The layout viewport is set with
`Emulation.setDeviceMetricsOverride`: desktop 1920×1080 for landscape, and a 540×960 phone viewport at DPR 2
(delivered as 1080×1920) for portrait, so the app renders its own mobile layout rather than a scaled desktop one.

To see the overlay over the running app without touching the app itself (read-only proxy, also useful for
re-verification after re-rendering):

```bash
python docs/opening-sequence/scripts/serve_with_intro.py --port 8001 --app http://127.0.0.1:8000
# http://127.0.0.1:8001/          the app wearing the intro
# http://127.0.0.1:8001/?intro=off  the app bare, for comparison
```

Full re-render pipeline:

```bash
python docs/opening-sequence/scripts/serve_with_intro.py --port 8001 &        # app wearing intro
python docs/opening-sequence/scripts/capture_overlay_frames.py landscape      # -> frames/       (resumable)
python docs/opening-sequence/scripts/capture_overlay_frames.py portrait       # -> frames-portrait/
python docs/opening-sequence/scripts/render_intro_theme.py                    # -> assets/intro-theme.wav
python docs/opening-sequence/scripts/encode_videos.py                         # -> both MP4s
python docs/opening-sequence/scripts/verify_overlay.py                        # 12 behavioural checks
```

`capture_overlay_frames.py` injects, before any page script, a script that replaces `setInterval`/`setTimeout`/rAF
with no-ops so a server-rendered page renders fully from its own HTML and holds still — with a live app, no tail
could be byte-identical. Canvas-only motion is invisible to the screenshot path, so the capture hands the canvas off
as a DOM `<img>` (in-page `toDataURL`) before each shot. Portrait frames come in at 2160×3840 (DPR 2 × clip scale 2)
and are Lanczos-downscaled to 1080×1920 (supersampled, slightly softer-edged than the native 1:1 landscape frames).

---

## Open / next (pick what the owner actually wants)

1. **`?intro=off` is broken in the proxy.** `serve_with_intro.py` is at
   `docs/opening-sequence/scripts/serve_with_intro.py`. Fetch `http://127.0.0.1:8001/?intro=off` and it still
   injects the overlay (`<div id="stage">` with `z-index:2147483000`) when it should return the app's response
   byte-for-byte. The direct app at `http://127.0.0.1:8000/?intro=off` returns 0 stage divs. Body differs by 4
   lines. Diagnose and fix the off-mode guard; `?intro=off` should be a clean no-op pass-through (the control case
   that proves the proxy adds nothing else). The whole file is small — read it first; the off-mode handling region is
   the place to look.

2. **`serve_with_intro.py` has no venv in its new home.** It sits at
   `docs/opening-sequence/scripts/serve_with_intro.py` and imports `urllib`, `http.server`, `threading`, `json`,
   `re`, `html`, `pathlib`, `sys`, `argparse`, `socket` — all stdlib, so system `python` runs it fine, but there is
   no `venv/` in `docs/opening-sequence/`. Decide whether it needs one (it does not functionally, but the repo
   convention and the user's "reconfigure" ask may call for it). Do not assume; check whether a venv is wanted and,
   if so, create it in-tree cleanly. If not, record why not.

3. **Outside duplicate dir is stale/duplicate.** `C:\Users\anis7\Documents\Anis-Media-Server-Intro\` still holds a
   full copy of the source tree (scripts, both MP4s, WAV, `intro-overlay.html`, `intro.html`, 6 stills, both frame
   dirs, `README.md`, `__pycache__/`). It was the source for the move. Decide what to do with it — delete it, or
   leave it as a backup with a note. If deleted, confirm nothing else on the host references it first (grep the
   repo for the absolute path, and check `docs/OPENING_SEQUENCE.md` / `PROJECT_STATUS.md` / `AGENTS.md` no longer
   point at it — they were updated to `docs/opening-sequence/`). Do not delete until you have verified no live
   reference remains.

4. **`docs/OPENING_SEQUENCE.md` section 5 was rewritten but read it fresh.** It was rewritten by
   `scripts/update_intro_doc.py` from "Wiring it in (not done)" to "How it is wired into the app", and the proxy
   command line was updated to `python docs/opening-sequence/scripts/serve_with_intro.py ...`. Read the current file
   (`docs/OPENING_SEQUENCE.md`) and confirm it is internally consistent: all paths point into `docs/opening-sequence/`,
   the wired-vs-proxy distinction is clear, and nothing still references the old outside path. If you find any stray
   reference to `C:\Users\anis7\Documents\Anis-Media-Server-Intro\`, that is a doc bug to fix.

5. **`templates/library.html` gate is once-per-session.** Re-read the include + gate at the end of
   `templates/library.html` and confirm the behaviour matches the doc: the overlay plays once per browser session,
   then `sessionStorage` keeps it from replaying on reload. If the owner wants it to play on every load, or never, or
   only in some mode, that is a product decision — flag it rather than changing it speculatively.

6. **Flutter client asset path.** `docs/opening-sequence/assets/intro-demo-portrait.mp4` is mentioned in
   `docs/OPENING_SEQUENCE.md` as "a finished 1080×1920 asset and native playback has no autoplay restriction" for
   the Flutter client. There are no Flutter client files for the intro in the tree (no `app_enter_screen.dart`,
   no `intro_app.json`). If the owner wants the portrait MP4 wired into the Flutter client as a launch asset, that is
   a fresh scope — there is nothing to resume in the Flutter tree for it; you would wire it fresh against the Flutter
   client harness. Do not invent Flutter files that aren't referenced; ask first.

7. **Re-render freshness.** The videos and frames show the library as it stood at capture time. If the library has
   changed since, the rendered artifacts are stale by construction — re-run the capture + encode to refresh. This is
   normal and expected; it is not a defect. The scripts are resumable (`capture_overlay_frames.py`).

---

## Do not do (constraints)

- Do not rewrite the overlay animation/engine speculatively. The animation is verified and owned by the prior session;
  touch the engine only if there is a concrete defect (e.g. the `?intro=off` bug).
- Do not remove or rename `templates/intro-overlay.html` or the `{% include %}` in `library.html` — that is the live
  wiring.
- Do not commit secrets or credentials. GitHub auth is already handled via `gh` (OAuth, token in keyring); do not
  put a PAT in the repo or in `.env`. If a push needs credentials, use `gh` / the already-authenticated flow, not a
  hardcoded token.
- Do not assume a venv is required for `serve_with_intro.py` — check first.
- Do not delete the outside duplicate dir until you have verified no live reference to it remains in the repo or on
  the host.
- Do not re-run `scripts/update_intro_doc.py` — it is a one-shot migration artifact; its assertions now fail because
  the doc already reflects the new layout.

---

## Suggested first actions (ordered)

1. Read `docs/OPENING_SEQUENCE.md` end to end, then `templates/intro-overlay.html` (or at least its script tail and
   the `window.INTRO` export) and the end of `templates/library.html` (the include + gate).
2. Reproduce the `?intro=off` defect: `curl -s http://127.0.0.1:8001/?intro=off` vs `curl -s
   http://127.0.0.1:8000/?intro=off`, compare stage-div presence and body. Confirm the bug is live before touching
   the proxy.
3. Read `docs/opening-sequence/scripts/serve_with_intro.py` fully and fix the off-mode guard.
4. Re-run `verify_overlay.py` against the running server to confirm 12/12 still pass after any change.
5. Decide on the venv question for `serve_with_intro.py` and the outside duplicate dir; record the decision.
6. Scan the repo for any remaining absolute reference to `Anis-Media-Server-Intro` and clean up any you find.
7. If the owner wants the Flutter client to carry the portrait MP4, treat that as a fresh wiring task against the
   Flutter client — nothing to resume in the Flutter tree.

---

## Repo state at handoff

- Branch `feat/flutter-production-player`: HEAD `16c6920`, pushed to `origin`.
- Working tree: clean except `.vscode/settings.json` (editor-local: `bloc.languageServer.enabled: false`) — not
  part of this work, do not touch.
- The commit adds ~294 MB under `docs/opening-sequence/` (frames + videos + WAV + stills) plus the doc updates and
  `scripts/update_intro_doc.py`. The commit message is `feat(intro): move opening-sequence artifacts in-tree and wire
  the overlay`.

---

## How to verify you are on the right base

```bash
cd /e/MediaServer
git branch --show-current          # expect feat/flutter-production-player
git log --oneline -3              # expect 16c6920, a10e9ef, 67ea9cb
git rev-parse HEAD                # note the sha
git fetch origin
git rev-parse origin/feat/flutter-production-player   # should equal the local HEAD sha
```

If local and remote tracking differ, you are not on the handoff base — stop and reconcile before continuing.

---

## Evidence references (read on demand, not upfront)

- `docs/OPENING_SEQUENCE.md` — full spec, modes, wiring, re-render, verification table, rendering notes, honest
  notes.
- `templates/intro-overlay.html` — the overlay layer (engine + score + DOM).
- `templates/library.html` — the include + per-session gate at the end.
- `docs/PROJECT_STATUS.md` §0 — the "Opening sequence (intro animation)" entry.
- `AGENTS.md` §1 — the pointer bullet.
- `docs/opening-sequence/README.md` — the folder's own spec.
- `docs/opening-sequence/scripts/verify_overlay.py` — the 12-check behavioural suite.
- `docs/opening-sequence/scripts/serve_with_intro.py` — the proxy (and the `?intro=off` defect).
- `docs/opening-sequence/scripts/update_intro_doc.py` — the migration script that already ran (do not re-run).

Source session note (background only, may be slightly stale on repo state): the vault note
`C:\Users\anis7\Documents\Obsidian Vault\Media Server\Sessions\2026-09-28 default brand-opening-animation.md`
describes the design decisions and the overlay-vs-snapshot rationale. The repo is now the ground truth for paths and
status — prefer it over the note where they conflict (the note still says "artifacts live outside this repository"
because it was written before the move).

---

## Whether there is anything to hand off at all

The move-in and wiring are done and pushed. The real continuation value is narrow: fix the `?intro=off` proxy bug,
decide the venv and outside-duplicate questions, and re-verify. If the owner's intent was just "get it in-tree and
wired", that is done — handoff may be closeable after you confirm the `?intro=off` fix and the verification suite
still pass. If the owner wants more (Flutter wiring, re-render, automation), that is a new task on top of this base.
Assess against the owner's actual instruction before doing extra work.

Co-Authored-By: Hermes Agent (default) upstage/solar-pro4:free
