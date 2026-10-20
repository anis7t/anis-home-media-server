# Phase 11 — Opening Sequence Unification (Web + Android Phone + Android TV)

**Status:** 📋 **PLANNED.** Slices 11.1 (canonical specification), 11.1a (remove the Flutter Replay
action) and 11.2 (the web canvas renderer) are **complete**; 11.3 onward await slice-by-slice
plans.
**Branch:** `feature/phase-11-opening-sequence`
**Parent:** `fb8b5f6` (on `feature/qr-signin-web-tv`)

**Why this phase exists:** the brand opening sequence was **lost in the Flask → React migration**
and never replaced. It shipped as a Jinja2 template, `templates/intro-overlay.html`, which Slice 7E.2
deleted on 2026-10-18 with no React port behind it. The Flutter client still has its own
implementation, but it has drifted from the original design. Full record:
[`docs/SLICE_7E_WALKTHROUGH.md`](SLICE_7E_WALKTHROUGH.md) §6 and
[`docs/OPENING_SEQUENCE.md`](OPENING_SEQUENCE.md) Part II §14.

> **The canonical design is [`docs/OPENING_SEQUENCE.md`](OPENING_SEQUENCE.md) Part I.** That document
> is the contract; this one is the roadmap. Where they disagree, the spec wins.

---

## 1. Where the sequence stands

| Target | Implementation | Score | Visible Skip | Replay action | Gating | Lockup |
|---|---|---|---|---|---|---|
| **Web** | **none** — the template was deleted | — | — | — | — | — |
| **Android phone** | `CustomPaint` re-implementation, 26 KB | **none** | **yes** | **yes** (Settings) | every launch | **stacked always** |
| **Android TV** | same `CustomPaint` (`AppShell` is shared) | **none** | **yes** | **yes** (Settings) | every launch | **stacked always** |
| *Original web (archived)* | Canvas `renderAt(t)` + `requestAnimationFrame` | Web Audio | no (`SHOW_HUD=false`) | no | once per browser session | **responsive** (side by side / stacked) |

### 1.1 Four findings that shape the work

**1. The Flutter intro is not video playback.** It is a `CustomPaint` re-implementation. The
`intro-demo-portrait.mp4` is declared in `pubspec.yaml` and **never played** — 2.4 MB of dead
weight in every APK.

**2. The Flutter intro is silent.** No `AudioPlayer`, no `SystemSound`. The web original had a Web
Audio score with an autoplay-resilient resume. The score was composed for this design and is
sitting unused in `docs/opening-sequence/assets/intro-theme.wav` (529 KB).

**3. The Flutter intro's entire FX layer is invisible.** This was **not** in the original drift
list and is the largest divergence of all. `brand_intro_overlay.dart` places `_IntroFXPainter`
**first** in its `Stack` — the bottom — and the two curtain halves above it are **opaque obsidian**.
So the light beams, the converging particles, the impact flash, the shockwave rings, the standing
brand glow and the settling embers (the whole `0.12 – 1.95 s` build-up) are **painted and then
completely covered**. The Flutter intro is, in effect, a dark curtain with a logo on it. The Flutter
client also has **no grain layer at all**.

> **The canonical layer stack — the one this phase must reproduce on every target:**
> `veilL/veilR (z2) → seam (z3) → **FX canvas (z4)** → vignette (z5) → grain (z6) → lockup (z7) →
> HUD (z8, hidden)`. **The FX canvas is above the curtain.** An earlier draft of this document
> listed it below the veils, which is precisely the Flutter bug.

