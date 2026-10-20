# Opening Sequence — Canonical Specification

**Status:** 📋 **Canonical specification** (Phase 11, Slice 11.1 — 2026-10-20).
**This document is the contract.** Every later Phase 11 slice is written from it.
**The web implementation still does not exist** — see Part II §14.

**Canonical source:** `docs/opening-sequence/source/intro-overlay.html` (973 lines) — the original
web overlay, preserved verbatim and treated as **read-only input**. It is never edited by Phase 11.

> **How to read the citations.** Every number in Part I carries a `source:` reference of the form
> `file:line`. If a number in this document and a number in the source disagree, **the source wins**
> and this document is a bug. Phase 11's exit criteria include a mechanical cross-check of Part I
> against the source.

---

# Part I — Canonical specification

## 1. Scope of this document

One brand opening sequence, implemented natively for three targets — the **web React SPA**, the
**Android phone**, and the **Android TV** — from a single design.

| Target | Implementation | Score | Visible Skip | Replay action | Gating | Lockup |
|---|---|---|---|---|---|---|
| **Web** | **the renderer is built** (11.2); the lifecycle is 11.3 | live Web Audio synthesis | none | none | once per browser session | responsive |
| **Android phone** | `CustomPaint` | none yet (11.5) | **present — to go (11.4)** | **none** (removed in 11.1a) | every launch | responsive |
| **Android TV** | same `CustomPaint` | none yet (11.5) | **present — to go (11.4)** | **none** (removed in 11.1a) | every launch | responsive |
| *Original web (archived)* | Canvas `renderAt(t)` | live Web Audio synthesis | none (`SHOW_HUD=false`) | none | once per browser session | responsive |

"Responsive" means the **responsive lockup rule** of §6: side by side in landscape, stacked in
portrait. It is **not** "always side by side" — see §6.3 and decision **F4** in §2.

## 2. The decision record

Settled 2026-10-20. Each is a **decision**, not a default to be re-litigated in a later slice.

| # | Decision | Answer |
|---|---|---|
| **D1** | Web implementation | **Canvas renderer with a separate Web Audio score.** Not a `<video>` element: browser autoplay policy blocks unmuted video, so a baked-in score would be lost, and gesture-gating it would break prompt-free autoplay. |
| **D2** | Gating | **Web: once per browser session. Android: every launch.** |
| **D3** | The Flutter client gets the score | **Yes.** |
| **D4** | Replay / Skip affordances | **Neither — anywhere.** No visible Skip button on any target, and **no Replay action anywhere, including the Flutter Settings screen.** Dismissal is implicit (§8). |
| **D5** | Intro over the login screen | **Yes.** It plays, then the login screen takes over. |
| **D6** | Canonical design | **Option B — the web original is canonical.** The Flutter client changes to match it. |
| **D7** | Responsiveness | **Yes** — adapts to any screen size, aspect ratio and orientation without quality loss. |

### 2.1 The four decisions taken with the Slice 11.1 plan (2026-10-20)

| # | Question | Answer |
|---|---|---|
| **D8** | Web score: live synthesis, or the shipped WAV? | **Live Web Audio synthesis on the web; the shipped `intro-theme.wav` on Flutter.** They are the same composition — the WAV is the offline render of the web's live synthesis (`source: 572-576`). Flutter has no Web Audio, so it ships the file. |
| **D9** | Camera-shake determinism | **Seeded, `t`-derived shake.** The original uses `Math.random()` (`source: 541-544`), which is not reproducible. A deterministic shake is required for a frame-for-frame oracle. The archived PNGs are therefore a *visual* reference for the shake window, and are re-captured as a byte oracle in Slice 11.6. |
| **D10** | The 14 s ambient drift on the veil | **Dropped.** It is an infinite CSS animation outside `t` (`source: 39-42, 118`), imperceptible within 3 s (≈1 % scale, ≈1 % brightness), and absent from the capture oracle (capture mode kills all CSS animation, `source: 166`). Keeping it would make the web and the Flutter client differ. |
| **D11** | `prefers-reduced-motion` | **A canonical contract on all three targets.** The web original honours it (`source: 331-332`); Flutter honours nothing today. |

### 2.2 D4 and D6 read together

The web original's HUD — the skip / replay / mute chrome — is **hidden by default**
(`SHOW_HUD=false`, `source: 931`), and its own comment says why: *"the layer is the real thing now,
so the demo HUD stays out of the way; click or space still skip while it is playing"*
(`source: 929-930`). So the canonical design has **no visible Skip and no visible Replay**;
dismissal is implicit.

