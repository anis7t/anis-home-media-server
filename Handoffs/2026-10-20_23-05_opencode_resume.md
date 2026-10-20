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

**The user reported it**, watching the TV: *"the animation is not smooth in fire tv"*.

The TV is an **mt8695** (MediaTek, a weak Mali-450) rendering 1920 × 1080. Two costs in the
Flutter overlay are pure waste, and both were fixed:

### 3.1 Twenty-one `ShaderMask`s per frame → zero

`_IntroLetter` painted each letter's gradient with a `ShaderMask`, and a `ShaderMask` is a
`saveLayer` with a blend mode — **one offscreen buffer per letter**, and there are twenty-one
letters (5 in "Anis'", 16 in "Home Media Server"). Twenty-one offscreen buffers *every frame* is
the difference between smooth and not.

**The fix:** the gradient is painted as the text's **foreground** —
`TextStyle(foreground: Paint()..shader = ui.Gradient.linear(...))` — which paints through the
glyphs' own shape with **no offscreen buffer at all**.

It is the **same picture**: the canonical's gradient is *vertical*
(`linear-gradient(180deg, #ffffff 36%, #cbd5e1 100%)`), so each letter's slice of it depends only on
the letter's height, which is the same for every letter of a word.

### 3.2 Two full-screen additive gradient fills → clipped to their own circles

The **impact flash** and the **standing brand glow** each filled the **whole stage** with an
additive (`BlendMode.plus`) radial gradient, when the gradient itself only covers a circle of
`diag × 0.55` and `diag × 0.3`. An additive fill of the whole framebuffer is a
read-modify-write of 2 million pixels, twice per frame.

**The fix:** the fill is clipped to the gradient's own circle. Everything outside the circle is the
gradient's last stop — fully transparent — and an additive transparent source contributes nothing, so
**the picture is identical** and the fill is a fraction of the size.

### 3.3 The proof that the picture did not change

**The Flutter client's picture oracle** (`flutter_client/test/features/intro/intro_frame_visual_test.dart`,
run with `MEDIA_SERVER_INTRO_VISUAL=all`) compares the render against the archived frames at
58 instants in each aspect. **The numbers before and after the fixes are the same to within
0.02/255 of mean error and 0.1 % of pixels** — the worst landscape frame is 12.56 (at t = 0.633) and
the worst portrait frame is 11.28 (at t = 1.033), both exactly where they were. So the changes are
**rasterisation-path changes, not picture changes, at any resolution** — which is what the user
asked to be sure of ("make sure it doesn't affect tv with lower resolution or 1080p").

### 3.4 What is still unaddressed

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
