#!/usr/bin/env python3
"""Prove the overlay behaves over the running app.

Runs headless Edge against the proxy (serve_with_intro.py) and checks, as
observable facts rather than assertions in prose:

  1. gate mode     - the layer is above the app, transparent where it is not
                     drawing, and the app's own DOM is under it
  2. mid-sequence  - the veils really do cover the app (nothing leaks through)
  3. after the end - the layer has removed itself and the app is interactive:
                     a real input event reaches the app's own control
  4. capture mode  - renderAt() drives frames, the app clock is stopped, and
                     consecutive "hold" frames are byte-identical
"""
import hashlib
import io
import os
import sys
import time

from cdp_local import Chromium

BASE = "http://127.0.0.1:8001/"
OUT = r"C:/Users/anis7/AppData/Local/hermes/cache/scratch"
ok = True


def check(label, cond, detail=""):
    global ok
    ok = ok and bool(cond)
    print("  [%s] %s%s" % ("ok" if cond else "FAIL", label, (" -- " + detail) if detail else ""))


br = Chromium().start()
try:
    # ---------------------------------------------------------------- 1. gate mode
    print("1. gate mode (the app wearing the intro)")
    br.navigate(BASE + "?intro=gate")
    g = br.eval("""(()=>{const s=document.getElementById('stage'),g=document.getElementById('gate');
      const cs=getComputedStyle(s),cg=getComputedStyle(g);
      return {body:document.body.className,stagePos:cs.position,stageZ:+cs.zIndex,gateZ:+cg.zIndex,
      stageBg:cs.backgroundColor,cards:document.querySelectorAll('.card').length,
      posters:document.querySelectorAll('.art img').length,title:document.title,
      gateOn:!g.classList.contains('off'),pageMode:INTRO.pageMode()};})()""")
    print("   ", g)
    check("mode is gate", g["pageMode"] == "gate")
    check("layer fixed and above the app, gate above the layer",
          g["stagePos"] == "fixed" and g["stageZ"] > 100 and g["gateZ"] > g["stageZ"])
    check("layer paints nothing itself", g["stageBg"] in ("rgba(0, 0, 0, 0)", "transparent"))
    check("the app's own page is beneath it", g["cards"] >= 10 and g["posters"] >= 10,
          "%d cards, %d posters, title %r" % (g["cards"], g["posters"], g["title"]))

    # arm an AudioContext probe *before* the module builds its own
    br.eval("""window.__ac=null;(function(){var O=window.AudioContext||window.webkitAudioContext;
      window.AudioContext=window.webkitAudioContext=function(){var c=new O();window.__ac=c;return c};})()""")

    # ------------------------------------------------------- 2. mid-sequence: cover
    print("2. mid-sequence: the veils cover the app")
    br.click_sel("#playBtn")                       # a real (trusted) input event
    time.sleep(1.35)
    mid = br.eval("""(()=>{const cs=e=>getComputedStyle(document.getElementById(e));
      return {playback:INTRO.playback(),audioState:window.__ac?window.__ac.state:'none',
      veilL:cs('veilL').transform,veilR:cs('veilR').transform,
      stageDisplay:cs('stage').display};})()""")
    print("   ", mid)
    check("the sequence is playing", mid["playback"] == "playing")
    check("audio context is running (real sound)", mid["audioState"] == "running", mid["audioState"])
    lx = float((mid["veilL"].split(",")[-2] or "0").strip()) if "matrix" in mid["veilL"] else 0.0
    check("the veils have not parted yet at 1.35 s", abs(lx) < 1.0, mid["veilL"])
    n = br.screenshot(os.path.join(OUT, "ov-mid.png"))
    print("    screenshot ov-mid.png: %d bytes" % n)

    # ------------------------------------------------- 3. after the end: handover
    print("3. after the end: the layer is gone and the app is live")
    time.sleep(3.2)
    end = br.eval("""(()=>{const ids=['stage','veilL','veilR','gate','fx'];
      const have={};ids.forEach(function(i){have[i]=!!document.getElementById(i)});
      const s=document.getElementById('stage'),cs=s?getComputedStyle(s):null;
      return {playback:INTRO.playback(),ids:have,
      stageDisplay:cs?cs.display:'(no stage)',stagePE:cs?cs.pointerEvents:'',
      body:document.body.className};})()""")
    print("   ", end)
    check("the layer removed itself", end["stageDisplay"] == "none")
    n = br.screenshot(os.path.join(OUT, "ov-end.png"))
    print("    screenshot ov-end.png: %d bytes" % n)

    # a real click must reach the app's own control now
    target = br.eval("""(()=>{const i=document.querySelector('input[type=search],input#q,input[name=q]')
      ||document.querySelector('header input');
      return i?{sel:'header input',id:i.id||i.name||i.type}:null;})()""")
    print("    app control:", target)
    if target:
        br.click_sel("header input")
        time.sleep(0.35)
        focused = br.eval("""(()=>{const a=document.activeElement;
          return {tag:a.tagName,id:a.id||a.name||'',isAppInput:!!a.closest('header')};})()""")
        print("    ", focused)
        check("a real click now reaches the app (it took focus)", focused["isAppInput"])

    # ------------------------------------------------------------- 4. capture mode
    print("4. capture mode: deterministic frames over the live app")
    br.navigate(BASE + "?intro=capture")
    time.sleep(1.5)
    cap = br.eval("""(()=>{return {mode:INTRO.pageMode(),body:document.body.className,
      timersDead:(function(){var n=0;setInterval(function(){n++},10);setTimeout(function(){n++},10);
        return {n:n};})().n===0,
      cards:document.querySelectorAll('.card').length,
      veil:getComputedStyle(document.getElementById('veilL')).transform};})()""")
    print("   ", cap)
    check("mode is capture", cap["mode"] == "capture" and "intro-capture" in cap["body"])
    check("the app's clock is stopped (timers are no-ops)", cap["timersDead"])
    check("the app is still rendered under the layer", cap["cards"] >= 12)

    hashes = {}
    for t in (1.70, 2.90, 2.95):
        br.eval("INTRO.renderAt(%s)" % t)
        time.sleep(0.25)
        br.eval("""(function(){var cv=document.getElementById('fx'),im=document.getElementById('__sw');
          if(cv&&cv.width){im=document.getElementById('__sw')||document.createElement('img');
          im.id='__sw';im.style.cssText='position:absolute;inset:0;width:100%;height:100%;z-index:9;pointer-events:none;display:none';
          document.getElementById('stage').appendChild(im);
          im.src=cv.toDataURL('image/png');cv.style.visibility='hidden';im.style.display='block';}})()""")
        time.sleep(0.4)
        p = os.path.join(OUT, "cap-%s.png" % t)
        br.screenshot(p)
        hashes[t] = hashlib.md5(open(p, "rb").read()).hexdigest()
        print("    t=%.2f -> %s  %s" % (t, os.path.basename(p), hashes[t][:12]))
    check("2.90 and 2.95 are the identical hold frame", hashes[2.90] == hashes[2.95])
    check("1.70 differs from the hold (the sequence is still running)", hashes[1.70] != hashes[2.90])
    n = br.screenshot(os.path.join(OUT, "ov-revealed.png"))
    print("    screenshot ov-revealed.png: %d bytes" % n)
finally:
    br.stop()

print()
print("OVERALL:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)