The Flutter client's visible **Skip pill** therefore goes under D6, and so does the Flutter
**Settings → "Replay Brand Intro"** action under D4. The archived source's `window.INTRO.replay()`
(`source: 945`) is part of the archived demo API, **not** a product feature, and is not ported.

> **Removed in Slice 11.1a, not in 11.1.** The Replay removal is its own slice so that Slice 11.4
> is not simultaneously "delete a Settings item" and "restyle the lockup". The files it must touch
> are listed under **L6** in §12.

## 3. The timeline

**Total duration 3.00 s.** The cue table is the contract; every later slice implements it exactly.

| t (s) | Cue | On screen | Audio | source |
|---|---|---|---|---|
| 0.00 | — | black, room tone | room tone fades in over 0.25 s | 700-707 |
| 0.12 | `streak` | light beams build; particles converge on the mark | riser (noise sweep 200 → 6200 Hz) + sub swell | 378-407, 709-716 |
| 0.62 | `impact` | **the logo lands** — flash, shockwave rings, camera shake | **HIT 1** — A minor, sub + sawtooth chord | 409-445, 718-726 |
| 0.74 | `sheen` | specular sweep across the mark | noise sweep, band-passed | 474-491, 728-729 |
| 0.80 | `w1` | "Anis'" rises, letter by letter | tick | 513-521, 731-734 |
| 0.92 | `w2` | "Home Media Server" rises, letter by letter | — | 522-529 |
| 1.12 | `hit2` | — | **HIT 2** — a fifth up, bell layer, pad swells | 736-745, 747-759 |
| 1.24 | `sub` | "PLAY • ORGANIZE • ENJOY" letterspaces in | tick | 531-536 |
| 1.42 | `rule` | the red rule draws | tick | 537-538 |
| 1.58 | `settle` | sparkle dust settles; embers drift | sparkle bells | 459-472, 761-764 |
| 1.95 | `curtain` | **the curtain parts**; the lockup begins to lift and fade | handoff chime at 2.00 | 547-557, 566-569, 766-769 |
| 2.57 | `handover` | **the app underneath becomes interactive**; the lockup is fully dismissed | score rings out | 840, 190, 566-569 |
| 2.75 | `curtainEnd` | halves fully off-screen; vignette and grain gone | — | 547-563 |
| 2.80 | — | embers faded out | — | 462 |
| 3.00 | `end` | **the layer is removed — the app has the viewport back** | master fade to silence | 841, 933-941, 772-775 |

**Machine-readable constants** (`source: 276-278`):

```text
streak 0.12 · impact 0.62 · sheen 0.74 · w1 0.80 · w2 0.92 · sub 1.24
rule 1.42 · settle 1.58 · curtain 1.95 · curtainEnd 2.75 · DURATION 3.00
handover = curtain + 0.62 = 2.57
```

### 3.1 The handover window

At `t = 2.57` the layer releases `pointer-events` (`source: 190, 840`), so the live app underneath
is **already interactive for the final 0.43 s** while the last of the score and the lockup's
dissipation play over it. The layer is removed at `t = 3.00`.

> **Correction.** The Phase 11 plan and the 2026-10-20 handoff both said "*the last ~0.38 s*".
> `3.00 − 2.57 = 0.43 s`. The handover is at **2.57** and the overlap is **0.43 s**.

## 4. The layer stack

**The canonical z-order.** All layers are children of one stacking context (`#stage`, `position:
fixed; inset: 0; z-index: 1` — `source: 37`). The layer is at the very top of the app's stack
(`z-index: 2147483000` in overlay mode — `source: 183-185`).

| z | Layer | What it is | source |
|---|---|---|---|
| 2 | `#veilL`, `#veilR` | **the curtain** — two halves of one backdrop | 107-121 |
| 3 | `#seam` | warm light spilling through the opening | 124-126, 559 |
| 4 | `#fx` | **the FX canvas** — beams, particles, flash, shockwaves, glow, embers | 44, 372-493 |
| 5 | `#vignette` | the radial darkening at the edges | 46-49, 563 |
| 6 | `#grain` | 5 % film grain | 50-54, 564 |
| 7 | `#lockup` | icon + wordmarks + subtitle + rule | 57-94, 566-569 |
| 8 | `#hud` | the demo chrome — **hidden by default** (`SHOW_HUD=false`) | 129-138, 931 |
| 2147483001 | `#gate` | the manual-testing click-to-start card — **off by default** | 141-159, 186-187 |

