# Phase 11 — Opening Sequence Unification (Web + Android Phone + Android TV)

**Status:** 📋 **PLANNED — not started.** Awaiting slice-by-slice plans.
**Branch:** `feature/phase-11-opening-sequence`
**Parent:** `fb8b5f6` (on `feature/qr-signin-web-tv`)

**Why this phase exists:** the brand opening sequence was **lost in the Flask → React migration**
and never replaced. It shipped as a Jinja2 template, `templates/intro-overlay.html`, which Slice 7E.2
deleted on 2026-10-18 with no React port behind it. The Flutter client still has its own
implementation, but it has drifted from the original design. Full record:
[`docs/SLICE_7E_WALKTHROUGH.md`](SLICE_7E_WALKTHROUGH.md) §6 and
[`docs/OPENING_SEQUENCE.md`](OPENING_SEQUENCE.md) §0.

---

## 1. Where the sequence stands

| Target | Implementation | Score | Visible Skip | Gating | Lockup |
|---|---|---|---|---|---|
| **Web** | **none** — the template was deleted | — | — | — | — |
| **Android phone** | `CustomPaint` re-implementation, 26 KB | **none** | **yes** | every launch | **stacked** (icon above wordmark) |
| **Android TV** | same `CustomPaint` (`AppShell` is shared) | **none** | **yes** | every launch | **stacked** |
| *Original web (archived)* | Canvas `renderAt(t)` + `requestAnimationFrame` | Web Audio | no (`SHOW_HUD=false`) | once per browser session | **side by side** |

### 1.1 Two findings that shape the work

**The Flutter intro is not video playback.** It is a `CustomPaint` re-implementation. The
`intro-demo-portrait.mp4` is declared in `pubspec.yaml` and **never played** — 2.4 MB of dead
weight in every APK.

**The Flutter intro is silent.** No `AudioPlayer`, no `SystemSound`. The web original had a Web
Audio score with an autoplay-resilient resume. The score was composed for this design and is
sitting unused in `docs/opening-sequence/assets/intro-theme.wav` (529 KB).

### 1.2 The dependency on what lies beneath

**Mechanically, none.** The sequence never reads, samples, inspects or blends with the app: no DOM
queries, no colour extraction, no snapshot, no `mix-blend-mode`, no `BackdropFilter`. It is a closed
system — a fixed stage, its own canvas, its own curtain, its own lockup, its own vignette and
grain.

**Compositionally, yes, and deliberately.** The curtain is **opaque obsidian** — `#05060a` in the web
original, `Color(0xFF05060A)` in Flutter — with translucent brand blooms over it. The app is fully
covered for most of the 3 seconds and is revealed by the two curtain halves **sliding apart**. Not a
crossfade, not a copy. The owner's decision, recorded in `docs/OPENING_SEQUENCE.md` §1: *"The outro
reveals the real page, not a copy of it."*

**Aesthetically, yes.** What is beneath determines what the final half-second looks like. That is
the point of the design.

**Consequence for the port:** the overlay must be a **transparent** full-screen layer carrying an
**opaque curtain**, over the mounted app. An opaque panel that is simply removed would make the
outro a flash rather than a reveal.

**The handover.** At `t >= curtain + 0.62` the overlay flips `pointer-events: none`, so the live app
underneath is already interactive while the last ~0.38 s plays over it. The port must reproduce
this.

### 1.3 The design is already resolution-independent

Both implementations scale by the **vmin** trick: the web original uses `--u: 1vmin` with
`clamp()` throughout, and Flutter computes `u = min(width, height) / 100`. The timing constants
match exactly (`duration 3.0`, `curtain 1.95`, `curtainEnd 2.75`).

So D7 — *adaptible to different screen sizes, aspect ratios and orientation without reducing
quality* — is largely a property to **preserve** through the port, not to invent. The capture harness
already letterboxes to 16:9 (`width: min(100vw, calc(100vh * 16 / 9))`) for the offline renders.

---

## 2. Decisions taken (2026-10-20)

| # | Decision | Answer |
|---|---|---|
| **D1** | Web implementation | **Canvas with audio.** See §3 for the research. |
| **D2** | Gating | **Web: once per browser session. Android: every launch.** |
| **D3** | Flutter gets the score | **Yes.** |
| **D4** | Replay / Skip affordances | **Neither.** No web Replay control, **and no visible Skip button** on any target. |
| **D5** | Intro over the login screen | **Yes.** It plays, then the login screen takes over. |
| **D6** | Canonical design | **Option B — the web original is canonical.** The Flutter client changes to match it: the lockup becomes **side by side**, and the visible Skip button goes. |
| **D7** | Responsiveness | **Yes** — must adapt to any screen size, aspect ratio and orientation without quality loss. |

### 2.1 D4 and D6 read together

The web original's HUD (skip / replay / mute chrome) is **hidden by default** — `SHOW_HUD=false` —
and the source comment says why: *"the layer is the real thing now, so the demo HUD stays out of the
way; click or space still skip while it is playing."* So the canonical design has **no visible
Skip button**; dismissal is implicit (click / tap / space / any key).

