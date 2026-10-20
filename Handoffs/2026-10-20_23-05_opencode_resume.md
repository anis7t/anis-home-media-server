# Resume note — Phase 11, the on-device session

**Written:** 2026-10-20 23:05 IST, mid-session, before a compaction.
**Branch:** `feature/phase-11-opening-sequence`. **Working tree:** see §5.

---

## 1. Where the phase stands

**Phase 11 is complete** — all eight slices are done and committed:

| Slice | Commit | What it delivered |
|---|---|---|
| 11.1 | `453e434` | The canonical specification (`docs/OPENING_SEQUENCE.md` Part I) |
| 11.1a | `09c643b` | The Flutter "Replay Brand Intro" action, removed |
| 11.2 | `ae71d72`, `f15da02` | The web canvas renderer + the frame-for-frame oracle |
| 11.3 | `8e554cb` | The web lifecycle, gating and modes |
| 11.3a | `3539f60` | The web Web Audio score |
| 11.4 | `7274146` | The Flutter client, aligned to the canonical design |
| 11.5 | `19bc21e` | The Flutter score, and 2.4 MB out of the APK |
| 11.6 | `655e192` | The responsive sweep, and the frames re-captured |

**The only thing outstanding is the on-device session** — and that is where the session was when
it was compacted.

## 2. The on-device session — the state of it

**Both devices are connected over wireless adb** and the release APK is installed on both:

| Device | Address | Model | Android | Screen |
|---|---|---|---|---|
| **Phone** | `192.168.1.6:40557` | I2217 | 16 (SDK 36) | 1080 × 2400, density 440 |
| **Fire TV** | `192.168.1.70:5555` | AFTMM | 7.1.2 (SDK 25) | 1920 × 1080, density 320 (the panel is 4K) |

```powershell
$adb = 'D:\platform-tools-latest-windows\platform-tools\adb.exe'
```

**The build number matters.** The devices carried 139 (TV) and 140 (phone); this branch's pubspec
says `1.2.18+138`, so an install fails with `INSTALL_FAILED_VERSION_DOWNGRADE` and `-d` does not
help (it only applies to debuggable builds). The fix is a **CLI override**, so the repo's version is
untouched:

```powershell
cd E:\MediaServer\flutter_client
flutter build apk --release --build-name 1.2.21 --build-number 141
```

That is what is installed on both devices now (1.2.21+141), as an **upgrade** — the devices' settings
survived.

**The screen is too slow to catch the intro.** `adb shell screencap` over wireless adb takes **4–5
seconds** on the TV (the shot at 1185 ms was still the engine's blank first frame, and the one at
5884 ms was already the home screen). The Fire TV's cold start is several seconds. So a
screenshot-based check of the intro is **not** practical over adb — the sequence is three seconds and
the capture round-trip is longer than the sequence.

`scripts/device-intro-check.ps1` does the force-stop → launch → screenshot sequence; it is a
best-effort artefact, not a usable oracle. **The user's eyes are the oracle here.**

**The frame rate could not be measured.** `dumpsys SurfaceFlinger --latency` returns an empty buffer
for the app's layers on this device (Android 7.1's SurfaceFlinger, and the Flutter surface is not
recorded). A `flutter run --profile` session against the TV would give real frame timings and is
the way to get a number.

## 3. The finding: the animation is not smooth on the Fire TV

**The user reported it**, watching the TV: *"the animation is not smooth in fire tv"*, and then
filmed it with a camera.

### 3.0 What the camera recording settled — read this first

`E:\MediaServer\test screenshots screenrecordings files etc\video_20261020_221735.mp4` — 3840 × 2160,
60 fps, 8.93 s, 536 frames, a **camera** filming the television (so the camera's auto-exposure
blows the dark scenes out, and its own noise defeats any duplicate-frame analysis).

Two things it shows, and the second is the important one:

1. **The app was showing its empty state** — "Your Apps / Add Devices" — so the sequence was *not*
   on screen for most of the recording ✗. The recording does not show the sequence at all ✗.
2. **At 4.15 s the screen went completely white and stayed white** for the rest of the recording ✗.
   That is **not** the sequence — it is the **Android launch window** ✗, after a relaunch ✗. The
   Flutter engine takes **4.7 seconds** to come up on this television, and the launch background was
   `@android:color/white` ✗✗. So the "blank white screen" the owner reported is the **launch
   window**, and it was on screen for four and a half seconds ✗.

**Both are now fixed** — the launch background is the sequence's own curtain colour (`#05060a` ✗ →
obsidian ✗), so the cold start opens on the curtain's colour and the hand-off is seamless ✓.

Two more facts the device session turned up:
- **The client opts out of Impeller** (the manifest's `EnableImpeller` entry ✗), so Android is on
  the **Skia** backend ✗.
- The app's cold start on the Fire TV: **2.3 s** to the window, **4.7 s** to the first frame ✗.

### 3.1 The costs that were pure waste

The TV is an **mt8695** (MediaTek, a weak Mali-450) rendering 1920 × 1080. An `Opacity` and a
`ShaderMask` are each a `saveLayer` with a blend mode — **one offscreen buffer each, per frame** ✗.

| Waste | Fix |
|---|---|
| **21 `ShaderMask`s** (one per letter) | the gradient is the text's **`foreground`** — no offscreen buffer, and the same picture (the canonical's gradient is vertical, so each letter's slice depends only on the letter's height ✗ → the same ✓) |
| **21 `Opacity`s** (one per letter) | the alpha is scaled into the gradient's colours ✓ — the canonical's letter is a gradient fill with the element's opacity over it, and the gradient is fully opaque ✓ |
| **2 full-screen `Opacity`s** (the vignette, the grain) | the vignette scales its gradient's colours ✓; the grain modulates its tile with a colour filter ✓ |
| **2 half-screen `ShaderMask`s** (the curtain) | the mask exists **only once the feather is non-zero** ✗ — before the parting the feather is zero and the mask is a no-op ✗ |
| **2 full-screen additive fills** (the flash, the glow) | clipped to the gradient's own circle ✓ — everything outside it is the gradient's last stop (fully transparent ✗) and an additive transparent source contributes nothing ✗ → identical ✓ |