**The stage itself paints nothing.** It is `background: transparent` (`source: 185`); it is a
**transparent layer carrying an opaque curtain over the live app**, not an opaque panel (§5).

> **Correction — the FX canvas is ABOVE the curtain, not below it.** An earlier draft of the Phase 11
> plan listed the stack as *"FX canvas → left veil → right veil → seam glow → vignette → lockup"*.
> That is wrong: the FX canvas is `z-index: 4`, **above** both veils (`z-index: 2`) and the seam
> (`z-index: 3`). The consequence is load-bearing — see **L2** in §12.

### 4.1 The FX canvas inventory

All six effects live in `drawFX(t)` (`source: 372-493`) and are drawn with
`globalCompositeOperation = 'lighter'`:

| Effect | Window | source |
|---|---|---|
| Build-up light beams (3) | `streak → impact` | 378-392 |
| Particles converging on the mark (170, seeded PRNG) | `streak → impact` | 394-407, 341-344 |
| Impact burst (170 particles) | `impact → impact + 0.42` — **suppressed under reduced motion** | 409-420, 411 |
| Shockwave rings (2) | `impact → impact + 0.80` | 422-433 |
| Impact flash (radial, 0.72 peak alpha) | `impact − 0.05 → impact + 0.34` | 435-445 |
| Standing brand glow | `impact → curtain + 0.30` | 447-457 |
| Settling embers (64, seeded PRNG) | `settle − 0.35 → settle + 0.70` | 459-472, 345-346 |

The specular **sheen** (`source: 474-491`) is a canvas draw that reads the lockup's live bounding
rect, so it is a function of `t` **and** the measured lockup geometry.

## 5. The compositing contract

1. **The stage is transparent.** The app beneath is fully visible through it, at all times.
   (`source: 185`)
2. **The curtain is opaque obsidian** — `#05060a` (`source: 116`; Flutter `Color(0xFF05060A)`).
   It is **not** a translucent scrim. A semi-transparent curtain over a semi-transparent stage is the
   classic way to lose the reveal without noticing.
3. **The two halves are one backdrop.** They use `background-size: 200% 100%` with **opposite**
   `background-position`s (`source: 117, 120-121`) so their gradients line up into a single
   continuous image, with a 1 px overlap at the centre (`source: 107`).
4. **The inner edges feather only once the halves part** — a CSS mask whose feather grows from 4
   to 15 (`source: 553-557`). Before that, the opening frames are one unbroken veil.
5. **The curtain translates, it does not shrink.** Each half moves by ±100 % of its own width
   (`source: 549-550`); the halves are full width for the whole move.
6. **The reveal is the real app.** There is nothing to load: the layer is injected over the running
   app, so what shows through is the app itself, live and interactive (`source: 300-303`).
7. **The dressing lifts as the UI arrives.** The vignette fades with the curtain progress and the
   grain fades from 5 % to 0 (`source: 563-564`).
8. **The lockup is dismissed gently** — it lifts by `2.4u` and scales to 0.94 while fading out
   over the 0.62 s that follows the curtain (`source: 566-569`).
9. **At 3.00 s the layer is removed entirely** — `display: none`, the capture class is cleared, and
   the audio is stopped (`source: 933-941`). Nothing of the intro is left in the page.

## 6. The responsive rule

### 6.1 The unit

One unit, `u = min(W, H) / 100`, published to CSS as `--u` (`source: 358`) and recomputed in
JavaScript for the canvas (`source: 547`). **Everything** in the design is expressed in `u` with
`clamp()` bounds:

| Element | Expression | source |
|---|---|---|
| Brand icon | `clamp(64px, u × 10.5, 118px)` | 71 |
| Wordmark `w1` / `w2` | `clamp(30px, u × 5.7, 66px)` | 78-79 |
| Subtitle | `clamp(8.5px, u × 1.3, 13px)` | 87 |
| Lockup gap | `clamp(10px, u × 3, 34px)` | 59 |
| Word column gap | `clamp(3px, u × 0.7, 7px)` | 73 |
| Portrait lockup gap | `clamp(9px, u × 1.5, 20px)` | 98 |

**There are no per-aspect-ratio assets.** The brand mark is inline SVG (`source: 281-299`), and the
FX are drawn procedurally. This is what makes D7 a property to preserve rather than a problem to
solve.

