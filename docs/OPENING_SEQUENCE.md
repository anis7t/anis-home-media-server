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

### 2.1a The three decisions taken with the Slice 11.3a plan (2026-10-20)

| # | Question | Answer |
|---|---|---|
| **D12** | The gesture that unlocks the audio is the same gesture that dismisses the intro. How does that resolve? | **The unlocking gesture is consumed by the audio.** The score starts in step with the animation and **the animation continues**; a *second* gesture dismisses. The literal alternative — start the score *and* dismiss — would play a three-second score over an intro that is no longer there, and the score is meant to be heard *with* the visuals. The cost is real and is recorded in §7.5: **the first click during the intro no longer skips it.** |
| **D13** | Should the port's noise be seeded, like the original's camera shake (D9)? | **Seeded.** The original drew its reverb impulse response and every noise buffer from `Math.random()` (`source: 602, 610`), so its live synthesis was never bit-reproducible. Seeding makes the port's render reproducible, which is what lets the oracle compare renders at all. The perceptual difference is nil — it is noise either way. |
| **D14** | The gate card's wording | **The original's, verbatim** (`source: 940-944`): the button reads *"▶ Play with sound"* and the hint reads *"Original synthesized theme. Browsers require a click before audio can play, so press play — `space` skips, `m` mutes."* The `m` mute is ported with it, because a hint that says *"`m` mutes"* and a key that also skips would be a lie. |

### 2.1b The two decisions taken with the Slice 11.4 plan (2026-10-20)

| # | Question | Answer |
|---|---|---|
| **D15** | The gating: the specification says "Android: every launch", and the code did that **accidentally**. How should it be made deliberate? | **Keep "every launch", and say so.** The dead `hasSeenIntro` flag — written when the sequence finished, never persisted, never read — is gone, and the controller now states the behaviour. The alternative was to persist it (`shared_preferences` is already a dependency) and play **once per install**; that is a visible change to the product, and the specification does not ask for it. |
| **D16** | The handover at 2.57 s: the web releases **both** touches and keys, but on a television a D-pad press must not navigate the app behind the sequence. | **The Flutter client releases touches at 2.57 s and keeps the keyboard for the whole three seconds.** A remote cannot drive the app while the sequence is still on screen. This is a deliberate divergence from the web, and it is recorded as **L17**. |

### 2.1c The three decisions taken with the Slice 11.5 plan (2026-10-20)

| # | Question | Answer |
|---|---|---|
| **D17** | Which player plays the score on the phone and the TV? | **`audioplayers` 6.8.1** — a pure-Dart wrapper over Android's `MediaPlayer`. It is small, and its platform interface makes the host tests a fake, so the suite never touches a real player. `just_audio` is built for streaming and long-form playback; `soundpool` is for rapid-fire game sound effects; and `media_kit`, though already a dependency, is a **video** engine whose **host** backend is the libmpv that Issue 11 is about. |
| **D18** | Should `m` mute the score on the Flutter client, as it does on the web? | **No — any key dismisses, as the Flutter client does today.** The web's `m` is a mute that does not dismiss (D14, §7.6); the Flutter client treats **every** key as a dismissal, and keeping that is the smaller change. The consequence is that **the Flutter client has no `m` mute**, and the score is silenced by the device's own volume. That is a divergence from the web, and it is recorded as **L18**. |
| **D19** | The intro plays on every launch (D15), so the score will make a sound on every cold launch. | **Yes — the canonical behaviour.** The score is part of the sequence on every target, and the web makes the same sound whenever its context is allowed to play. |

### 2.1d The decisions taken with the Slice 11.7 plan (2026-10-21)

| # | Question | Answer |
|---|---|---|
| **D24** | The Fire TV's 2015 GPU cannot render the sequence at 60 fps: its first frame alone costs 1.09 seconds, because Skia on OpenGL ES compiles each new draw program at runtime and the television has no Vulkan for Impeller. How does the television show the sequence? | **The television plays a pre-rendered video of it.** The video is rendered from the shipped web application — the canonical — so the picture is the canonical's by construction, and the GPU only decodes frames, which is exactly how the streaming apps get their smoothness. The phone keeps the live sequence, because the phone is not that device. |
| **D25** | The canonical suppresses four effects under `prefers-reduced-motion`, and a video has them baked in. | **Under reduced motion the television keeps the live sequence.** The contract holds where it is observable, and the video is used for the normal case. |
| **D26** | Should the score be muxed into the video? | **No — it stays a separate WAV**, played by `audioplayers` and anchored to the **video's playback position**. Muxing would re-encode the canonical's own render, and the score is the one asset the client holds byte for byte. Anchoring to the video's position is also the canonical's own rule (§7): the sound and the picture agree about where the sequence is, because the anchor *is* the picture's position. |
| **D27** | The wordmarks paint with `DefaultTextStyle.merge`, so the ambient style's **decoration** is inherited too — and on the phone the ambient style carries one, so the sequence showed yellow underlines the canonical does not have. | **The sequence's typography is not the ambient style's to decide.** The merged style sets `decoration: TextDecoration.none` explicitly. The canonical's font stack is still inherited — that inheritance is deliberate, because the canonical puts the platform's UI font first — but the decoration is not. |

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

