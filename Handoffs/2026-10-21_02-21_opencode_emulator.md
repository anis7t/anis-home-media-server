docs(intro): what an Android emulator can and cannot settle

The owner asked whether an emulator could stand in for the phone and the
television during the on-device checks. It can, for part of it. This records
what was tried, what it proved, and the two things it cannot do - so that
nobody spends another evening on the parts that do not work.

## WHAT IS INSTALLED, AND THAT IT IS REAL

The Android SDK on this host is at `D:\platform-tools-latest-windows` (not the
default `%LOCALAPPDATA%\Android\Sdk`), and it already carried the emulator
(37.2.12.0), a system image (`android-36 / google_apis_playstore / x86_64`)
and two AVDs. Nothing was downloaded.

`medium_phone` is **1080x2400, Android 16** - the owner's phone's own OS and
resolution. It runs **hardware-accelerated**: the emulator reports

    WHPX on Windows 10.0.26300 detected.
    Windows Hypervisor Platform accelerator is operational

even though `Get-WindowsOptionalFeature` reports `HypervisorPlatform:
Disabled`. **Do not trust that cmdlet here** - `HypervisorPresent` is true and
the emulator's own detection is the authority. No reboot, no feature enable,
no administrator rights were needed. Cold boot is 66 seconds.

Graphics: `-gpu host` gives the guest the host's **Radeon RX 560X**
(`gles_mode_selected:host`). `-gpu swiftshader_indirect` does not work as a
fallback: it saturates the emulator's CPU and **SystemUI ANRs** ("System UI
isn't responding" on screen). Always `-gpu host` here - the host is not
transcoding while it runs.

## WHAT IT PROVED

On build 1.2.21+143, in profile and release:

  * the app installs, launches and runs on Android 16;
  * `media_kit` initialises - `libmpv.so` and
    `libmediakitandroidhelper.so` load, `package:media_kit_libs_android_video
    attached`, and the device facts are read (`google/sdk_gphone64_x86_64`);
  * the **score plays**: `audioplayers` takes audio focus
    (`USAGE_MEDIA/CONTENT_TYPE_MUSIC`) and holds it for 2.6 seconds before
    abandoning it - the sequence's own length;
  * the **launch window is dark**, not white: the Android 12+ system splash is
    the app icon on the curtain colour, which is the phone-side counterpart of
    the television's `-v21` drawable fix;
  * the sequence runs to completion and the app is revealed behind it.

## WHAT IT CANNOT DO, AND WHY NOT TO RETRY IT

**It cannot reproduce the Fire TV's problem.** There is no `android-tv` image
installed, and the guest renders on the host's Radeon, not on a 2015 PowerVR
Rogue GE8300. The television's failure is Skia compiling GL programs inside the
first frame; no emulator on an AMD desktop will show that. The television check
stays a real-device check.

**It cannot photograph a three-second sequence.** Every capture path was
measured against the sequence's 3.0 s:

  * `adb shell screencap -p /sdcard/x.png` + pull: **2.3 s**
  * `adb exec-out screencap -p > file`: **3.6 s**
  * `adb shell screenrecord`: wrote **1-2 frames** for a 6-14 s recording
  * `ext.flutter.screenshot` over the DDS: **`Unknown method`** - this Flutter
    version does not register it
  * the engine's `_flutter.screenshot` over the VM service: **`Could not
    capture image screenshot`** with Impeller, and **the same with Skia**
    forced (`am start --ez enable-impeller false`, which does take effect -
    the engine prints the opt-out deprecation notice)

So the emulator can be driven and read through **logcat**, and not through its
pixels. Budget accordingly.

**And `--tv` does not arrive.** `main(List<String> args)` reads the *values* of
the activity's intent extras (Flutter's `getDartEntrypointArguments`), so
`am start --es tv "--tv"` should give `args = ['--tv']`. In practice the intro
took the painted path: `media_kit` initialised but nothing opened the asset and
no video decoder ran. Do not build a television test on that flag; a television
needs the television.

## RESIDUAL TASKS KILLED

The session had accumulated processes that outlived their purpose:

  * the old `flutter attach --debug-url ...` (already exited) and its
    **orphaned DDS** (`dart development-service`, still listening);
  * a `flutter_tester` from an 18:43 test run, alive seven hours later;
  * the emulator itself - stopped at the end, because leaving it up holds the
    host's GPU, which is the one resource AGENTS.md warns about;
  * `E:\MediaServer\_em`, scratch written inside the repository.

Kept: Serena's Dart language server (it needs it) and the Gradle daemon (it
makes the next APK build fast).

## THE LAST COMMIT CARRIED 107 MiB OF SCRATCH

`443b0d8` included **185 files under `build/`** - the CRF comparison encodes
and 180 extracted frames from the video oracle, 107 MiB. They are scratch; the
shipped artifact is `flutter_client/assets/intro/intro-tv-1080p.mp4`.

The commit was unpushed and unnamed in any document, so it was **amended**
rather than followed by a cleanup commit: `build/` is now untracked and
`/build/` is in `.gitignore`. `198 files changed` became `14 files changed`,
and the working tree is clean at **`7e60b2b`**.

## WHERE THAT LEAVES PHASE 11

Unchanged, and still blocked on the owner's devices: the on-device check of
143 - the television's smoothness and score, the phone's underlines. The
emulator narrowed the risk (the app runs on Android 16, the score plays, the
launch window is dark) without closing either item.

## THE UNDERLINE REGRESSION TEST

The phone's double yellow underlines (Slice 11.8) had no test that could catch
a regression. The picture oracle renders the overlay in a bare `MaterialApp`,
and a bare test's ambient style never carries a decoration - so it is clean by
construction, and it stays clean after the rule is deleted. That is exactly why
the fault reached the phone.

`flutter_client/test/features/intro/intro_typography_test.dart` closes it. It
pumps the overlay under a `DefaultTextStyle` carrying the worst ambient style
it can - underlined, yellow (`0xFFFF00`), double, 14 px - in both aspects, then
reads **every painted span's resolved style** (`RichText.text.style`, which is
the style after the `Text` widget has merged the ambient one in, not what some
widget asked for) and requires `TextDecoration.none` on all of them. The
subtitle is checked separately for its own colour (`#94A3B8`), its own size and
the same `none`.