### 6.2 Raster

`DPR = min(2, devicePixelRatio)` (`source: 351`); the canvas backing store is `W × DPR` by
`H × DPR` and the CSS size is `W × H` (`source: 361-362`). The canvas is re-rasterised on resize
(`source: 364-365`).

### 6.3 The lockup layout rule — **responsive, not "always side by side"**

The lockup is **side by side in landscape** and **stacked in portrait** (`source: 98-100`). The
breakpoint is `H > W` on the **stage box** (`source: 355`), applied to both `#stage` and `#lockup`
(`source: 359-360`).

| Stage shape | Lockup |
|---|---|
| Landscape (`H ≤ W`) | icon left, word column right — side by side |
| Portrait (`H > W`) | icon above, word column below, centred — stacked |

> **Correction — this is a breakpoint rule, not a blanket "side by side".** The Flutter client
> stacks the lockup **unconditionally** (`brand_intro_overlay.dart:347`). That is **correct** for
> the phone in portrait and **wrong** for the TV, which is landscape. Making the Flutter lockup
> side-by-side unconditionally would break the phone. See **L4** in §12.

## 7. The audio contract

### 7.1 The score

The score is an original composition, synthesized from scratch — no samples, nothing licensed
(`source: 12-14`). Its structure mirrors `render_intro_theme.py` 1:1 (`source: 573-575`):

> room tone → riser → **HIT 1** (A minor) → sheen → **HIT 2** (E major, a fifth up) + bell layer
> → pad → sparkle → handoff chime → master fade to silence at 3.00 s

Master chain: source bus → compressor (`threshold −14 dB`, `knee 10`, `ratio 3.2`, `attack 0.004`,
`release 0.25`) → destination, with a convolution reverb send (`source: 586-596`).

### 7.2 The non-blocking rule — **the single most important line in this document**

> **The audio must never gate the animation.**

The visual animation is scheduled and runs unconditionally. The `AudioContext` may be `suspended`
(browser autoplay policy) and the animation does not wait for it, does not stall, and does not
restart. The context is resumed on the first user gesture, via transparent one-time listeners on
`pointerdown`, `keydown` and `touchstart` (`source: 951-962`).

This is what makes the sequence work in Safari and Chrome without a click-to-start gate, and it is
the reason D1 chooses a canvas + separate audio over a `<video>` element.

### 7.3 Alignment

The audio starts at `ctx.currentTime + RAMP` where `RAMP = 0.12` (`source: 579, 782`), and the
animation's clock starts at `performance.now() + 120` (`source: 849`) — the same 120 ms.

### 7.4 Per-target

| Target | Score source | Notes |
|---|---|---|
| **Web** | **Live Web Audio synthesis** (D8) | The original's own approach. Zero asset bytes. |
| **Android phone** | `docs/opening-sequence/assets/intro-theme.wav` | 3.070 s, 44.1 kHz stereo, peak −1.01 dBFS. The offline render of the same composition. 529 KB. |
| **Android TV** | the same WAV | Identical bytes to the phone. |

## 8. The dismissal contract

**Dismissal is implicit. There is no Skip control and no Replay control anywhere.**

| Gesture | Effect | source |
|---|---|---|
| Click / tap on the stage | Skip to the end | 887-889 |
| `Space` | Skip to the end (or start, from the gate) | 890-897 |
| Any key / any D-pad press (Flutter) | Skip to the end | `brand_intro_overlay.dart:122-128` |

Skipping renders the final frame and finishes (`source: 857-864`): the layer is removed, the
audio stops over 0.10 s, and the app underneath is live and interactive.

**The HUD is not a product affordance.** The archived source's skip / replay / mute buttons
(`source: 228-233`) exist behind `SHOW_HUD=false` (`source: 931`) and are **not** ported. The
archived `window.INTRO.replay()` (`source: 945`) is likewise not ported (D4).

## 9. The reduced-motion contract

`prefers-reduced-motion: reduce` (`source: 331-332`) suppresses exactly four things, and no more:

| Suppressed | source |
|---|---|
| The impact burst particles | 411 |
| The camera shake | 541 |
| The icon's rotation (−7° → 0°) | 506 |
| The icon's scale (1.55 → 1) | 507 |

Everything else — the beams, the flash, the shockwaves, the wordmarks, the curtain — plays
normally. Per **D11** this is a contract on **all three targets**; the Flutter client honours
nothing today (**L11** in §12).