> **The web's reference is the original's Web Audio, not the WAV.** The source's comment that the
> Web Audio "mirrors `render_intro_theme.py` 1:1" is about the **composition**, not the samples.
> The two are different syntheses: the Python renderer sweeps a resonant **low-pass** over its noise
> beds and the original's Web Audio uses a **band-pass**, and the two filters do not produce the
> same signal. The WAV is the **Flutter** client's reference (it plays the file); the archived
> overlay's `window.INTRO.audio` is the **web** port's reference. §13.2 is the oracle that says so.

### 7.2 The non-blocking rule — **the single most important line in this document**

> **The audio must never gate the animation.**

The visual animation is scheduled and runs unconditionally. The `AudioContext` may be `suspended`
(browser autoplay policy) and the animation does not wait for it, does not stall, and does not
restart. The context is resumed on the first user gesture, via transparent one-time listeners on
`pointerdown`, `keydown` and `touchstart` (`source: 951-962`).

This is what makes the sequence work in Safari and Chrome without a click-to-start gate, and it is
the reason D1 chooses a canvas + separate audio over a `<video>` element.

**In the port this is structural, not a promise.** The renderer (`web/src/lib/intro/`) has **no
reference to the audio module at all** — the score is owned by `web/src/lib/intro/audio.ts` and
reached only through the overlay. A suspended `AudioContext` cannot reach the render loop, and the
score's `start()` returns `false` (rather than throwing) when there is no Web Audio at all, which
is the source's own fail-safe (`source: 779`).

### 7.3 Alignment

The audio starts at `ctx.currentTime + RAMP` where `RAMP = 0.12` (`source: 579, 782`), and the
animation's clock starts at `performance.now() + 120` (`source: 849`) — the same 120 ms.

**`RAMP` is not a lead-in for the score — it is what makes the two agree.** The score's zero is
placed at `ctx.currentTime + RAMP - elapsed`, where `elapsed` is how far the animation has already
played. At `elapsed = 0` that is the source's own expression; at any other value it is the same
instant as the animation's zero, seen from the audio clock.

### 7.4 The score is anchored, not orphaned

The original schedules the whole score against `ctx.currentTime + RAMP` and nothing else. **A
suspended context's clock does not advance**, so if the context resumed a minute later the original
would play the entire three-second score, from the top, out of nowhere.

The port's contract:

| Situation | What happens |
|---|---|
| The context is already running when the sequence starts | The score is scheduled at `ctx.currentTime + RAMP` and is in step with the animation. |
| The context is suspended and the animation is still running when it resumes | The score starts **now**, anchored to the animation's position: the score's zero is placed `elapsed` seconds in the past, so the remaining voices land on their own beats. **A voice whose beat has already passed is skipped**, not fired late. |
| The context resumes **after** the animation has ended | **The score is dropped.** A three-second score playing out of nowhere is worse than no score. |

The drop is structural: the overlay's unlock listeners live only while the sequence is playing, so
there is no late resume to react to.

### 7.5 The unlocking gesture (D12)

**The gesture that unlocks the audio is the same gesture that dismisses the intro.** The original's
own `unlockAudio` listeners fire on `pointerdown` / `keydown` / `touchstart` (`source: 951-962`)
and the stage's click handler skips the sequence (`source: 887-889`) — so, read literally, the one
gesture that could start the score would also throw the animation away, and the score would play
over an intro that is no longer there.

**The port's rule: the unlocking gesture is consumed by the audio.**

| Gesture | Effect |
|---|---|
| The **first** gesture while the audio is still suspended | It resumes the context and starts the score **in step with the animation**. The animation **continues**. |
| Any **later** gesture | It dismisses the sequence, as §8 says. |
| A gesture when the context was **already running** | It dismisses, as §8 says. There was nothing to unlock. |

**The cost, stated plainly: the first click during the intro no longer skips it.** A user who
wanted out has to click twice. That is the price of the score being heard *with* the visuals
rather than after them, and it is D12's answer.

### 7.6 The mute key

`m` **mutes**, and does not dismiss (`source: 894-896`). This is the one exception to §8's "any key
dismisses", and it exists because the gate's own hint — the original's, restored verbatim by D14 —
says *"`m` mutes"*. A hint that says a key mutes and a key that also skips would be a lie.

The HUD that the original's mute button lived in is **not** ported (D4/D6); the key is.

### 7.7 The noise is seeded (D13)

The original's reverb impulse response and every noise buffer are drawn from `Math.random()`
(`source: 602, 610`). The port draws them from a fixed seed, so **two renders of the same score are
the same signal** — which is what makes §13.2's reproducibility oracle possible at all.

### 7.8 Per-target