**Proven to bite, not assumed.** With the two `decoration: TextDecoration.none`
lines deleted from `brand_intro_overlay.dart`, all three cases fail with

    Expected: TextDecoration:<TextDecoration.none>
    Actual:   TextDecoration:<TextDecoration.underline>
    this span kept the ambient decoration: "A"

which is the phone's fault exactly. The rule was then restored by copying the
file back, and `git status -- flutter_client/lib` is empty.

With the rule in place: **3/3 pass**, `flutter analyze` clean, and the whole
intro suite is **51/51** through `scripts\run_flutter_tests.ps1 -TestPath
test/features/intro` (the frame oracle's numbers are unchanged: landscape
means 3.32-10.19 at 89.0-100.0 % within tolerance, portrait 3.32-10.21 at
89.4-100.0 %).

## L22 IS WRONG ABOUT THE MECHANISM

The ledger says the client "cross-fades the video out over the last 0.25 s".
It does not. `_IntroVideoStage` is a `Video` in a `BoxFit.cover`, with no
`Opacity`, no `AnimatedOpacity` and no fade of any kind; at 3.00 s the overlay
is **removed**. What is there is a **hard cut**.

Measured, to see what that cut actually costs:

  * the video's last frame, sampled at four points, is uniformly
    **R=8 G=8 B=16** (the separator's `#080810` backdrop after yuv420p
    rounding);
  * `AppColors.background`, which the shell paints under everything, is
    **`#090B10` = 9,11,16**.

So the cut is a **1/3/0 jump in a very dark screen** - not a flash, not a
visible seam, but not a match either. L22's *divergence* stands (an opaque
video cannot reveal live content, so content appears rather than emerging);
its *mechanism* is what is false.

**The owner's decision: correct the ledger, do not add a fade.** The
canonical's own outro is *"a removal at 3.00 s, not a fade"* (L12), so a fade
would be a **new** divergence rather than a fidelity fix - and it would have to
be replicated on the phone for the two targets to keep agreeing. Corrected in
all three places that carried the same false claim: L22 in
`docs/OPENING_SEQUENCE.md`, section 11.7.6 of the plan, and
`scripts/capture-intro-video.mjs`'s own header comment, which said "the app
fades in behind the video's last quarter-second".

## THE APK TO INSTALL IS THE RIGHT ONE

Two version numbers disagree, and both are true: `pubspec.yaml` says
`1.2.18+138`, and the APK is **1.2.21 / 143** because it was built with
`--build-name` / `--build-number` overrides, so the pubspec was never bumped.
`aapt dump badging` is the authority for what a package carries:

    package: name='in.anisparvez.media_server_client' versionCode='143' versionName='1.2.21'

It was built at **01:19**. The newest source file it has to contain,
`brand_intro_overlay.dart`, was written at **01:15**, and it carries both
`decoration: TextDecoration.none` rules (`:1067` the wordmark's merged style,
`:1155` the subtitle's). So the artifact on disk **is** the one with the
underline fix - **nothing needs rebuilding before the device check**, and
nobody should be surprised by the 138 in the pubspec.

## STATE: THE PHASE WAITS ON THE OWNER'S DEVICES

Asked at 02:29 whether the television was free; the answer was **not yet** -
the owner is casting a series to it. **Do not touch either device, and do not
install anything, until the owner says so.**

Everything else in Phase 11 is done and committed:

    ca9a6e3  docs(intro): the APK waiting to be installed is the one with the fix
    0d65e40  docs(intro): L22 records the hard cut it actually is
    488bd08  test(intro): the typography cannot inherit an ambient decoration
    7e60b2b  feat(intro): the television plays a pre-rendered sequence

The remaining work, in order:

  1. install 143 on the television (`192.168.1.70:5555`) and check the
     sequence's smoothness, the score, dismissal and the 2.57 s handover;
  2. install 143 on the phone (`192.168.1.6:40557`) and check the underlines
     are gone, the live sequence runs, and the score plays;
  3. close Phase 11 - Part II of `docs/OPENING_SEQUENCE.md` and the AGENTS.md
     work queue;
  4. the ~6 dB web score-level finding (spec section 7.9) stays open after
     that; it is the last known item of the phase's own making.