## 10. The gating contract

| Target | Rule | Owner |
|---|---|---|
| **Web** | **Once per browser session.** The **container** writes `sessionStorage.introSeen`; the overlay **must not** write it before the enclosing component's evaluation. | The mounting container (`web/src/app/AppShell.tsx`, Slice 11.3) |
| **Android phone** | **Every launch.** `IntroController.build()` sets `isPlaying: true` unconditionally. | `IntroController` |
| **Android TV** | **Every launch.** Same widget, same controller. | `IntroController` |

> **Note on the Flutter's `hasSeenIntro`.** The field exists (`intro_controller.dart:12`) and is
> set by `markFinished()`, but it is **never persisted and never consulted**. The "every launch"
> behaviour is therefore a *property of the current implementation*, not a designed gate. Slice 11.4
> must make that explicit in the code rather than leave it accidental (**L13** in §12).

The web's `?intro=` modes (Slice 11.3): `auto` (**the default**), `gate`, `capture`, `off`
(`source: 908-917, 969-975`).

> **Correction — the default mode is `auto`, not `gate`.** The archived standalone page defaulted to
> `gate`; the **injected overlay defaults to `auto`** (`source: 914`). `?intro=gate` is reserved
> strictly for manual testing.

## 11. The per-target status table

See §1 for the summary. The authoritative per-element position is the **divergence ledger** in §12.

## 12. The divergence ledger

Every difference between the canonical design and what each target does today. **This is the work
list for Slices 11.2 – 11.6 and 11.1a.** A row is closed only when its slice's exit criteria pass.

| # | Element | Canonical | Web (today) | Flutter (today) | Closed in |
|---|---|---|---|---|---|
| **L1** | Layer order | veils 2 → seam 3 → **fx 4** → vignette 5 → grain 6 → lockup 7 | built (11.2) | **fx is first in the `Stack`, i.e. at the bottom** (`brand_intro_overlay.dart:141-284`) | 11.2, 11.4 |
| **L2** | FX layer visible | beams, converging particles, impact flash, shockwave rings, standing glow, embers — **above** the curtain | built (11.2) | **never seen** — drawn *under* the opaque veils, so the whole 0.12–1.95 s build-up is invisible | 11.4 |
| **L3** | Grain | 5 % film grain over the FX, fading to 0 as the curtain opens | built (11.2) | **absent** | 11.4 |
| **L4** | Lockup layout | side by side in landscape, stacked in portrait | built (11.2) | **stacked unconditionally** (`:347`) — right for the phone, wrong for the TV | 11.4 |
| **L5** | Skip affordance | **none** | none (by design) | **visible Skip pill** (`:241-282`) | 11.4 |
| **L6** | Replay affordance | **none** (D4) | none (by design) | [CLOSED in 11.1a (2026-10-20)] - the Settings "Replay Brand Intro" item and the `BRAND & EXPERIENCE` section that contained it are gone, as are `IntroController.replay()` and its test. The docs that advertised it are updated. | **11.1a - done** |
| **L7** | Score | web: live synthesis · Android: the WAV | the lifecycle is 11.3 | **absent** | 11.3, 11.5 |
| **L8** | Curtain geometry | translate ±100 % of half-width; 1 px overlap; inner edge feathers only once parting; the two halves carry one continuous gradient | built (11.2) | halves **shrink** to zero width with **hard edges**, each with its own centred gradient (`:151-171`, `:297-320`) | 11.4 |
| **L9** | Ambient drift | **none** (D10 — dropped) | none (D10) | none | — closed by D10 |
| **L10** | Camera shake | deterministic, `t`-derived, 9 px peak, `impact → impact + 0.42` (D9) | built (11.2) | **absent** | 11.2, 11.4 |
| **L11** | Reduced motion | honoured on all three (D11) | the lifecycle is 11.3 | **not honoured** | 11.3, 11.4 |
| **L12** | Outro | layer **removed** at 3.00 s | built (11.2) | 300 ms opacity fade after 3.00 s, plus a 3.5 s safety timeout (`:81-83, 97-102`) | 11.4 |
| **L13** | Gating semantics | documented, deliberate | the lifecycle is 11.3 | "every launch" is **accidental** — `hasSeenIntro` is never persisted or consulted | 11.4 |
| **L14** | Dead asset | — | — | `assets/videos/intro-demo-portrait.mp4` is declared in `pubspec.yaml` and **never played** — 2.43 MB in every APK | 11.5 |
| **L15** | AGENTS.md's Flutter invariant | — | — | claims the intro is *"hardware-accelerated portrait video"*, claims `IntroController` provides session gating, and lists the Replay action — **all three wrong** | 11.1 (closed by this document) |