| Target | Score source | Notes |
|---|---|---|
| **Web** | **Live Web Audio synthesis** (D8) | The original's own approach. Zero asset bytes. Built in Slice 11.3a. |
| **Android phone** | `docs/opening-sequence/assets/intro-theme.wav` | 3.070 s, 44.1 kHz stereo, **peak −2.98 dBFS, RMS −19.00 dBFS**. The offline render of the same composition. 541,592 bytes. **Shipped, byte for byte, since Slice 11.5.** |
| **Android TV** | the same WAV | Identical bytes to the phone. |

> **Correction.** This table previously said the WAV peaks at **−1.01 dBFS**. It does not: the
> measured peak is **−2.98 dBFS** (`20·log₁₀(0.7093)`), and the RMS is **−19.00 dBFS**
> (`20·log₁₀(0.1121)`). The −1.01 figure was wrong, and no code depended on it.

### 7.9 The Flutter client's score — the web's contract, on the phone

The phone and the TV play the canonical's **offline render**, because Flutter has no Web Audio and
the composition has to be the same music either way. The *contract* is the web's (§7.4), with the
platform's differences taken into account.

| Situation | What happens |
|---|---|
| The player is ready when the sequence starts | The score starts at the sequence's t = 0 ✓ |
| The player is **not** ready — Android's preparation took 80 ms | The score starts when it is ready, **anchored to the sequence's position at that moment** ✓ — the same anchoring as the web ✓ |
| The sequence is over by then | **The score is dropped** ✓ — a sound out of nowhere is worse than no sound ✓ |
| The sequence is dismissed | The score stops ✓, and it cannot outlive the overlay ✓ |
| Always | **The animation never waits for the audio** ✓ — the score is prepared before the first frame, in the application's entry point, and nothing awaits it ✓ |

> **The one thing the two do not share is the unlocking gesture.** The web's score waits for a user
> gesture, because a browser will not play audio without one (D12). **Android has no such
> policy**, so the Flutter client's score starts on its own — and the intro makes a sound on every
> cold launch, which is D19. That is **L18**.

### 7.9 The open level finding

The port's score renders **quieter than the archived original's own Web Audio** under an offline
render: the original measures a peak of 1.213 and an RMS of 0.376, the port a peak of 0.613 and an
RMS of 0.067 — about **6 dB** apart, and the original's own peak **exceeds full scale**.

What is **not** the cause, all of it measured:

- **Not a doubled score.** The original builds exactly 33 oscillators — the score's oscillator
  count, once — and the port builds 33.
- **Not the reverb.** Replacing the original's `ConvolverNode` with a zero gain changes its level
  by 0.1 %.
- **Not a different graph.** Every node the original creates, counted by kind, matches the port's
  exactly — 33 oscillators, 11 noise buffers, 78 gains, 23 filters, 36 panners, 1 convolver,
  1 compressor, 2 shapers. (That equality is itself the oracle; it is what caught the riser's
  spurious high-pass.)
- **Not the noise.** Both draw from the same seeded stream in the same order.

The port's level **does** match the shipped WAV within **1.3 dB in peak** (0.613 against 0.709) and
its envelope tracks the WAV's within **16 dB** in every 155 ms window. So the port is at the level
of the audio the Flutter client ships, and the archived original's live Web Audio is the outlier —
but *why* it is the outlier is **not known**, and it is recorded as an open finding rather than
papered over. It does not block 11.3a: the oracle in §13.2 proves what 11.3a set out to prove.


## 8. The dismissal contract

**Dismissal is implicit. There is no Skip control and no Replay control anywhere.**

| Gesture | Effect | source |
|---|---|---|
| Click / tap anywhere on the overlay | Skip to the end | 887-889 |
| `Space` | Skip to the end (or start, from the gate) | 890-897 |
| Any key / any D-pad press (Flutter) | Skip to the end | `brand_intro_overlay.dart:122-128` |

**Two exceptions on the web, both deliberate.**

| Gesture | Effect | Why |
|---|---|---|
| `m` | **Mutes. It does not dismiss.** | The original's behaviour (`source: 894-896`), and the gate's own hint — the original's wording, restored verbatim (D14) — says *"`m` mutes"*. §7.6. |
| The **first** gesture while the audio is still suspended | **It is consumed by the audio**, and the animation continues | D12. The one gesture that could unlock the score would otherwise also throw the animation away. §7.5. |

Skipping renders the final frame and finishes (`source: 857-864`): the layer is removed, the
audio stops over 0.10 s, and the app underneath is live and interactive.

**And one exception on Flutter, which is a divergence from the web (D16).** The Flutter client
releases **touches** at the handover (2.57 s) so the app underneath is live, but it keeps the
**keyboard** for the whole three seconds, so a D-pad press dismisses the sequence rather than
navigating the app behind it. The web releases both, because a browser's key events and pointer
events are the same kind of thing; on a television they are not. **L17** in §12.

**The Flutter client has neither of the two web exceptions.** It has **no `m` mute** — any key
dismisses, as it always has (D18, **L18**) — and it has **no unlocking gesture**, because Android
has no autoplay policy and the score starts on its own (§7.9).

