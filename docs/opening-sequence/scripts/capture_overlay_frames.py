#!/usr/bin/env python3
"""Capture the intro-over-live-app sequence, frame by frame, in both orientations.

What is captured is the real thing: the app served by serve_with_intro.py with
the overlay injected over it, at ?intro=capture (the proxy stops the app's clock
so frames are reproducible). The layout viewport is set with CDP device metrics,
so the app lays out at exactly the captured size -- desktop for landscape, a
phone viewport for portrait -- and what the curtain opens onto in the video is
the app's own layout, not a scaled screenshot of it.

    python capture_overlay_frames.py landscape     # 1920x1080, desktop layout
    python capture_overlay_frames.py portrait      # 1080x1920, phone layout

Resumable: frames already on disk are skipped, so a crash costs nothing.
"""
import os
import sys
import time

from cdp_local import Chromium

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = "http://127.0.0.1:8001/?intro=capture"
FPS = 30
NFRAMES = 90

# name -> (layout width, layout height, device scale, mobile, out dir)
STYLES = {
    "landscape": (1920, 1080, 1, False, "frames"),
    "portrait": (540, 960, 2, True, "frames-portrait"),
}

SWAP = """(function(){
  var cv=document.getElementById('fx'); if(!cv||!cv.width) return 'no-canvas';
  var im=document.getElementById('__sw');
  if(!im){im=document.createElement('img');im.id='__sw';
    im.style.cssText='position:absolute;left:0;top:0;width:100%;height:100%;z-index:9;pointer-events:none';
    cv.parentNode.insertBefore(im,cv);}
  /* the screenshot path only repaints when the DOM is damaged: canvas-only
     motion is invisible to it, so the canvas is handed over as an image */
  im.src=cv.toDataURL('image/png');
  cv.style.visibility='hidden';
  return 'swapped';
})()"""


def main():
    style = sys.argv[1] if len(sys.argv) > 1 else "landscape"
    if style not in STYLES:
        sys.exit("style must be one of: %s" % ", ".join(STYLES))
    w, h, dpr, mobile, folder = STYLES[style]
    out = os.path.join(HERE, folder)
    os.makedirs(out, exist_ok=True)
    have = set(os.listdir(out))
    todo = [i for i in range(NFRAMES) if "f_%04d.png" % i not in have]
    print("%s: %dx%d layout at DPR %d -> %dx%d pixels, %d/%d frames to do"
          % (style, w, h, dpr, w * dpr, h * dpr, len(todo), NFRAMES))
    if not todo:
        return

    br = Chromium().start()
    try:
        br.metrics(w, h, dpr=dpr, mobile=mobile)
        br.navigate(BASE)
        time.sleep(2.0)                       # the app's own first paint
        real = br.eval("[innerWidth, innerHeight, devicePixelRatio, "
                       "document.querySelectorAll('.card').length]")
        print("  viewport %s, cards %s" % (real[:3], real[3]))
        if real[0] != w or real[1] != h:
            sys.exit("layout viewport is %sx%s, wanted %dx%d" % (real[0], real[1], w, h))
        mode = br.eval("INTRO.pageMode()")
        if mode != "capture":
            sys.exit("page is in mode %r, not capture" % mode)

        t_start = time.time()
        for n, i in enumerate(todo, 1):
            br.eval("INTRO.renderAt(%.6f)" % (i / FPS))
            br.eval(SWAP)
            br.screenshot(os.path.join(out, "f_%04d.png" % i),
                          clip={"x": 0, "y": 0, "w": w, "h": h}, scale=dpr)
            if n % 10 == 0 or n == len(todo):
                el = time.time() - t_start
                print("  %3d/%d  t=%.3fs  (%.1fs elapsed, %.2fs/frame)"
                      % (n, len(todo), i / FPS, el, el / n), flush=True)
    finally:
        br.stop()

    # honesty check: report runs of byte-identical frames, so a stalled
    # screenshot path cannot pass silently (the two intended holds are t<0.12
    # and t>2.75, where nothing moves anyway)
    import hashlib
    seen, runs, run = {}, [], []
    for i in range(NFRAMES):
        p = os.path.join(out, "f_%04d.png" % i)
        d = hashlib.md5(open(p, "rb").read()).hexdigest()
        if run and seen.get(run[-1]) == d:
            run.append(i)
        else:
            if len(run) > 1:
                runs.append(run)
            run = [i]
        seen[i] = d
    if len(run) > 1:
        runs.append(run)
    print("  identical-frame runs:", [(r[0] / FPS, r[-1] / FPS) for r in runs] or "none")


if __name__ == "__main__":
    main()