## 13. The oracle — how a later slice proves it matches

### 13.1 The frame-for-frame oracle (built in Slice 11.2)

**`web/e2e/intro-frame.spec.ts` puts the archived original and the port side by side, drives
both to the same instant, and compares what they painted.** Three comparisons, at three levels:

| Level | How | Result |
|---|---|---|
| **The FX canvas** | the SHA-256 of the canvas's pixels | **byte-exact** |
| **Every DOM layer** | the inline style (parsed, so the order the properties happen to be serialised in does not matter) and the rendered box — for the mark, the glow, both wordmark containers **and every letter of both**, the subtitle, the rule, both veil halves and their masks, the seam, the vignette, the grain, and the lockup | **exact** |
| **The whole overlay** | the rendered page, pixel by pixel | **exact** |

It runs at **20 sampled instants** covering every effect in the sequence — the beams, the
converging particles, the impact and its burst, the flash, the shockwave rings, the sheen, the
wordmarks, the subtitle, the rule, the embers, the curtain parting, the handover and the hold —
in **landscape (1920×1080) and portrait (1080×1920)**.

**Three things are normalised, and each is a rendering mechanic rather than a design element:**

1. **The camera shake's randomness.** The original draws it from `Math.random()` and the port's
   is deterministic (D9), so the two can never agree by accident. The oracle patches the
   original's `Math.random` to hand it **exactly the two draws the port used**, so the original
   computes the same offsets from the same formula. The shake window is compared like any other
   — it is not skipped.
2. **The compositor hint.** The mark and the lockup carry `will-change`, which promotes them to
   their own composited layers, and a promoted layer's antialiasing is a hair different from the
   same content painted directly. The markup, the computed styles and the geometry are identical
   to the last bit; the two *documents* simply promote them differently. The hint is taken out of
   the comparison on both sides.
3. **The first frame.** The original paints frame zero at load (source 965). The harness must do
   the same, or the two documents accumulate a different history — and the compositor then
   rasterises the wordmark's glyphs differently, which is invisible to the eye but was 58 of 255
   on a glyph edge.

### 13.2 The archived asset pipeline (the offline renders)

| Tool | What it does |
|---|---|
| `docs/opening-sequence/scripts/serve_with_intro.py` | Read-only injection proxy. Injects the archived overlay over the **running app**, independently of the app's own code. |
| `docs/opening-sequence/scripts/capture_overlay_frames.py` | Drives `INTRO.renderAt(t)` (`capture_overlay_frames.py:77`) over CDP to capture reference frames — 90 landscape, 90 portrait. |
| `docs/opening-sequence/scripts/encode_videos.py` | Re-encodes both MP4s from the captured frames, with the score. |
| `docs/opening-sequence/scripts/verify_overlay.py` | 12 behavioural checks against the running server. |
| `docs/opening-sequence/scripts/verify_app_integration.py` | Live-service verifier — drives the real app. |

The **archived** PNGs were captured with the original's random shake (`source: 541-544`), so they
are a *visual* reference inside the `0.62 – 1.04 s` window and a byte oracle everywhere else.
Slice 11.6 re-captures them against the shipped implementation, after which they are a byte
oracle everywhere.

---

# Part II — Historical record

*Everything in Part II is what happened. It is preserved, not rewritten, because it is the evidence
for Issue 10 and the reason Phase 11 exists.*

## 14. The loss (2026-10-18) — the web overlay is gone

**This is a missed backlog item from the Flask → React migration, not a design change.**

### What happened

The opening sequence shipped in the Flask era as a Jinja2 template, `templates/intro-overlay.html`,
included at the end of the library page. Its whole life in git:

```text
a10e9ef  feat(intro): wire the brand opening sequence into the library page
107220f  chore: sync latest development
5a2af4f  refactor(ui): decommission legacy Jinja templates and static assets (Slice 7E.2)   <- deleted
```