> **The original's click-to-skip does not work, and the port's does.** The source tests
> `e.target === el.stage` (`source: 888`), but the FX canvas (z-index 4) and the curtain halves
> (z-index 2) have no `pointer-events: none` — so a click always lands on one of them and never
> on the stage, and the check never passes. The port listens on the stage itself and lets the
> event bubble, so a click anywhere on the overlay dismisses, which is also what the Flutter
> client does. (After the handover at 2.57 s the stage releases the pointer, so a click on the
> app underneath does **not** dismiss — the sequence is effectively over by then.)

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

### 10.1 The web's modes, and what each one does

| Mode | Behaviour | Records the intro as seen? |
|---|---|---|
| `auto` | **The product behaviour.** Plays automatically, once per browser session. | **Yes**, when the sequence starts |
| `gate` | The manual-testing card. It waits for the play button. **The session gate does not apply** (`source: 969-971`). | **Yes**, when the sequence starts — so a manual view does not leave the intro pending |
| `capture` | A still page for reproducible frames. No auto-play, no auto-removal, and a render handle exposed. | **No** — a verification run must not consume the user's session |
| `off` | **Nothing is mounted.** The component is never in the tree. | n/a |

> **The original's `intro=(auto|replay|force)` escape hatch is removed.** The source's auto mode
> plays the intro **even when it has been seen**, if the URL carries one of those values
> (`source: 976`). That is a Replay mechanism, and **D4 forbids one**. The session gate is
> therefore unconditional, and `?intro=gate` is the manual way to watch the intro again.

### 10.2 Who owns the gate

**The container.** `web/src/hooks/useIntroSequence.ts` reads `sessionStorage.introSeen` **during
render**, decides whether to mount the overlay, and records that the intro has started. **The
overlay has no `sessionStorage` reference at all** — which is asserted against the component's own
source, not merely at runtime, because a runtime spy would only prove it for the paths a test
happens to exercise.

**The decision is made once, at mount**, in a `useState` initialiser rather than an effect. Under
`StrictMode` — which the app enables — effects run twice, so an effect-time read would see the
flag the container had just written itself, decide the intro had already been seen, and never play
it at all.

### 10.3 The capture handle

In `?intro=capture` the overlay exposes `window.__INTRO__` with the original's shape — `renderAt`,
`timeline`, `duration`, `pageMode` — so the existing capture tooling needs only a one-line change to
drive the port instead of the archived overlay. It is exposed **only** in that mode, and its name is
underscore-prefixed to mark it internal.

## 11. The per-target status table

See §1 for the summary. The authoritative per-element position is the **divergence ledger** in §12.

## 12. The divergence ledger

Every difference between the canonical design and what each target does today. **This is the work
list for Slices 11.2 – 11.6 and 11.1a.** A row is closed only when its slice's exit criteria pass.