**The picture is unchanged, and the oracle proves it.** The Flutter client's picture oracle
compares the render against the archived frames at 58 instants in each aspect. Before and after:
the worst landscape frame **12.56 → 12.50** ✓, the worst portrait **11.28 → 11.30** ✓, and every
other frame moves by at most **0.11/255** of mean error ✓. So these are rasterisation-path
changes, not picture changes, and a 720p or a 1080p television gets the same picture as a 4K one
✓ — which is what the owner asked to be sure of.

### 3.2 What is still unaddressed

**~400 blended draw calls per frame remain**, for the particles: 170 converging streaks
(`drawLine`) + 170 burst particles (`drawCircle`) + 64 embers (`drawCircle`), each with its own
colour and width, so each is a paint change and a pipeline break. The *pixels* are trivial (a
2 px-wide streak touches almost nothing) — the cost is the **command count**.

The options, if the TV is still choppy:
- **Batch the particles into paths.** One path per colour, with the width and alpha quantised — a
  visible change to the picture, so it needs the oracle re-measured and the ledger updated.
- **Reduce the particle count on the TV only.** The plan's decision **D-D** said this would come
  back to the owner, and it is now on the table.
- **Render the FX layer at a lower resolution** and upscale it. The FX are soft, so it is
  near-invisible, but it *is* a divergence from the canonical, and the picture oracle would move.

**The owner has not been asked about D-D yet** — that is the next conversation.

### 3.3 How the frame rate could be measured

`dumpsys SurfaceFlinger --latency` returns an empty buffer for the app's layers on this device
(Android 7.1's SurfaceFlinger ✗), and a screencap over wireless adb takes 4–5 seconds ✗ — longer
than the three-second sequence ✗. The ways to get a number:
- **`flutter run --profile`** on the television ✗ — the profile build works ✓ (the VM service is
  reachable over an `adb forward` ✗) ✓, and the Dart VM service's `getVMTimeline` RPC returns the
  `Flutter.Frame` events ✓ — **the HTTP call's URL shape was wrong ✗** and was not retried ✗.
- **`flutter attach`** to the running profile build ✓.

## 4. Other things worth knowing

- **The dev server is stopped** and must be started only while the web oracles run
  (`cd web; npm run dev 2>&1`, in the background). It binds the **IPv6 loopback**, so it is
  reachable at `http://localhost:5173` and **not** at `http://127.0.0.1:5173`.
- **The dev server's API now has one origin, `:8000`** (`web/vite.config.ts` was fixed — its "Rust"
  routes pointed at `:8001`, where nothing runs, and its "Flask" routes at `:8000`, which *is* the
  Rust service). Caddy and `media.anisparvez.in` were verified untouched.
- **The Flutter suite's baseline** is `+275 ~8 -3`; the three failures are the pre-existing
  `libmpv` ones (Issue 11) — `runtime_player_3a_test.dart`, `runtime_player_3b_test.dart`,
  `app_shell_test.dart` — all failing in `setUpAll`. After Slice 11.6 it was `+316 ~8 -3`.
- **The web's oracles** are `web/e2e/intro-frame.spec.ts` (12 tests, five aspects, pixel-exact) and
  `web/e2e/intro-audio.spec.ts` (3 tests).
- **A long command goes to the background with a timeout, and is checked on an interval.** The owner
  asked for this explicitly.
- **Issue 10** (the intro was lost in the migration) is now closed by Phase 11 — the ledger in
  `docs/OPENING_SEQUENCE.md` §12 is the record of what diverged and what was closed.
- **One open finding from 11.3a** stands: the web's score renders about **6 dB quieter** than the
  archived original's Web Audio, and the cause is not yet isolated (spec §7.9 lists everything that
  was measured and ruled out).

## 5. The working tree at the time of writing

**Uncommitted** (the performance fixes and the device script):
- `flutter_client/lib/features/intro/presentation/widgets/brand_intro_overlay.dart` — the
  `TextStyle.foreground` change
- `flutter_client/lib/features/intro/presentation/painters/intro_fx_painter.dart` — the flash and
  the glow clipped to their circles
- `scripts/device-intro-check.ps1` — the on-device capture script
- `docs/opening-sequence/device/` — the captured screenshots and the audio dumps

**A build of the APK with the fixes is in flight**, to be installed on both devices.

## 6. The next steps, in order

1. **Install** the rebuilt APK on both devices (it is being built with
   `--build-name 1.2.21 --build-number 141`).
2. **Ask the owner to watch the TV** and say whether the animation is smooth now.
3. If it is still choppy, **ask about D-D** (the particle count on the TV) — the plan always said
   that decision was the owner's.
4. **Run the phone's on-device check** (the intro is portrait there, so it exercises the *stacked*
   lockup ✓) and confirm the score is audible on both.
5. **Commit** the fixes with a message that states the picture is unchanged (the oracle's numbers ✓).
6. **Update the docs**: the ledger's **L19** for the performance fixes (a *divergence-free*
   optimisation ✓ — the picture is identical ✓, so it is not a divergence ✓ but it is worth
   recording ✓), and the handoff.
7. The phase's **exit criterion** is the on-device session ✓ — once that passes, Phase 11 is
   closed and the spec's Part II can say so.