The Flutter client's visible Skip pill is therefore **removed** under D6, matching the canonical
design. The Flutter **Settings → "Replay Brand Intro"** action is a separate, Flutter-only
convenience and is *not* part of the visual design; it is retained unless the user says otherwise.

---

## 3. D1 research — how popular OTTs do this efficiently

**Netflix's own intro is code, not video.** The well-known recreations are pure HTML/CSS/JS or
canvas (`maddy-bit/NETFLIX`, `Aishwary2004Gupta/Netflix-Intro-Animation-Code`, the dev.to
"Netflix intro animation — pure CSS" walkthrough). CNBC reported Netflix spent **two years** on the
clip. The takeaway: a short brand sting is conventionally an *authored animation*, not a media file.

**The industry answer for a web intro with sound is a separate audio track, not baked-in video.**
Video autoplay with sound is blocked by browser policy; a `<video>` element would have to be muted
(the score lost) or wait for a gesture (breaking prompt-free autoplay). Web Audio has the same
autoplay restriction — which is precisely why the original's discipline matters: **the visual
animation never waits on the audio.** The `AudioContext` resumes on the first
`pointerdown`/`keydown`/`touchstart`.

**For keeping the main thread free, the pattern is a worker with an offscreen canvas.** Chromium
ships a lottie player that renders on a `Worker` against an `OffscreenCanvas` transferred from the
main thread. A 3-second sting is small enough that this is likely unnecessary here, but it is the
technique to reach for if profiling says otherwise.

**The industry tool for resolution-independent vector motion is Lottie / dotLottie**, whose
`rendererSettings.preserveAspectRatio` and `viewBox` are the standard answer to *"adapt to any
aspect ratio without quality loss"*. It is worth naming, but **not recommended here**, for three
reasons: the existing design is already vmin-scaled (so it is resolution-independent without
Lottie); the original is **code-authored and deterministic** (`renderAt(t)` is one pure function of
time, which is what makes it unit-testable and frame-verifiable); and Lottie would add an
After-Effects authoring dependency to a project that has none.

**Conclusion: D1-A1 — port the canvas renderer, keep the score as a separate Web Audio track.**
The efficient route is to port `renderAt(t)` as a *pure function* (unit-testable, frame-verifiable
against `capture_overlay_frames.py`) rather than to re-implement it as a pile of CSS keyframes.

---

## 4. Slice structure

Each slice is independently verifiable and leaves the tree green. **Plan each slice before
implementing it** (AGENTS.md §0.1).

### Slice 11.1 — Canonical design specification *(no code)*
Freeze the design so every downstream slice is written from one source.
- Rewrite `docs/OPENING_SEQUENCE.md` as the canonical spec: the timing table (3.00 s total; impact
  at `t≈0.55`; curtain `1.95 → 2.75`; handover at `2.57`), the layer stack, the compositing
  contract (opaque curtain over the live app), the responsive rule (vmin), the audio contract, the
  dismissal contract, the per-target status table, and the D2–D7 decisions above.
- Record the **layer order** explicitly, since the two implementations already differ:
  `FX canvas → left veil → right veil → seam glow → vignette → lockup → (no HUD)`.
- Record the divergences being closed: lockup side-by-side, no visible Skip, grain/vignette
  treatment, and the Flutter Silent-vs-web-audible difference.
- **Exit:** the spec is referenced by every later slice; no code changes.

### Slice 11.2 — Web: the canvas renderer *(no audio yet)*
The hard technical core.
- Port `renderAt(t)` from `docs/opening-sequence/source/intro-overlay.html` to TypeScript as a
  **pure function of time** — `web/src/lib/intro/render.ts` — so it is unit-testable and directly
  comparable to the reference frames.
- Reimplement the DOM layers as React: `web/src/components/brand/BrandIntroOverlay.tsx` (the name
  the Phase 0 audit already reserved).
- Compositing: transparent stage, opaque curtain, vignette, grain at 5%, side-by-side lockup, seam
  glow, the `handover` phase.
- Responsive: preserve the vmin scaling; no per-aspect-ratio assets.
- **Exit:** the renderer matches `capture_overlay_frames.py` output **frame for frame**; the pure
  function is unit-tested against captured reference frames.

### Slice 11.3 — Web: lifecycle, gating, modes, audio
- `web/src/hooks/useIntroSequence.ts`: `?intro=` modes (`auto` / `gate` / `capture` / `off`), the
  **container-owned** session gate, dismissal, `prefers-reduced-motion`, the Web Audio score with the
  non-blocking discipline, and the login-screen case (D5).
- Mount in `web/src/app/AppShell.tsx`; the overlay is portaled to `document.body`, `z-index` above the
  `z-20` sticky header. **The container writes `sessionStorage.introSeen`; the overlay must not.**
- `/remotelogin` is **excluded** — `AppShell` early-returns a bare `<main>` for that route and the
  phone flow must stay a focused single-purpose screen.