| # | Element | Canonical | Web (today) | Flutter (today) | Closed in |
|---|---|---|---|---|---|
| **L1** | Layer order | veils 2 → seam 3 → **fx 4** → vignette 5 → grain 6 → lockup 7 | built (11.2) | **CLOSED in 11.4 (2026-10-20)** — the FX canvas is now **above** the curtain, as is the seam, the vignette, the grain and the lockup. It was the **first** child of the `Stack` (the bottom), so the whole build-up was painted and then covered by two opaque halves. | 11.2, **11.4** |
| **L2** | FX layer visible | beams, converging particles, impact flash, shockwave rings, standing glow, embers — **above** the curtain | built (11.2) | **CLOSED in 11.4** — all seven effects and the sheen are now implemented in `flutter_client/lib/features/intro/presentation/painters/intro_fx_painter.dart`, ported from the canonical renderer. The particles are the canonical's: the same seeded fields, bit for bit. | 11.2, **11.4** |
| **L3** | Grain | 5 % film grain over the FX, fading to 0 as the curtain opens | built (11.2) | **CLOSED in 11.4, with one recorded divergence** — the grain exists, at the same 5 % and the same fade. The canonical's is an SVG `feTurbulence` filter, which Flutter cannot render (there is no SVG filter support); the Flutter client uses a **seeded white-noise** texture with the same tile size and the same colour matrix. The same *kind* of texture, not the same pixels. | 11.2, **11.4** |
| **L4** | Lockup layout | side by side in landscape, stacked in portrait | built (11.2) | **CLOSED in 11.4** — the layout is now the canonical **breakpoint rule**, decided by the **stage's aspect** (`H > W`) and never by the device type. It was a `Column`, stacked unconditionally: right for the phone, wrong for the TV. | 11.2, **11.4** |
| **L5** | Skip affordance | **none** | none (by design) | **CLOSED in 11.4** — the visible Skip pill is gone. Dismissal is implicit: a tap anywhere, or any key. | **11.4** |
| **L6** | Replay affordance | **none** (D4) | none (by design) | [CLOSED in 11.1a (2026-10-20)] - the Settings "Replay Brand Intro" item and the `BRAND & EXPERIENCE` section that contained it are gone, as are `IntroController.replay()` and its test. The docs that advertised it are updated. | **11.1a - done** |
| **L7** | Score | web: live synthesis · Android: the WAV | **built (11.3a)** — the port of the original's Web Audio, in `web/src/lib/intro/audio.ts`, with the score anchored to the animation's clock, the unlocking gesture consumed by the audio (D12), the `m` mute, and the drop rule (§7.4-§7.7) | **CLOSED in 11.5 (2026-10-20)** — the phone and the TV play the canonical's offline render, **byte for byte**, anchored to the sequence when it starts, dropped if the sequence is over, and never waited for (§7.9). The asset is `assets/audio/intro-theme.wav`, and the score's SHA-256 is asserted against the canonical's in the test suite. | **11.3a, 11.5 - done** |
| **L8** | Curtain geometry | translate ±100 % of half-width; 1 px overlap; inner edge feathers only once parting; the two halves carry one continuous gradient | built (11.2) | **CLOSED in 11.4** — the halves **translate** ±100 % of their own width, they overlap by 1 px, their inner edges feather only once they part, and they carry **one** continuous image (the same stage-wide gradient, offset by half a stage to the left and to the right). They used to **shrink to zero width** with hard edges, each with its own centred gradient. | 11.2, **11.4** |
| **L9** | Ambient drift | **none** (D10 — dropped) | none (D10) | none | — closed by D10 |
| **L10** | Camera shake | deterministic, `t`-derived, 9 px peak, `impact → impact + 0.42` (D9) | built (11.2) | **CLOSED in 11.4** — the same deterministic hash, so the two targets shake identically. It was absent. | 11.2, **11.4** |
| **L11** | Reduced motion | honoured on all three (D11) | the lifecycle is 11.3 | **CLOSED in 11.4** — `MediaQuery.disableAnimationsOf` is honoured, and it suppresses **exactly** the four things: the impact burst, the camera shake, the icon's rotation and the icon's scale. It was honoured by nothing. | 11.3, **11.4** |
| **L12** | Outro | layer **removed** at 3.00 s | built (11.2) | **CLOSED in 11.4** — the layer is removed at 3.00 s. It used to fade to zero over 300 ms, and carry a 3.5 s safety timeout. | 11.2, **11.4** |
| **L13** | Gating semantics | documented, deliberate | the lifecycle is 11.3 | **CLOSED in 11.4** — "every launch" is now **stated**, and the dead `hasSeenIntro` flag is gone. It was set when the sequence finished and never persisted and never read, so the behaviour was accidental rather than designed. | 11.3, **11.4** |
| **L14** | Dead asset | — | — | **CLOSED in 11.5 (2026-10-20)** — `assets/videos/intro-demo-portrait.mp4` was declared in `pubspec.yaml`, **never played**, and cost **2.43 MB** in every APK. It is gone from the pubspec and from the tree, and the asset section now names exactly one file: the score. The APK's assets shrink by about **1.9 MB**. | **11.5 - done** |
| **L15** | AGENTS.md's Flutter invariant | — | — | claims the intro is *"hardware-accelerated portrait video"*, claims `IntroController` provides session gating, and lists the Replay action — **all three wrong** | 11.1 (closed by this document) |
| **L16** | The mark | the canonical SVG, path for path | the shared `BrandMark` | **CLOSED in 11.4** — the mark is now the canonical artwork. The Flutter client's re-implementation had the **wrong specular highlight** (`v 19.4 … L23.2 18.0` where the canonical is `v8.5 l14.2-1.4 L12 9.2z`, so the highlight covered roughly twice its area) and a hard `drawShadow` at six units where the canonical has a soft `feDropShadow dy=2 stdDeviation=3`. | 11.2, **11.4** |
| **L17** | The handover | the app underneath is interactive from 2.57 s | the layer releases `pointer-events` at 2.57 s | **CLOSED in 11.4, with one recorded divergence** — the Flutter client releases **touches** at 2.57 s and keeps the **keyboard** for the whole three seconds, so a D-pad press cannot navigate the app behind the sequence. The web releases both. §8. | 11.2, **11.4** |
| **L18** | The score's **start** and the **`m` key** | the web waits for a gesture, and `m` mutes without dismissing | the unlocking gesture is consumed by the audio (D12); `m` mutes and does not dismiss (D14) | **RECORDED in 11.5 (2026-10-20)** - the Flutter client has **no unlocking gesture** (Android has no autoplay policy, so the score starts on its own, and the intro makes a sound on every cold launch - D19) and **no `m` mute** (any key dismisses, as the Flutter client always has - D18). The score is silenced by the device's own volume. | 11.5 |
| **L19** | **How the sequence is rendered on a television** | the sequence is **painted** | the television **plays a pre-rendered video** of it; the phone still paints it | **RECORDED in 11.7 (2026-10-21)** - the Fire TV's GPU is a 2015 PowerVR Rogue GE8300 with no Vulkan, so Impeller is unavailable and Skia compiles each new draw program at runtime: the first frame's raster measured **1.09 seconds** and the three-second sequence got **five frames**. The video is rendered from the canonical itself, so the picture is the canonical's; it is verified against the canonical's reference frames at **58 instants** (the worst mean error **5.33/255**, the mean of the means **2.34/255** - the H.264 grain). | 11.7 |
| **L20** | **The typeface inside the video** | the canonical's font stack: `'Inter', system-ui, …` | the video's wordmarks are drawn with the **capture machine's** system font; the live sequence uses the **device's** platform font | **RECORDED in 11.7 (2026-10-21)** - neither the web nor the client bundles a typeface, so the canonical's own rendering is already a system font, and the video's is the one on the machine that rendered it. On the television the live sequence and the video therefore differ in their letterforms, as the web on a desktop and the web on the television already do. | 11.7 |
| **L21** | **The grain inside the video** | the SVG turbulence, re-rasterised every frame | the video carries the grain as encoded pixels | **RECORDED in 11.7 (2026-10-21)** - the canonical's grain is per-pixel noise, which is the one thing a video codec cannot carry exactly: the measured mean error against the reference frames is **2.34/255** and up to **2.89 %** of pixels differ by more than 32/255, all of it in the grain. This is the same class of difference as the Flutter client's own grain (L3), carried by the codec rather than by the renderer. | 11.7 |
| **L22** | **How the application is revealed** | the curtain **parts** and the live application appears through the opening | on the television the curtain parts onto the application's background colour, and at 3.00 s the sequence is **removed** onto the live application | **RECORDED in 11.7 (2026-10-21), mechanism corrected 2026-10-21.** An opaque video cannot reveal live content behind it, so the video's parting window carries the application's own background colour, and the application's content **appears** rather than emerging from behind the curtain — the **timing** of the reveal is therefore 1.05 s later than the canonical's. It is a **hard cut, not a fade**: at 3.00 s the layer is removed, which is the canonical's own outro rule (L12 — "a removal at 3.00 s, not a fade"). Measured: the video's last frame is uniformly **R=8 G=8 B=16** (the capture backdrop `#090b10` after yuv420p's rounding) against `AppColors.background` **9,11,16**, so the cut is a **1/3/0 jump in near-black**. An earlier version of this row claimed a 0.25 s cross-fade; **no fade was ever implemented**, and adding one would be a new divergence from the canonical, not a fidelity fix. The phone is unaffected. | 11.7 |

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