Slice 7E.2 retired nine legacy templates, `templates/intro-overlay.html` among them. Its own
walkthrough recorded the template's removal and verified that *"the React SPA (`web/dist/`) serves
all pages directly without dependency on server-side Jinja templates"* — which was true, and was
the wrong question. It asked whether the **architecture** still worked, not whether the **feature**
survived. No `BrandIntro`/`IntroOverlay` component exists in `web/src`, and a search across
**all branches and all of history** finds no React component that ever existed.

### What is true today

| | State |
|---|---|
| **Web (React/Axum)** | **No intro.** `web/src` contains no overlay component. The only surviving trace is a *type*, `intro?: "auto" \| "gate" \| "off"`, in the generated `web/src/lib/api/schema.ts` (line 1562), mirroring the old OpenAPI spec. The query parameter is inert: `https://media.anisparvez.in/?intro=off` and `?intro=auto` both return the plain SPA shell. |
| **Rust/Axum** | Nothing to port. The overlay is a client-side DOM layer injected *over* the running app, so the backend's only involvement is serving the runtime media files as static assets. `rust/src` correctly contains no intro code. |
| **Flutter client** | **Still implemented and tested.** `flutter_client/lib/features/intro/presentation/widgets/brand_intro_overlay.dart` and `presentation/controllers/intro_controller.dart`, with its own copy of `assets/videos/intro-demo-portrait.mp4`, plus `brand_intro_overlay_test.dart` and `intro_controller_test.dart`. |
| **Assets** | **All intact** in `docs/opening-sequence/` — 293 MB total: `intro-demo.mp4` (2.2 MB), `intro-demo-portrait.mp4` (2.4 MB), `intro-theme.wav` (529 KB), 90 landscape + 90 portrait PNG frames (~280 MB, the source material for re-rendering the video), the stills, and the original `source/intro-overlay.html` and `source/intro.html`. |
| **Generation tooling** | `docs/opening-sequence/scripts/*.py` — the canvas capture, video encoding, theme rendering and verification scripts. `cdp_local.py` needs `websockets`; the rest are standard library. |

### Why it went unnoticed for two days

`AGENTS.md` asserted that the overlay *"is wired into the React SPA in
`web/src/components/BrandIntroOverlay.tsx`"*. **That file has never existed on any branch.** The
invariant was written as though the port had been done, so every later reader — human or agent —
had a reason to believe the feature was live. `docs/OPENING_SEQUENCE.md`'s status line said
*"delivered and wired into the application"* for the same reason.

Both claims have been corrected. The AGENTS.md web invariants are now explicitly marked as the
**specification for a port that has not been written**, rather than as a description of the
current app.

### The port is well-specified, not a redesign

Everything needed is intact:

- The **design** — now frozen as **Part I of this document**.
- The **invariants** — `AGENTS.md` §"Brand Opening Sequence (Intro Overlay) Invariants".
- The **assets** — `docs/opening-sequence/assets/`.
- A **working reference implementation** of the same visual design, in the Flutter client.

The Rust side needs only to serve the runtime media files from `web/public/`; the 280 MB of PNG
frames is re-render source material and does not need to ship.

The one requirement that is easy to get wrong, and that the old template was careful about, is
recorded in §5: the overlay must be **injected over the running app**, not a snapshot of it.

## 15. How it was wired in the Flask era

The overlay was included as the **last** thing in `templates/library.html`, so the app's own scripts
had already run and what the curtain opened onto was a fully initialised page:

```jinja
{# templates/library.html — at the very end of the file #}
{% include 'intro-overlay.html' %}
```

> **This is how it WAS wired.** The template and the include were both deleted in Slice 7E.2
> (2026-10-18). A React port must reproduce this behaviour — the overlay injected at the very
> end of the page, over the live app — but with a React component rather than a server-side
> include.

The archived source exposes `window.INTRO` with `play()`, `skip()`, `replay()`, `finish()`,
`renderAt(t)`, `pageMode()`, `playback()`, `audio`, `timeline`, `duration` (`source: 944-949`).
That is the **archived demo API** — it is what the capture harness drives, and what
`capture_overlay_frames.py` calls. It is not a product surface, and `replay()` in particular is
**not** ported (D4).

## 16. Where the artifacts live

Everything for this work lives inside the repository in `docs/opening-sequence/`:

| Path | What it is |
|---|---|
| `docs/opening-sequence/scripts/serve_with_intro.py` | read-only injection proxy — forwards every request, rewrites only `text/html` |
| `docs/opening-sequence/scripts/cdp_local.py` | headless-Edge CDP driver (launch, attach, evaluate, real clicks, clipped captures) |
| `docs/opening-sequence/scripts/capture_overlay_frames.py` | 90-frame capture per orientation, resumable, with a duplicate-run audit |
| `docs/opening-sequence/scripts/encode_videos.py` | normalises rasters and encodes both cuts with the score |
| `docs/opening-sequence/scripts/render_intro_theme.py` | the score's source (standard library only) |
| `docs/opening-sequence/scripts/verify_overlay.py` | 12 behavioural checks against the running server |
| `docs/opening-sequence/scripts/verify_app_integration.py` | live-service verifier — drives the real app, all checks pass |
| `docs/opening-sequence/scripts/convert_to_overlay.py` | asserted, reproducible record of the standalone→overlay conversion |
| `docs/opening-sequence/source/intro.html` | pre-overlay source, kept as the conversion's input |
| `docs/opening-sequence/source/intro-overlay.html` | **the canonical source** (973 lines), preserved verbatim |
| `docs/opening-sequence/assets/intro-theme.wav` | score master — 3.070 s, 44.1 kHz stereo, peak −1.01 dBFS |
| `docs/opening-sequence/assets/intro-demo.mp4` | 1920×1080, 30 fps, 90 frames, 3.000 s, H.264 CRF 17 + AAC 192 kbps |
| `docs/opening-sequence/assets/intro-demo-portrait.mp4` | 1080×1920, same encoding — for the Flutter client |
| `docs/opening-sequence/assets/stills/` | keystills from the encoded videos |
| `docs/opening-sequence/frames/` | 90 PNGs landscape, captured over the live app (regenerable) |
| `docs/opening-sequence/frames-portrait/` | 90 PNGs portrait |
| `docs/opening-sequence/README.md` | full specs, integration notes, capture realities, verification table |

## 17. Re-rendering the videos

Captured with **local headless Edge over CDP** — same origin as the app, real input events, no
`data:` URLs and no cloud session to drop (Edge is on every Windows host, so no new dependency is
needed).

```bash
python docs/opening-sequence/scripts/serve_with_intro.py --port 8001 &        # the app wearing the intro
python docs/opening-sequence/scripts/capture_overlay_frames.py landscape      # -> frames/           (resumable)
python docs/opening-sequence/scripts/capture_overlay_frames.py portrait       # -> frames-portrait/
python docs/opening-sequence/scripts/render_intro_theme.py                    # -> assets/intro-theme.wav
python docs/opening-sequence/scripts/encode_videos.py                         # -> both MP4s
python docs/opening-sequence/scripts/verify_overlay.py                        # 12 behavioural checks
```

`capture_overlay_frames.py` sets the layout viewport with `Emulation.setDeviceMetricsOverride`, so the
app lays out at exactly the captured size — desktop 1920×1080 for landscape, and a 540×960 phone
viewport at DPR 2 (delivered as 1080×1920) for portrait, which makes the app render **its own** mobile
layout rather than a scaled desktop one.

## 18. The verification record (archived, 12/12)

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

## 19. Rendering notes worth keeping

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

## 20. Honest notes

- Portrait frames are captured at 2160×3840 (DPR 2 × clip scale 2) and Lanczos-downscaled to 1080×1920
  — supersampled, hence slightly softer-edged than the landscape frames, which are a native 1:1 render
  of the app at 1920×1080.
- One library item (`IMG 5167`) has no artwork in the real library, so it shows the app's own
  placeholder. That is the app being accurate, not a capture defect.
- The videos show the library **as it stood at capture time**; re-run the capture + encode after
  library changes.
- The rendered artifacts (`frames/`, `frames-portrait/`, the MP4s and the WAV) are regenerable from
  the scripts and the live app; they are kept here as the delivered deliverables and for re-verification.
- The archived MP4s and PNGs were rendered from the **pre-D6** design. The lockup is unchanged in the
  archived source (D6 changes the *Flutter* client to match the source, not the source itself), but
  Slice 11.6 re-renders them against the shipped implementation regardless.

---

**Related:** [`docs/PHASE_11_OPENING_SEQUENCE_PLAN.md`](PHASE_11_OPENING_SEQUENCE_PLAN.md) ·
[`docs/SLICE_7E_WALKTHROUGH.md`](SLICE_7E_WALKTHROUGH.md) §6 ·
[`docs/Current issues.md`](Current%20issues.md) Issue 10 ·
`AGENTS.md` §"Brand Opening Sequence (Intro Overlay) Invariants"
