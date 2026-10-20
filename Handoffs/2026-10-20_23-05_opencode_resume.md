docs(intro): the Fire TV's white screen, and what the choppiness actually is

Two device findings, both measured on the television rather than reasoned about.

## WHAT THE OWNER'S CAMERA FILM SHOWED

`E:\MediaServer\test screenshots screenrecordings files etc\video_20261020_221735.mp4` -
3840 x 2160, 60 fps, 8.93 s, a **camera** filming the television. So the
camera's auto-exposure blows the dark scenes out to white and its own noise
defeats any duplicate-frame analysis: a film is the wrong instrument for a
frame rate.

What it does show: the app's empty "My Apps" state for the first 4.15
seconds, and then **a completely white screen for the rest of the recording** -
after a relaunch. That white was the Android launch window, and it lasted
4.6 seconds because the Flutter engine takes that long to come up on this
television. It is fixed below.

The device's own `screenrecord` is the right instrument - it is exact - but on
this television it manages only about 5 frames a second at 1080p, and once
wrote a single frame, so it cannot time the animation either. The engine's
own frame timings, from a profile build, are the instrument that worked.

## THE WHITE SCREEN WAS THE -v21 LAUNCH DRAWABLE

The launch window was white for the whole of the engine's startup - 4.6 seconds
of white in front of an obsidian curtain, and the owner saw it on every cold
launch.

The first fix changed `res/drawable/launch_background.xml` to the curtain's
colour. It changed nothing, because **Android picks the `-v21` variant of a
drawable on API 21 and above**, and the Fire TV is API 25. The drawable that
was actually on screen was `res/drawable-v21/launch_background.xml`, and it
used `?android:colorBackground` - which is **white** under the
`Theme.Light.NoTitleBar` parent that `LaunchTheme` inherits from.

Three resources were wrong, and all three are now the curtain's colour:

  * `res/drawable-v21/launch_background.xml` - the one the device uses;
  * `res/drawable/launch_background.xml` - the pre-21 variant;
  * `res/values/styles.xml`'s `NormalTheme` - the engine swaps this theme in
    as soon as it attaches, which is *before* the first Flutter frame, and it
    also said `?android:colorBackground`.

**Verified by pixel, not by assertion**: a `screencap` taken during a cold
launch now reads R=5 G=6 B=10 - which is `#05060a`, the canonical's curtain
colour - at three points across the frame. Before the fix the same capture
read 255/255/255.

## THE CHOPPY SEQUENCE: THE MEASUREMENT, AND WHY IT IS NOT FIXABLE IN THE APP

A profile build on the television, reporting the engine's own frame timings.
The sequence is three seconds long. It got **five frames**:

    t=0.000  build 18 us  raster 1,092,067 us
    t=1.435  build 8,300 us  raster 91,536 us
    t=1.585  build 92,279 us  raster 1,115,496 us
    t=2.703  build 10,461 us  raster 368,101 us

The **build** is never the problem - it is 14 microseconds on the first frame
and under 25 milliseconds on the rest. The **raster** is: 1.09 seconds for the
first frame, and 70-370 milliseconds afterwards. The build thread is idle; the
GPU is the bottleneck.

### What it is

The Fire TV's GPU is a **PowerVR Rogue GE8300** (2015) with OpenGL ES 3.2 and
**no Vulkan**. So:

  * **Impeller is not available.** Impeller compiles every pipeline into the
    engine at build time and removes shader compilation jank by design, but
    on Android it requires Vulkan. The engine prints a deprecation notice
    about the Impeller opt-out on this device; there is no opt-out in this
    client - the notice is the engine saying it fell back.
  * **Skia on OpenGL ES compiles at runtime**, the first time it sees a given
    combination of draw operations, and the compilation happens *inside the
    frame that needs it*. That is the 1.09-second first frame.

This is the same answer native Android apps get for free, which is why
Netflix, Prime and Hotstar are smooth: Android's HWUI has a persistent
on-device shader cache (`libs/hwui/pipeline/skia/ShaderCache.cpp`) and
precompiles its static shaders at build time, and their openings are usually
pre-rendered video, so nothing is compiled at all.

### Two things that were tried and did not work

**A shader warm-up.** Flutter's own remedy (`ShaderWarmUp`) was implemented:
ten draw operations covering every paint the sequence uses, executed at
startup. The measurement says it compiled (341 ms of it), and the first frame
still took 1.09 seconds. Skia's GL program cache is keyed per render target,
so programs compiled into a 100x100 offscreen image are **not** reused by the
screen. The warm-up was removed rather than shipped as a 371 ms startup tax
that buys nothing.

**Starting the sequence's clock at the first presented frame.** Implemented and
kept, but it is not the fix. The ticker's elapsed time is measured from its
first tick, and the engine does not begin a new frame until the previous one
has been rastered, so the second frame's tick carries the whole first frame's
second in one step: the sequence's position jumps from 0.000 to 1.435 and the
viewer never sees the first second and a half of it. That is the "rushed"
opening, and it is a *consequence* of the slow raster, not a separate bug.

### What it would take

To hit 60 fps on this device the sequence would need to be dramatically
cheaper than the canonical design, and the canonical design is the whole
point. The options are the owner's:

  * **D-D - a cheaper sequence on the television.** Fewer particles, no
    curtain mask (a full-screen `saveLayer` per frame), fewer full-screen
    gradient passes. It is a divergence from the canonical and it changes the
    picture.
  * **A pre-rendered video of the sequence for the television**, rendered from
    the canonical, so the picture is the canonical's and the GPU only decodes
    frames - which is precisely how Netflix and Prime get their smoothness.
  * **Accept it on this television** and hold the canonical to the web, which
    runs it at 60 fps, and to the phone.

## Also in this change

The sequence's clock now starts after the first frame has been built, and the
score starts with the controller's first tick rather than with the widget
tree. The score was previously audible for the two seconds the engine spent
starting up, before there was anything to see. That is the canonical's
"the score is anchored, not orphaned" rule applied to the Flutter client: the
sound and the picture now agree about where the sequence is.

The picture is unchanged: the intro's 47 tests pass, including the picture
oracle against the archived frames, with the same numbers (worst landscape
12.50, worst portrait 11.30).