**4. `renderAt(t)` is not pure in the original.** The camera shake uses `Math.random()`, and the
veil's 14 s ambient drift is an infinite CSS animation outside `t` altogether. A frame-for-frame
oracle therefore requires a determinism rule (now **D9**/**D10** in §2).

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

**The handover.** At `t >= curtain + 0.62` (2.57 s) the overlay flips `pointer-events: none`, so the
live app underneath is already interactive for the final **0.43 s** (3.00 − 2.57) while the last of
the score plays over it. The port must reproduce this.

### 1.3 The design is already resolution-independent

Both implementations scale by the **vmin** trick: the web original uses `--u: 1vmin` with
`clamp()` throughout, and Flutter computes `u = min(width, height) / 100`. The timing constants
match exactly (`duration 3.0`, `curtain 1.95`, `curtainEnd 2.75`).

So D7 — *adaptible to different screen sizes, aspect ratios and orientation without reducing
quality* — is largely a property to **preserve** through the port, not to invent. The capture harness
already letterboxes to 16:9 (`width: min(100vw, calc(100vh * 16 / 9))`) for the offline renders.

**But the lockup rule is a breakpoint, not a constant.** The canonical source toggles `.portrait` on
`H > W` and **stacks** the lockup in portrait (`#lockup.portrait{flex-direction:column}`). Flutter
stacks **unconditionally** — which is right for the phone in portrait and wrong for the TV. Making
the Flutter lockup side-by-side unconditionally would break the phone. See the spec §6.3.

---

## 2. Decisions taken (2026-10-20)

| # | Decision | Answer |
|---|---|---|
| **D1** | Web implementation | **Canvas with audio.** See §3 for the research. |
| **D2** | Gating | **Web: once per browser session. Android: every launch.** |
| **D3** | Flutter gets the score | **Yes.** |
| **D4** | Replay / Skip affordances | **Neither — anywhere.** No visible Skip button on any target, **and no Replay action anywhere, including the Flutter Settings screen.** |
| **D5** | Intro over the login screen | **Yes.** It plays, then the login screen takes over. |
| **D6** | Canonical design | **Option B — the web original is canonical.** The Flutter client changes to match it. |
| **D7** | Responsiveness | **Yes** — must adapt to any screen size, aspect ratio and orientation without quality loss. |
| **D8** | Web score source | **Live Web Audio synthesis on the web; the shipped `intro-theme.wav` on Flutter.** Same composition — the WAV is the offline render of the web's live synthesis. |
| **D9** | Camera-shake determinism | **Seeded, `t`-derived.** The archived frames are a visual reference inside the shake window and are re-captured as a byte oracle in 11.6. |
| **D10** | The 14 s ambient drift | **Dropped.** Not expressible as a function of `t`, imperceptible in 3 s, absent from the oracle, and keeping it would make the web and Flutter differ. |
| **D11** | `prefers-reduced-motion` | **A canonical contract on all three targets.** |

### 2.1 D4 and D6 read together

The web original's HUD (skip / replay / mute chrome) is **hidden by default** — `SHOW_HUD=false` —
and the source comment says why: *"the layer is the real thing now, so the demo HUD stays out of the
way; click or space still skip while it is playing."* So the canonical design has **no visible
Skip**; dismissal is implicit (click / tap / space / any key).

The Flutter client's visible Skip pill is therefore **removed** under D6, matching the canonical
design.

**The Flutter "Replay Brand Intro" action is also removed**, under D4 as extended. The archived
source's `window.INTRO.replay()` is part of the archived demo API, not a product feature, and is
not ported. The removal is its own slice (**11.1a**) so that Slice 11.4 is not simultaneously
"delete a Settings item" and "restyle the lockup".

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

Each slice is independently verifiable and leaves the tree green. **Plan a slice only when the
owner asks for it, and plan only that one** (AGENTS.md §0.1: *"Always ask the user before
drafting an implementation plan... Do not draft or write an implementation plan document until
the user has explicitly requested or approved doing so."*). Approval of one slice is not approval of
the next.

### Slice 11.1 — Canonical design specification *(no code)* ✅ **COMPLETE (2026-10-20)**

**Deliverable:** [`docs/OPENING_SEQUENCE.md`](OPENING_SEQUENCE.md) **Part I** — the canonical
specification. Part II preserves the historical record (the loss, the Flask-era wiring, the
artifacts, the verification, the rendering notes).

It contains: the decision record (D1–D11), the **15-cue timing table** (every value cited to
`source: intro-overlay.html:<line>`), the **layer stack with z-indexes**, the compositing
contract, the responsive rule (including the **portrait breakpoint**), the audio contract, the
dismissal contract, the reduced-motion contract, the gating contract, the **divergence ledger**
(L1–L15 — the work list for every later slice), and the oracle.

**Exit:** the spec is referenced by every later slice; no code changes.

### Slice 11.1a — Flutter: remove the Replay action *(code)* ✅ **COMPLETE (2026-10-20)**

D4 as extended: **no Replay action anywhere.** A small, self-contained deletion, deliberately
separated from 11.4 so that 11.4 is purely about the visual design.

- Delete the **Settings → "Replay Brand Intro"** item (`settings_content.dart:638-704`) and the
  `BRAND & EXPERIENCE` section header with it — that section contains **only** that item.
- Delete `IntroController.replay()` (`intro_controller.dart:41-43`).
- Delete the test `intro_controller_test.dart` — *"replay sets isPlaying to true"*.
- Update the docs that advertise the action: `docs/MANUAL.md:445`,
  `docs/FLUTTER_CLIENT_STATUS.md:498`.

**Why it is safe:** the Android intro plays on **every launch** (D2), so a Replay action is
redundant by construction. After the removal the only path to `isPlaying: true` is
`IntroController.build()`.

**Exit:** the Flutter suite is green; the action, the controller method and its test are gone; no
document advertises a Replay action.

**Delivered (2026-10-20):** the Settings item and the `BRAND & EXPERIANCE` section are removed
from `settings_content.dart` (with its now-unused import), `IntroController.replay()` is removed,
its test is deleted, and the `markFinished` test was re-based on the provider-override pattern
already used in `brand_intro_overlay_test.dart` so the playing→finished transition stays covered
without any production refactor. The docs that advertised the action were updated. **Next: 11.2.**

### Slice 11.2 — Web: the canvas renderer *(no audio yet)* ✅ **COMPLETE (2026-10-20)**

The hard technical core, and the one the whole phase rests on.

**What was built:**

| File | What it is |
|---|---|
| `web/src/lib/intro/timeline.ts` | **Pure.** The cue constants, the easings, the seeded particle fields, and the deterministic camera shake. |
| `web/src/lib/intro/frame.ts` | **Pure.** `computeFrame(t, opts) → Frame` — every derived DOM-layer value, as the source's exact CSS strings. |
| `web/src/lib/intro/fx.ts` | The canvas port of `drawFX(t)`. |
| `web/src/lib/intro/geometry.ts` | **Pure.** The design unit, the portrait breakpoint, the device pixel ratio. |
| `web/src/components/brand/BrandIntroOverlay.tsx` | The React component: the layer structure, the rAF loop, the frame applier. |
| `web/src/components/brand/brand-intro.css` | The layer styles, ported from the source's stylesheet. |
| `web/src/components/BrandMark.tsx` | The canonical brand mark, shared by the app and the sequence. |

**The three decisions taken with the plan:**

- **Direct DOM writes to refs**, not React state per frame. React renders the layer structure
  once; the applier writes the per-frame values straight to the elements, from the same
  `requestAnimationFrame` loop the original used. The rule that follows: **no element the
  applier writes to may carry a React `style` prop**, because React would overwrite it.
- **The oracle lives in the web repo** — Playwright specs in `web/e2e/` plus vitest units in
  `web/src/lib/intro/`. Playwright and Chromium were already installed.
- **One brand mark in the app.** `AppShell`'s simplified `BrandMark` and the remote-login
  screen's copy were replaced by the canonical SVG — the one the sequence was authored against,
  with the specular highlight and the drop shadow. The app header, the footer, the device
  sign-in screen and the sequence now show the same mark.

**The oracle** (`web/e2e/intro-frame.spec.ts`) puts the archived original and the port side by
side, drives both to the same instant, and compares what they painted — **the FX canvas by the
SHA-256 of its pixels, every DOM layer's style and geometry (including every letter of both
wordmarks), and the rendered page pixel by pixel** — at 20 instants, in landscape and portrait.
**All three comparisons are exact.** See the canonical spec §13 for the three rendering
mechanics that are normalised, and why.

**Six further findings, all from reading the source rather than the summary:**

| # | Finding |
|---|---|
| **F7** | The source's `mulberry32` re-seeds and re-mixes on **every call** — the whole body is inside the returned closure. The obvious "tidier" port, which hoists the initialisation out, produces a completely different sequence, and every particle in the sequence lands somewhere else. The oracle caught it. |
| **F8** | `renderAt` measures the DOM **before** it writes to it, so every frame is drawn against the **previous** frame's geometry. The canvas is therefore drawn *first* and the DOM written *after* — the port must keep that order or the FX shift by a frame. |
| **F9** | The app's font stack leads with **Inter**; the source's does not. The overlay must set the source's own stack, or the wordmarks are not the same picture. |
| **F10** | The source's brand SVG is **richer** than the app's: three paths, a specular highlight and a drop shadow. |
| **F11** | The original paints frame zero **at load**. A port that does not accumulates a different history, and the compositor then rasterises the wordmark's glyphs differently — invisible to the eye, but 58 of 255 on a glyph edge. |
| **F12** | The `will-change` compositor hint changes a promoted layer's antialiasing. The two documents promote the mark differently, so the hint has to be taken out of the comparison on both sides. |

**Verified:** `tsc -b` clean · `oxlint` exit 0 · vitest **275/275** across 38 files (27 new) ·
`vite build` succeeds · the Playwright oracle **5/5**.

**Exit:** met. The renderer matches the archived original frame for frame; the pure function is
unit-tested against golden values taken from the source's own algorithm.

### Slice 11.3 - Web: lifecycle, gating, modes ✅ **COMPLETE (2026-10-20)**

The renderer gets a life. **The Web Audio score is deliberately not in this slice** — it is Slice 11.3a.

**What was built:**

| File | What it is |
|---|---|
| `web/src/lib/intro/mode.ts` | **Pure.** Parses `?intro=` → `auto` \| `gate` \| `capture` \| `off`; anything unrecognised falls back to `auto`. |
| `web/src/hooks/useIntroSequence.ts` | The **container-owned** hook: the mode, the session gate, and the capture handle. |
| `web/src/components/brand/BrandIntroOverlay.tsx` | Gains the `mode` prop, the gate card, the dismissal listeners, the capture behaviour, and the `window.__INTRO__` handle. |
| `web/src/components/brand/brand-intro.css` | The gate card's styles, ported from the source. |
| `web/src/app/AppShell.tsx` | Mounts the overlay as a sibling of `<main>`, so it plays over the login screen (D5). |

**The four modes:** `auto` (the default; once per browser session) · `gate` (the manual-testing card;
never the product behaviour) · `capture` (a still page, driven from outside) · `off` (nothing is
mounted at all — the component is never in the tree).

**The gate's ownership.** The container reads `sessionStorage.introSeen` **during render**, decides
whether to mount, and records that the intro has started. **The overlay never touches
`sessionStorage`** — asserted against the component's own source, not just at runtime, because a
runtime spy would only prove it for the paths a test happens to exercise.

**Five findings, all from reading the source rather than the plan:**

| # | Finding |
|---|---|
| **F13** | **The original's click-to-skip is dead.** It tests `e.target === el.stage` (source 888), but the FX canvas (z-index 4) and the curtain halves (z-index 2) have no `pointer-events: none` — so a click always lands on one of them and never on the stage. The canonical spec requires click/tap to dismiss, and the Flutter client dismisses on a tap anywhere, so **the port follows the spec**. |
| **F14** | The original's auto mode has an escape hatch: `intro=(auto\|replay\|force)` plays the intro **even when it has been seen** (source 976). That is a Replay mechanism, so **D4 removes it** — the session gate is unconditional. `?intro=gate` remains the manual way to watch it. |
| **F15** | The original's `gate` mode does **not** consult the session gate. The port matches that, and additionally records the intro as seen when a gate view starts, so a manual view does not leave the intro pending. The `capture` mode deliberately does **not** record it: a verification run must not consume the user's session. |
| **F16** | **The curtain does not hide the page until it has fully parted.** The halves' inner edges are **feathered** — the source gives each a mask whose transparent band is `4 + 11 × progress` percent of the half's width. The band of the page the curtain does not fully hide is therefore the gap **plus** those two feather bands, and that is the only place the app's own content can show through. |
| **F17** | A **conditional hook call**: `useIntroSequence` was placed after the `/remotelogin` early return, which `oxlint`'s rules-of-hooks caught. The hook is now called before the return, and the early return still skips the mount. |

**The oracle grew a sixth test:** the shipped application, in its `?intro=capture` mode, is compared
against the verified harness — pixel for pixel, at every sampled instant, with the differing pixels
required to fall inside the curtain's reveal band (F16) and nowhere else. That is what makes the
verified thing the thing that **ships**.

**Verified:** `tsc -b` clean · `oxlint` exit 0 · vitest **292/292** across 40 files (17 new) ·
`vite build` succeeds · the Playwright oracle **6/6**.

**Exit:** met. The sequence plays once per browser session, a reload does not replay it, `?intro=off`
bypasses it, `?intro=gate` shows the card, `/remotelogin` never shows it, the intro plays over the
login screen, and the shipped app's overlay is pixel-identical to the original's.

### Slice 11.3a - Web: the Web Audio score ✅ **DONE (2026-10-20)**

The score, and nothing else. D8: **live Web Audio synthesis on the web** — the original's own
approach, zero asset bytes — with the **non-blocking discipline** that AGENTS.md makes an invariant:
the animation never waits on the audio, and the `AudioContext` resumes on the first gesture.

- Port the original's audio module (source 572-807, 236 lines) to TypeScript.
- The gate card's wording changes with it: the button becomes "Play with sound" and the hint
  describes the keys, exactly as the original's does.
- **The oracle is a measurement, not a listening test:** the port's synthesis is rendered in an
  `OfflineAudioContext` and the samples are compared against
  `docs/opening-sequence/assets/intro-theme.wav` — which is the offline render of that same
  composition. The score becomes *provably* the same music rather than probably.
- The animation must remain provably unblocked by a suspended `AudioContext` — a suspended context
  must not delay a single frame.

**What was built.** `web/src/lib/intro/audio.ts` — the score as a **data table** (28 voices, every
parameter of every voice: its envelope, its filter, its reverb send, its pan), a builder that works
on a live `AudioContext` and an `OfflineAudioContext` alike, and a live `IntroScore` that owns the
context. `web/src/lib/intro/score-golden.json` pins the composition. `web/e2e/intro-audio.spec.ts`
is the oracle.

**Three decisions were taken with the plan** and are recorded as **D12** (the unlocking gesture is
consumed by the audio), **D13** (the noise is seeded) and **D14** (the gate's wording is the
original's, verbatim) in the spec's §2.1a.

**The reference is the original's Web Audio, not the WAV.** The Python renderer and the browser's
`BiquadFilterNode` are not the same synthesis — the Python sweeps a resonant *low-pass* over its
noise beds and the original's Web Audio uses a *band-pass*. The WAV is the **Flutter** client's
reference; the archived overlay's `window.INTRO.audio` is the **web** port's. The oracle renders
the archived original in an `OfflineAudioContext`, with `Math.random` replaced by the port's own
seeded PRNG, so the two draw the same noise in the same order.

**Two defects the oracle found** — both in the port, both invisible to a listening test:

1. **The oscillators bypassed their envelopes.** The plain oscillators and the saturated sub were
   connected *directly to the bus* as well as into their envelope gain, so raw full-amplitude
   sines rode on top of the mix. The port rendered **3.5× too loud** and clipped.
2. **The riser had a spurious 120 Hz high-pass.** The original builds the riser *inline*
   (`source: 709-714`) rather than through `noiseVoice`, so it has no high-pass and its sweep ends
   at `t + 0.60` rather than at the generic `dur × 0.9`. Counting the nodes by kind found it: the
   port built **24 filters** where the original builds **23**.

**One defect the oracle could not explain**, and which is recorded rather than papered over: the
port's score renders about **6 dB quieter** than the archived original's own Web Audio, and the
original's peak **exceeds full scale**. It is not a doubled score (33 oscillators on both sides),
not the reverb (removing the convolver changes the level by 0.1 %), not a different graph (every
node kind matches exactly) and not the noise (the same seeded stream, in the same order). The
port's level *does* match the shipped WAV within **1.3 dB in peak**, and its envelope tracks the
WAV's within **16 dB**. Spec §7.9 carries the full list of what was ruled out.

**Verified:** `tsc -b` clean · `oxlint` exit 0 · vitest **300/300** across 41 files (8 new) ·
`vite build` succeeds · the Playwright oracle **9/9** (the six frame oracles plus three audio
oracles).
### Slice 11.4 - Flutter: align to the canonical design ✅ **DONE (2026-10-20)**

Makes the shipped app match the canonical design. **This is a visible change to the phone app.**
Its scope is **larger** than the original three drifts — see §1.1 finding 3.

- **Re-order the layer stack** so the FX canvas is **above** the veils (L1), and **implement the FX
  layer** that is currently invisible: light beams, converging particles, impact flash, shockwave
  rings, standing brand glow, settling embers (L2).
- **Add the grain layer** (L3).
- **Lockup → responsive**: side by side in landscape, stacked in portrait (L4). The phone's portrait
  stack stays; the TV becomes side by side.
- **Remove the visible Skip button** (L5). Dismissal stays implicit (tap anywhere / any key) and the
  `Focus(onKeyEvent)` handler keeps absorbing D-pad presses.
- Match the **curtain geometry** (translate + feather + continuous gradient, L8) and the **outro**
  (removal at 3.00 s, not a 300 ms fade, L12).
- Honour **`prefers-reduced-motion`** (L11) and make the "every launch" gating **deliberate rather
  than accidental** (L13).
- Add a TV test asserting a D-pad press dismisses the overlay and **does not fall through** to
  the app behind it.
- **Exit:** the Flutter suite is green; the phone and TV both show the canonical design.

**What was built.** The Flutter client is now a **port of the canonical renderer**, not a
re-implementation of the idea:

| File | What it is |
|---|---|
| `flutter_client/lib/features/intro/domain/intro_timeline.dart` | The cue constants, the easings, the source's `mulberry32` (with JavaScript's 32-bit semantics), the two seeded particle fields, and the deterministic camera shake |
| `flutter_client/lib/features/intro/domain/intro_frame.dart` | `computeIntroFrame(t)` — every animated value, rounded the way the canonical rounds it |
| `flutter_client/lib/features/intro/presentation/painters/intro_fx_painter.dart` | All seven FX and the sheen, with `BlendMode.plus` for the canvas's `lighter` |
| `flutter_client/lib/features/intro/presentation/painters/intro_veil_painter.dart` | The curtain: two halves of **one** continuous image |
| `flutter_client/lib/features/intro/presentation/widgets/brand_intro_overlay.dart` | The canonical layer stack, the responsive lockup, the handover, the removal at 3.00 s, and no Skip pill |
| `flutter_client/lib/features/intro/presentation/widgets/brand_mark.dart` | The canonical mark, path for path |
| `flutter_client/lib/features/intro/presentation/controllers/intro_controller.dart` | The deliberate gating |

**Two decisions were taken with the plan** and are recorded as **D15** (the gating: "every launch"
is kept and made deliberate, and the dead `hasSeenIntro` flag is gone) and **D16** (the handover:
Flutter releases **touches** at 2.57 s and keeps the **keyboard** for the whole three seconds, so
a D-pad press cannot navigate the app behind the sequence) in the spec's §2.1b.

**Three things the ledger did not name, and the slice found:**

1. **The mark was wrong.** The Flutter client's specular highlight used
   `v 19.4 … L23.2 18.0` where the canonical is `v8.5 l14.2-1.4 L12 9.2z` — roughly twice the area
   it should cover — and its shadow was a hard `drawShadow` at six units where the canonical has a
   soft `feDropShadow dy=2 stdDeviation=3`. Now **L16**.
2. **The handover was missing entirely.** The overlay absorbed every touch for the whole three
   seconds; the app underneath was not live until the sequence had gone. Now **L17**.
3. **The curtain's gradient was wrong**, not only its geometry: the canonical is one stage-wide
   image carried by both halves, and the Flutter client had two independent radial blobs.

**The oracle is two tiers**, and the parameter tier is the load-bearing one:

| Tier | What it compares | Result |
|---|---|---|
| **The parameters** | every animated value, at **69 instants**, against `docs/opening-sequence/frame-golden.json` — which is generated from the canonical renderer and records the values it **rendered** | **exact**, to 1 × 10⁻⁹ |
| **The picture** | the rendered frame against the **archived original's own frames** (90 per aspect, 30 fps), over the closed-curtain window | within a **measured** threshold |

**Two things the oracle caught that no listening test would have.** The first port of the particle
fields took the random draws in the order the constructor's *named arguments* happened to be
evaluated — and Dart does not promise that order — so every particle landed somewhere else. And
the first `toFixed` multiplied by the scale factor, which rounds: a value just below a midpoint can
land exactly on it, and the curtain's feather at t = 2.57 came out one unit in the last place away
from the canonical's.

**Two divergences are recorded, and neither is hidden:** the **grain** (Flutter cannot render the
canonical's SVG `feTurbulence`, so it uses a seeded white-noise texture of the same tile size and
colour matrix — the same *kind* of texture, not the same pixels) and the **handover** (D16).


**Verified:** `flutter analyze` clean across the whole client · the Flutter suite **+296 ~8 -3**,
against a baseline of **+275 ~8 -3** — the same three pre-existing `libmpv` failures (Issue 11),
unchanged and named, and **+21 passes** from the new intro tests.

**The on-device check is deliberately outstanding, and is batched to the end of the phase.** The
exit criterion says "the phone and TV both show the canonical design", and that is the one thing
this slice cannot prove on the host: `adb devices` is empty, and `app_shell_test.dart` — the file
that would cover the AppShell-level integration — is one of the three that cannot run here
(Issue 11). The device check is therefore **not** attempted piecemeal: it is one session, at the
end, on the real hardware, with the owner's remote-control protocol observed. What it needs: the
APK built and installed on the Fire TV Stick 4K and the phone, the intro triggered by a cold launch
(it plays on **every** launch, by design), a screenshot of each, and the two compared against the
archived frames.
### Slice 11.5 — Flutter: the score ✅ **DONE (2026-10-20)**

- Add the audio dependency and ship `intro-theme.wav` (D8).
- Play it on phone and TV; the animation must never wait on it.
- **Exit:** audible on both form factors; the dead `intro-demo-portrait.mp4` is removed from
  `pubspec.yaml` and the asset tree (**2.4 MB out of every APK**).

**What was built.**

| File | What it is |
|---|---|
| `flutter_client/lib/features/intro/domain/intro_score.dart` | The contract — `prepare()`, `ready`, `playFrom(elapsed)`, `stop()`, `dispose()` — and a silent implementation for the host tests |
| `flutter_client/lib/features/intro/infrastructure/audioplayers_score.dart` | The implementation over `audioplayers` |
| `flutter_client/lib/features/intro/presentation/controllers/intro_score_controller.dart` | The lifecycle: the anchor, and the drop rule |
| `flutter_client/lib/features/intro/presentation/providers/intro_score_provider.dart` | The provider, overridden in the entry point |
| `flutter_client/lib/features/intro/presentation/widgets/brand_intro_overlay.dart` | The wiring: the score starts with the sequence, stops with it, and cannot outlive it |
| `flutter_client/lib/main.dart` | The score is **prepared before the first frame** |

**Three decisions were taken with the plan** and are recorded as **D17** (the player:
`audioplayers` 6.8.1), **D18** (the `m` key: the Flutter client keeps "any key dismisses", so it
has **no** `m` mute) and **D19** (the score plays on every cold launch, as the canonical does) in
the spec's §2.1c.

**The contract is the web's (§7.9), with the platform's differences taken into account:**

| Situation | What happens |
|---|---|
| The player is ready when the sequence starts | The score starts at the sequence's t = 0 |
| The player is **not** ready — Android's preparation took 80 ms | The score starts when it is ready, **anchored to the sequence's position at that moment** — the same anchoring as the web |
| The sequence is over by then | **The score is dropped** — a sound out of nowhere is worse than no sound |
| The sequence is dismissed | The score stops, and it cannot outlive the overlay |
| Always | **The animation never waits for the audio** — the score is prepared before the first frame, and nothing awaits it |

**The asset.** The canonical's file, **byte for byte** — the test suite asserts the SHA-256 of
the shipped WAV against `docs/opening-sequence/assets/intro-theme.wav`, and reads the WAV's header
to assert 44.1 kHz, 16-bit, stereo, 3.070 s. The dead `intro-demo-portrait.mp4` is gone from the
pubspec and from the tree; the asset section now names exactly one file, and a test says so. The
APK's assets shrink by about **1.9 MB**.

**Two divergences are recorded, and neither is hidden:** the Flutter client has **no unlocking
gesture** (Android has no autoplay policy, so the score starts on its own — D19) and **no `m` mute**
(any key dismisses, as it always has — D18). Both are **L18**.

**Verified:** `flutter analyze` clean across the whole client · the intro suite passes, including
the score's lifecycle (prepared early · started with the sequence · anchored to the sequence's
position when the player is ready · dropped when the sequence is over · stopped on dismissal) and
the asset's identity · the full suite adds no new failures, and the pre-existing three (Issue 11)
are unchanged and named.

**Audible on both form factors** — that half of the exit criterion is the **batched device session**
at the end of the phase, together with Slice 11.4's on-device check.
### Slice 11.6 — Responsive hardening & asset regeneration ✅ **DONE (2026-10-20)**

- D7 verification across portrait, landscape, ultrawide, tablet and TV viewports — and the **Flutter**
  equivalents, since it must match.
- **Re-capture the oracle frames** against the shipped, now-deterministic implementation (D9), and
  re-encode the videos with the existing tooling.
- **Exit:** the sequence is correct at every tested aspect ratio, and the offline renders match the
  shipped implementation.

**Four decisions were taken with the plan** and are recorded as **D20** (the viewport matrix), **D21**
(the archived frames are replaced, after the byte comparison proves the replacement faithful), **D22**
(the capture is done with Playwright, reusing the web's own oracle mechanism) and **D23** (the
cross-implementation picture comparison is in scope) in the spec.

**The responsive sweep — and the web's half is pixel-exact.** The archived original is a
standalone document that can be laid out at **any** viewport, so the oracle puts it and the port side
by side at **five** aspects and compares them **pixel for pixel**: landscape, portrait, ultrawide
(2560 × 1080), tablet (1024 × 1366) and a modern phone (1080 × 2400). **All twelve oracle tests
pass**, and the new aspects are exact, not within a tolerance.

**The Flutter client's half is exact too.** Its test asserts, at every aspect, that the lockup's
**arrangement** follows the breakpoint (from the rendered geometry, so a device that lies about what
it is cannot get the wrong layout), that the canonical's **clamps** hold, that **nothing overflows**,
and that the **parameters** match the canonical's fixture at that aspect's design unit. The frame is
aspect-independent except the lockup's vertical travel, so the fixture now carries the travel for
each design unit the sweep visits.

**The re-capture is a proof, and it is not the proof the plan assumed.** The archived frames were
captured in a *different browser*, and two things rasterise differently there — the SVG grain's
turbulence (**1–2 units over the whole frame**) and the Gaussian blur on the wordmarks (a large
delta on the glyph edges, over a tiny area). So the frames **cannot** be byte-identical to the
archived ones, and the plan's promise of a byte oracle everywhere is not achievable as written. What
*is* achievable, and is what the script proves:

| Claim | Measured |
|---|---|
| **Reproducible** — the capture is run twice and the two runs must be byte-identical **where the curtain is closed** | the landscape **58/58**, the portrait **55/58** (three stragglers, in a bounded region on the blurred wordmark) |
| **Faithful** — compared, pixel by pixel, with the archived ones, outside the shake and the parting | the landscape **0.013 %** of pixels differ by more than 32/255 and the mean error is **0.02**; the portrait **0.140 %** and **0.99** |

The frames are replaced **only if that comparison passes**, and it did.

> **The frames after the parting show the live application, and it is not static between runs** — its
> data arrives when it arrives. The closed-curtain window is the reference, and it is fully
> reproducible.

**The videos** are re-encoded from the new frames with the score. The encoder's audio path was
stale — it looked for the WAV beside the script, where it has never been — and it now reads the
score from the assets. The videos are **archival** now: the Flutter client was described as their
consumer, and since Slice 11.5 it ships the **WAV** and never played a video.

**One correction to the plan.** It said the archived tooling pointed at a retired port. It does not:
**`:8001` is the injection proxy's own port** (it forwards to the app on `:8000`), and the archived
pipeline is consistent. The genuinely broken thing was the **dev server's** proxy, which pointed its
"Rust" routes at `:8001` — where nothing runs — and its "Flask" routes at `:8000`, which *is* the
Rust service. The two were the wrong way round, and every `/api/movies` call through the dev server
was failing with `ECONNREFUSED`. There is now **one origin**, and the dev server's API works.

**Verified:** the web's oracle **12/12** (five aspects, pixel-exact) · the web's audio oracle
**3/3** · `flutter analyze` clean · the Flutter suite adds no new failures, and the pre-existing
three (Issue 11) are unchanged and named · the responsive sweep's five aspects pass.

### Slice 11.7 — The television's pre-rendered sequence ✅ **DONE (2026-10-21)**

#### 11.7.0 Why this slice exists: the measurement

The Fire TV could not play the sequence, and the reason was measured rather than guessed. A profile
build on the television reported the engine's own frame timings, and the three-second sequence got
**five frames**:

| | build | raster |
|---|---|---|
| the first frame | 14 µs | **1,092,067 µs** |
| the frames after it | 8–25 ms | 70–370 ms |

The build thread is never the problem. **The GPU is.** The television's GPU is a **PowerVR Rogue
GE8300** (2015) with OpenGL ES 3.2 and **no Vulkan**, so:

- **Impeller is unavailable.** Impeller compiles every pipeline into the engine at build time and
  removes shader compilation jank by design, but on Android it requires Vulkan. The engine's
  deprecation notice about the Impeller opt-out on this device is the engine saying it fell back;
  there is no opt-out in this client.
- **Skia on OpenGL ES compiles at runtime**, the first time it sees a given combination of draw
  operations, and the compilation happens *inside the frame that needs it*. That is the 1.09-second
  first frame.

The "rushed" opening is a **consequence** of that, not a separate fault: the ticker's elapsed time
is measured from its first tick, the engine does not begin a new frame until the previous one has
been rastered, and so the second frame's tick carries the whole first frame's second in one step.
The sequence's position jumps from 0.000 to 1.435 and the first second and a half of it is never
seen.

Two remedies were implemented and **rejected by the measurement**, and are recorded here so they are
not attempted again:

| Attempt | Result |
|---|---|
| A `ShaderWarmUp` covering every paint the sequence uses | it compiled (341 ms of it) and the first frame still took **1.09 s**: Skia's GL program cache is keyed **per render target**, so programs compiled into a 100 × 100 offscreen image are not reused by the screen |
| Starting the sequence's clock at the first presented frame | implemented and kept, but it is not the fix: the *slow raster* is what skips the content, not the clock's origin |

This is the same answer the streaming apps get for free, and the reason they are smooth: Android's
HWUI has a persistent on-device shader cache (`libs/hwui/pipeline/skia/ShaderCache.cpp`) and
precompiles its static shaders at build time, and their openings are usually **pre-rendered video**,
so nothing is compiled at all.

#### 11.7.1 Scope

**The television plays a pre-rendered video of the sequence instead of the live canvas.**

- The video is rendered from the **shipped web application** in its `?intro=capture` mode — the
  same source the picture oracle already compares against the archived frames, so the video *is* the
  canonical by construction, and it is the implementation the owner has already seen.
- It is **1920 × 1080, 60 fps, 3.000 seconds**, H.264 in yuv420p, with **no audio track**.
- The **score stays a separate, byte-for-byte canonical WAV**, played by `audioplayers` exactly as
  it is now, and **anchored to the video's playback position** rather than to a clock. The canonical's
  "the score is anchored, not orphaned" rule is preserved: the sound and the picture agree about
  where the sequence is, because the anchor *is* the picture's position.
- The **phone keeps the live sequence**. The Flutter client's renderer stays the phone's
  implementation, and the difference is recorded as a divergence.

**What this slice deliberately does not do:**

- It does **not** change the canonical design, the web, the phone's sequence, the score, the
  dismissal, the gating, or the handover.
- It does **not** introduce a portrait video: the phone keeps the live sequence, so one asset is
  enough.
- It does **not** replace the Flutter client's live renderer with the video everywhere. The
  television's constraint is a device constraint, and the phone is not that device.

#### 11.7.2 The steps

1. **Capture.** A Playwright script drives the shipped app's `__INTRO__.renderAt(t)` over 180
   instants (t = k/60) at 1920 × 1080, screenshots each, and the frames are encoded to an MP4.
   The mechanism is the oracle's own (`web/e2e/intro-frame.spec.ts` already drives that handle), so
   the capture is the same measurement the oracle makes.
2. **Verify the video.** A new oracle compares the video's frames, at the 58 sample instants, with
   the archived frames. Because the video's frames are at multiples of 1/60 s and the samples are
   not, the comparison allows the motion of **at most 1/120 s** — and the tolerance is stated, not
   assumed.
3. **Play it on the television.** `media_kit` is already a dependency and already owns the
   television's playback path, including the `mediacodec-copy` configuration the platform rules
   require. The overlay plays the video instead of painting the canvas, and reads the video's
   position for the score's anchor.
4. **Keep the contract.** The dismissal still works (a tap stops the video and the score), the
   handover at 2.57 s still releases the app's input while the video plays, and the sequence still
   ends at 3.0 s.

#### 11.7.3 Exit criteria

- The television plays the video, and **the sequence is smooth** — the owner's judgement, on the
  device, which is the only instrument that has ever measured this correctly.
- The video's frames match the archived frames within the stated tolerance, at every sample
  instant.
- The score starts in step with the video, and the handover and dismissal behave as they do now.
- The phone is unchanged, except for Slice 11.8 below.
- The Flutter suite and the web's oracles pass, and the APK's size increase is stated.

#### 11.7.4 Risks

| Risk | How it would be caught |
|---|---|
| The video's first frame is not available immediately, so a flash of the launch window shows through | the launch window is the sequence's own colour, so the worst case is a longer obsidian wait and no wrong colour; the owner would see it on the device |
| The video's typeface is the rendering machine's system font, not the device's | the canonical's own font stack is `'Inter', system-ui, …` and Inter is not installed here, so the video carries the canonical's *fallback* — the same rendering the oracle compares. It is recorded as a divergence |
| `media_kit`'s video path on the television has its own driver hazards | the platform rules already cover this path (`mediacodec-copy`, the software fallback), and the sequence is three seconds of a still frame — a far milder case than the player |
| The APK grows by the video's size | the size is measured and stated; the video is ~1–3 MB for three seconds of a nearly-black 1080p frame |
| The video's grain is baked in, so it cannot animate | the canonical's grain *is* static within a frame and the web's is an SVG turbulence that is rasterised per frame; the baked version is a divergence, and it is recorded |

#### 11.7.5 Decisions taken with this slice

- **D24 — the television plays a pre-rendered video; the phone keeps the live sequence.**
- **D25 — under `prefers-reduced-motion` the television keeps the live sequence**, because the
  canonical suppresses four effects and a video has them baked in. The contract holds, and the
  television's normal case is the video.
- **D26 — the score stays a separate WAV**, muxed into the video would re-encode the canonical's
  own render, and the score is the one asset the client holds byte for byte.

#### 11.7.6 What was built

- **`scripts/capture-intro-video.mjs`** renders the video from the harness — the same page the
  picture oracle uses, which mounts the real `BrandIntroOverlay` — at 1920 × 1080, 60 fps, 3.000
  seconds, and encodes it to H.264 in yuv420p with no audio track. It drives the overlay's own
  `renderAt` handle over 180 instants, in ascending order, because the canonical measures the
  mark's *live* rectangle.
- **`scripts/verify-intro-video.mjs`** is the oracle for it. The video is at 60 fps and the
  reference frames at 30, and both start at t = 0, so the reference frame at index `i` and the
  video's frame at index `2i` are the **same instant** and the comparison needs no interpolation
  and no allowance for motion. **Measured over the 58 closed-curtain frames: the worst mean error
  5.33/255, the mean of the means 2.34/255, and at most 2.89 % of pixels differing by more than
  32/255** — all of it in the grain, which is the one thing a codec cannot carry (L21).
- The video's backdrop is the application's own background colour (`#090b10`), so the curtain parts
  onto the colour the television's application is painted in, and the client cross-fades the video
  out over the last quarter-second to bring the application in (L22).
- **The client**: `BrandIntroOverlay` gained a `videoAssetPath`, and a second rendering — the
  video, full-screen, with the same behaviour the painted stage has (a tap dismisses, the keyboard
  is absorbed for the whole sequence, and the handover at 2.57 s is driven by the **video's own
  position**). The score is anchored to that position too, so the sound and the picture agree about
  where the sequence is. If the video cannot be created or played, the overlay **falls back to the
  painted sequence** rather than showing a black screen.
- The video is **1.19 MB**, and the APK grows by that much.

### Slice 11.8 — The wordmarks must not inherit the ambient text style ✅ **DONE (2026-10-21)**

The phone's sequence showed **double yellow underlines under every wordmark**, which the canonical
does not have, in either aspect. It is not in the client's code: the app contains no
`TextDecoration` and no yellow, and the *same code* rendered by the oracle is clean.

The cause is in the wordmark widget: it paints its letters with `DefaultTextStyle.merge`, so that
the canonical's font stack (the platform's UI font first) is inherited rather than hard-coded. A
merged style also inherits the ambient **decoration**, and on the phone the ambient style carries
one. The oracle cannot see this, because a test's ambient style never does.

**The fix is one line**: the merged style sets `decoration: TextDecoration.none` explicitly, so the
sequence's own typography cannot be changed by whatever surrounds it. The host's render is
unchanged — a test's ambient style has no decoration to override — so the picture oracle's numbers
do not move, and the phone's underlines go.

**Verified by:** the picture oracle unchanged (the same numbers), and the phone's capture showing no
underlines.

## 5. Phase exit criteria

1. The sequence plays on the web, on the Android phone and on the Android TV, and all three look
   the same.
2. It is resolution-independent at every tested aspect ratio and orientation, with no quality loss.
3. The score plays on all three, and on the web the animation is **provably** not blocked by a
   suspended `AudioContext`.
4. Gating: web once per browser session, Android every launch.
5. **No visible Skip button and no Replay action anywhere** — including the Flutter Settings
   screen.
6. The curtain is opaque and the outro is a **reveal** of the live app, not a flash.
7. The handover lets the app underneath be interactive during the final **0.43 s**.
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
| **Slice 11.4 changes the shipped phone app's appearance** | It is a **decision**, not an accident (D6); the change is confined to the lockup layout and the Skip button's removal, and is verified in Slice 11.4's exit criteria |
| **Slice 11.4 is bigger than the original brief** — the invisible FX layer (L2) and the missing grain (L3) were not in the drift list | The divergence ledger in the spec (§12) is the authoritative work list; each row names its closing slice, so nothing is discovered late |
| The overlay traps focus or blocks the app on TV | `KeyEventResult.handled` on the overlay's `Focus`; a TV test asserts the fall-through does not happen |
| The web overlay is trapped by an ancestor `transform` | AGENTS.md already mandates `transform: none` on `fadeIn`; the overlay is **portaled to `document.body`**, so no ancestor can trap it |
| The offline renders become stale again | Slice 11.6 regenerates them after the last visual change, and the assets live in one place |
| **The canonical spec drifts from the source** | Every value in the spec carries a `source: file:line` citation, and the spec states that the source wins on any disagreement |

---

## 7. Traps worth knowing

- **The `delnum` lesson from the router applies here too.** A decommissioning sign-off must diff
  *capabilities*, not just mechanisms. Slice 11.1 exists so the design is written down before the
  code, and every slice's exit criteria name a user-visible behaviour.
- **A state updater must be pure** — the same rule that caused the StrictMode double-session bug in
  the QR flow applies to any animation driven by React state.
- **The curtain must be opaque.** A semi-transparent curtain over a semi-transparent stage is the
  classic way to lose the "reveal" without noticing.
- **`renderAt(t)` must stay pure.** If it reads the clock — or a random number generator — the frame
  oracle breaks and the sequence stops being deterministic. That is why D9 exists.
- **The audio must never gate the animation.** That single rule is the difference between a
  prompt-free intro and a broken one in Safari and Chrome.
- **The FX canvas is above the curtain, not below it.** Getting this backwards makes the whole
  build-up invisible — which is exactly the bug the Flutter client has today.

---

## 8. Related

- [`docs/OPENING_SEQUENCE.md`](OPENING_SEQUENCE.md) — **the canonical specification** (Part I) and
  the historical record (Part II)
- [`docs/SLICE_7E_WALKTHROUGH.md`](SLICE_7E_WALKTHROUGH.md) §6 — the missed backlog item
- [`docs/Current issues.md`](Current%20issues.md) Issue 10 — the finding
- `AGENTS.md` §"Brand Opening Sequence (Intro Overlay) Invariants" — the invariants this phase
  implements