- No visible Skip, no Replay (D4).
- **Exit:** plays once per browser session; a reload does not replay; `?intro=off` bypasses it;
  `?intro=gate` shows the card; the animation is provably not blocked by a suspended audio context.

### Slice 11.4 — Flutter: align to the canonical design
Makes the shipped app match the canonical design. **This is a visible change to the phone app.**
- Lockup → **side by side** (D6).
- **Remove the visible Skip button** (D4). Dismissal stays implicit (tap anywhere / any key) and the
  `Focus(onKeyEvent)` handler keeps absorbing D-pad presses.
- Match the compositing (grain, vignette, curtain opacity) and the timing.
- Add a TV test asserting a D-pad press dismisses the overlay and **does not fall through** to the
  app behind it.
- **Exit:** the Flutter suite is green; the phone and TV both show the canonical design.

### Slice 11.5 — Flutter: the score
- Add the audio dependency and ship `intro-theme.wav`.
- Play it on phone and TV; the animation must never wait on it.
- **Exit:** audible on both form factors; the dead `intro-demo-portrait.mp4` is removed from
  `pubspec.yaml` and the asset tree (**2.4 MB out of every APK**).

### Slice 11.6 — Responsive hardening & asset regeneration
- D7 verification across portrait, landscape, ultrawide, tablet and TV viewports — and the **Flutter**
  equivalents, since it must match.
- Re-render the offline assets: the lockup changed (D6), so `intro-demo.mp4` and
  `intro-demo-portrait.mp4` are stale. Re-capture the frames and re-encode with the existing tooling
  (`capture_overlay_frames.py`, `encode_videos.py`).
- **Exit:** the sequence is correct at every tested aspect ratio, and the offline renders match the
  shipped implementation.

---

## 5. Phase exit criteria

1. The sequence plays on the web, on the Android phone and on the Android TV, and all three look
   the same.
2. It is resolution-independent at every tested aspect ratio and orientation, with no quality loss.
3. The score plays on all three, and on the web the animation is **provably** not blocked by a
   suspended `AudioContext`.
4. Gating: web once per browser session, Android every launch. The Flutter "Replay Brand Intro"
   action still works.
5. No visible Skip button and no Replay control on any target.
6. The curtain is opaque and the outro is a **reveal** of the live app, not a flash.
7. The handover lets the app underneath be interactive during the final ~0.38 s.
8. The offline renders in `docs/opening-sequence/assets/` match the shipped implementation.
9. `cargo test`, `npm run test`, `scripts\run_flutter_tests.ps1` and `scripts\probe_android_api.py`
   are all green.

---

## 6. Risks

| Risk | Mitigation |
|---|---|
| The ported renderer drifts from the original | `capture_overlay_frames.py` + `serve_with_intro.py` give a frame-for-frame oracle; the renderer is a *pure function of time*, so it is directly comparable |
| The score cannot autoplay in the browser | The original's discipline is preserved — the animation never waits on audio; the context resumes on first gesture |
| A new Flutter audio dependency brings platform risk | The app already plays video through media_kit, so a media pipeline exists; the dependency is scoped to one slice |
| Slice 11.4 changes the shipped phone app's appearance | It is a **decision**, not an accident (D6); the change is confined to the lockup layout and the Skip button's removal, and is verified in Slice 11.4's exit criteria |
| The overlay traps focus or blocks the app on TV | `KeyEventResult.handled` on the overlay's `Focus`; a TV test asserts the fall-through does not happen |
| The web overlay is trapped by an ancestor `transform` | AGENTS.md already mandates `transform: none` on `fadeIn`; the overlay is **portaled to `document.body`**, so no ancestor can trap it |
| The offline renders become stale again | Slice 11.6 regenerates them after the last visual change, and the assets live in one place |

---

## 7. Traps worth knowing

- **The `delnum` lesson from the router applies here too.** A decommissioning sign-off must diff
  *capabilities*, not just mechanisms. Slice 11.1 exists so the design is written down before the
  code, and every slice's exit criteria name a user-visible behaviour.
- **A state updater must be pure** — the same rule that caused the StrictMode double-session bug in
  the QR flow applies to any animation driven by React state.
- **The curtain must be opaque.** A semi-transparent curtain over a semi-transparent stage is the
  classic way to lose the "reveal" without noticing.
- **`renderAt(t)` must stay pure.** If it reads the clock, the frame oracle breaks and the
  sequence stops being deterministic.
- **The audio must never gate the animation.** That single rule is the difference between a
  prompt-free intro and a broken one in Safari and Chrome.

---

## 8. Related

- [`docs/OPENING_SEQUENCE.md`](OPENING_SEQUENCE.md) — the current state and the design (rewritten in
  Slice 11.1 into the canonical spec)
- [`docs/SLICE_7E_WALKTHROUGH.md`](SLICE_7E_WALKTHROUGH.md) §6 — the missed backlog item
- [`docs/Current issues.md`](Current issues.md) Issue 10 — the finding
- `AGENTS.md` §"Brand Opening Sequence (Intro Overlay) Invariants" — the invariants this phase
  implements