**And a sixth test: the shipped application.** The five above compare the archived original against
the test-only harness page. The sixth compares the **real app**, in its `?intro=capture` mode,
against the same harness — pixel for pixel, at every sampled instant. That is what makes the
verified thing the thing that **ships**.

> **The curtain does not hide the page until it has fully parted.** The halves' inner edges are
> **feathered** — the source gives each a mask whose transparent band is `4 + 11 × progress` percent
> of the half's width (`source: 552-557`). The band of the page the curtain does not fully hide is
> therefore the gap **plus** those two feather bands, and it is the only place the app's own
> content can show through. The shipped-app comparison requires every differing pixel to fall
> inside that band, and nowhere else.

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

### 13.2 The score's oracle (built in Slice 11.3a)

**`web/e2e/intro-audio.spec.ts` puts the archived original's audio and the port's side by side and
compares them.** Three comparisons, at three levels — plus the composition table, which is pinned
separately.

| Level | How | Result |
|---|---|---|
| **The composition** | `web/src/lib/intro/score-golden.json` — a transcription of the original's `build(t0)` (`source: 698-776`) — against the port's own voice table | **exact** |
| **The graph** | every node the original's score creates, counted by kind, against the port's | **exact** — 33 oscillators, 11 noise buffers, 78 gains, 23 filters, 36 panners, 1 convolver, 1 compressor, 2 shapers |
| **The signal** | the port's offline render against `intro-theme.wav`, on the shape of the score over time (20 windows of 155 ms) | within **16 dB** in every window; the peak within **1.3 dB** |
| **Reproducibility** | two renders of the port's own score | identical to within **1 × 10⁻⁴** |

**The graph comparison is exact, and it is what caught the port's real defect.** The original builds
the **riser inline** (`source: 709-714`) rather than through `noiseVoice`, so it has **no
high-pass** and its sweep ends at `t + 0.60` rather than at the generic `dur × 0.9`. The port gave
the riser a spurious 120 Hz high-pass — one extra filter, and a quieter riser than the original's.
Counting the nodes by kind found it in one run.

**How the original is rendered offline.** The archived overlay is served from the dev server's own
origin (its document lives outside `web/`, which Vite will not serve), its `AudioContext` is
replaced with an `OfflineAudioContext`, and `Math.random` is replaced with the port's own seeded
PRNG — so the original's noise draws and the port's come from the **same sequence**, and the score's
noise beds are created in the same order in both.

> **What the graph oracle does *not* settle.** The two renders still differ in level by about
> **6 dB**, and the cause is not known. §7.9 lists everything that was measured and ruled out. The
> oracle asserts what it can prove exactly — the graph — and the tolerance it does assert is
> measured, not guessed.

### 13.3 The Flutter client's oracle (built in Slice 11.4)

The Flutter client cannot be compared to the archived original **pixel for pixel** — Chromium's
rasteriser and Flutter's are not the same, and they never will be: font metrics, gradient
interpolation, antialiasing and blend modes all differ. So the comparison is in **two tiers**, and
each answers a different question.

| Tier | What it compares | How | Result |
|---|---|---|---|
| **The parameters** | every animated value, at **69 instants** | the canonical renderer (the web's, which is pixel-identical to the archived original) is exported to `docs/opening-sequence/frame-golden.json`, and the Flutter client's own frame is asserted against it, **value for value** | **exact** — to 1 × 10⁻⁹ |
| **The picture** | the rendered frame, against the **archived original's own frames** | the Flutter overlay is rendered at the archived frames' instants and at their viewports, and the two are compared perceptually | the mean error stays **under 14 / 255**, and **at least 86.5 %** of the pixels stay within 32 / 255, at every one of the 58 frames of the closed-curtain window, in both aspects |

**The parameters are the load-bearing tier.** The fixture is generated by
`scripts/gen-intro-frame-golden.mjs`, and it records the values the canonical implementation
**rendered** — parsed out of the very strings it wrote to the DOM, because the rounding is part of
the rendering. The Flutter client's `jsToFixed` is JavaScript's `toFixed`, and that equivalence is
itself tested (`intro_tofixed_test.dart`, against a captured reference).

**The picture tier covers the closed-curtain window** — every frame up to t = 1.90 s, 58 of the 90
in each aspect. That is the whole build-up: the beams, the converging particles, the impact, the
burst, the flash, the shockwaves, the standing glow, the sheen, the wordmarks, the subtitle, the
rule, the embers, the mark's landing — every effect the previous Flutter implementation painted
and then hid under an opaque curtain. It is also the window in which the comparison is *exact in
principle*: the curtain is opaque, so what is behind it does not matter.

> **The parting window is not compared as pictures, and the reason is not a convenience.** The
> archived frames were captured over the **web** application, so what shows through the parting
> curtain is the web app. The Flutter client runs a different application, and the two cannot be
> compared there. The parting is not left unproven: its **geometry** is pinned exactly by the
> parameter tier — both halves' travel, both halves' feather, the seam's opacity, the lockup's
> dismissal, the vignette and the grain, at 69 instants. What the picture tier adds is that the
> geometry is not merely right but *drawn* right.

> **Two things about the picture tier that are worth knowing.** The frames are compared at the
> **logical** scale, because a widget test can only capture there — the archived portrait frames are
> 1080 × 1920 *pixels* (a 540 × 960 viewport at a device pixel ratio of 2), and comparing a
> 540 × 960 capture against them compares the top-left quarter of one with the whole of the other.
> And the **word column is excluded**: a Flutter widget test renders text with the **Ahem** test
> font, whose glyphs are solid squares, so the wordmarks cannot be compared as pictures at all.
> Their *parameters* are pinned exactly by the parameter tier instead.

**The seeded fields are compared too.** The converging particles and the embers come from the
source's `mulberry32`, and Dart's 64-bit integers do not behave like JavaScript's 32-bit ones.
The port reimplements JavaScript's `Math.imul` and the `| 0` coercions, and
`intro_timeline_test.dart` asserts the particles, the embers and the camera shake against a
captured reference — **bit for bit**.

> **Three things the oracle caught that no listening test would have.** The first port of the
> particle fields took the random draws in the order the constructor's *named arguments* happened
> to be evaluated — and Dart does not promise that order — so every particle landed somewhere
> else. The first `toFixed` multiplied by the scale factor, which rounds: a value just below a
> midpoint can land exactly on it, and the curtain's feather at t = 2.57 came out one unit in the
> last place away from the canonical's. And the mark had **no size** at all: a `CustomPaint` with
> no child and no size is zero-sized, so the canonical mark simply did not appear.

### 13.4 The archived asset pipeline (the offline renders)

| Tool | What it does |
|---|---|
| `docs/opening-sequence/scripts/serve_with_intro.py` | Read-only injection proxy. Injects the archived overlay over the **running app**, independently of the app's own code. It listens on **:8001** and forwards to the app on **:8000** - the injection proxy's own port, not a retired backend. |
| `docs/opening-sequence/scripts/cdp_local.py` | headless-Edge CDP driver (launch, attach, evaluate, real clicks, clipped captures) |
| `docs/opening-sequence/scripts/capture_overlay_frames.py` | Drives `INTRO.renderAt(t)` over CDP to capture reference frames - 90 landscape, 90 portrait. |
| `docs/opening-sequence/scripts/encode_videos.py` | Re-encodes both MP4s from the captured frames, with the score. |
| `docs/opening-sequence/scripts/verify_overlay.py` | 12 behavioural checks against the running server. |
| `docs/opening-sequence/scripts/verify_app_integration.py` | Live-service verifier - drives the real app. |
| `scripts/capture-shipped-frames.mjs` | **Slice 11.6.** Re-captures the frames against the **shipped** implementation, proves the capture is reproducible, and replaces the archived ones. |

#### The re-capture (Slice 11.6)

The archived frames were captured from the **archived original** over the running application, in a
cloud browser, at the time the original drew its camera shake from `Math.random()` (source 541-544).
Three things have changed since, and the re-capture is what makes the frames a reference again:

| | |
|---|---|
| **The shake is deterministic** (D9), so the frames inside the shake window (0.62 - 1.04 s) are now reproducible - and they differ from the archived ones, which carried a random shake. |
| **The application is the React one**, so the frames in the parting window show a different application. |
| **The browser is a different one**, and two things rasterise differently there: the SVG grain's turbulence (**1-2 units over the whole frame**) and the Gaussian blur on the wordmarks (a large delta on the glyph edges, over a tiny area). |

**So the frames are not, and cannot be, byte-identical to the archived ones.** The re-capture proves
the two things that *can* be proved:

| Claim | How it is proved | Measured |
|---|---|---|
| **Reproducible** | the capture is run twice, and the two runs must be byte-identical **where the curtain is closed** - which is where the frames are a property of the overlay alone | the landscape **58/58**; the portrait **55/58** (the three stragglers differ in a bounded region on the blurred wordmark) |
| **Faithful** | the new frames are compared, pixel by pixel, with the archived ones, outside the shake and the parting | **0.013 %** of the landscape's pixels differ by more than 32/255, and the mean error is **0.02**; the portrait is **0.140 %** and **0.99** |

The metric is the same one the Flutter client's oracle uses (section 13.3), so the two are comparable.
The archived frames are replaced only if the comparison passes - which is what makes the replacement
safe.

> **The frames after the parting show the live application, and it is not static between runs.**
> The application behind the curtain is a live client - its data arrives when it arrives - so those
> frames are reproducible only in the sense that they were captured once. The closed-curtain window
> is the reference, and it is fully reproducible.

#### The videos

`encode_videos.py` re-encodes both MP4s from the frames, with the score. They are **archival
artefacts** now: the Flutter client used to be described as their consumer, and since Slice 11.5 it
ships the **WAV** instead and never played a video.

### 13.5 The responsive sweep (Slice 11.6)

Decision **D7** says the sequence is resolution-independent, and the sweep is what proves it.

| Target | How it is proved | Result |
|---|---|---|
| **Web** | the archived original is a standalone document that can be laid out at **any** viewport, so the oracle puts it and the port side by side at **five** aspects and compares them **pixel for pixel** | **exact** at every one of them: landscape, portrait, ultrawide (2560 x 1080), tablet (1024 x 1366) and a modern phone (1080 x 2400) |
| **Flutter** | the lockup's **arrangement** follows the breakpoint, the canonical's **clamps** hold, nothing overflows, and the **parameters** match the canonical's fixture at that aspect's design unit | **exact** at all five aspects |

> **The breakpoint is the stage's aspect, never the device type.** A phone in landscape gets the
> side-by-side lockup, and a television would get the stacked one if it were ever held in portrait.
> The Flutter client's test asserts the arrangement from the rendered geometry, so a device that
> lies about what it is cannot get the wrong layout.

> **The frame is the same sequence at every aspect.** Every value in it is aspect-independent except
> the lockup's vertical travel, which is `pl * u * 2.4` - so the fixture carries the travel for
> each design unit the sweep visits, and the Flutter client is asserted against the one for its own
> aspect.

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
| `docs/opening-sequence/assets/intro-theme.wav` | score master — 3.070 s, 44.1 kHz stereo, peak −2.98 dBFS, RMS -19.00 dBFS |
| `docs/opening-sequence/assets/intro-demo.mp4` | 1920×1080, 30 fps, 90 frames, 3.000 s, H.264 CRF 17 + AAC 192 kbps |
| `docs/opening-sequence/assets/intro-demo-portrait.mp4` | 1080×1920, same encoding — archival; the Flutter client has shipped the WAV since Slice 11.5 and never played a video |
| `docs/opening-sequence/assets/stills/` | keystills from the encoded videos |
| `docs/opening-sequence/frames/` | 90 PNGs landscape, captured over the live app from the SHIPPED implementation (Slice 11.6), regenerable with `scripts/capture-shipped-frames.mjs` |
| `docs/opening-sequence/frames-portrait/` | 90 PNGs portrait, likewise |
| `scripts/capture-shipped-frames.mjs` | re-captures the frames from the shipped implementation and proves the capture reproducible (Slice 11.6) |
| `scripts/gen-intro-frame-golden.mjs` | generates the canonical frame fixture, with the lockup's travel per design unit |
| `docs/opening-sequence/frame-golden.json` | the canonical frame, at 69 instants, for the Flutter client to assert against |
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
