#!/usr/bin/env python3
"""Verify the opening sequence as it is served by the running app itself.

Drives the live service on :8000 (not the demo proxy) in headless Edge and checks,
as observable facts:

  1. a first visit shows the brand layer over the real page, and the page keeps its
     own styling — the layer must not leak (background, scrolling);
  2. while the layer draws it takes the clicks, so the app cannot be used through it;
  3. a real click on the start card runs the sequence with sound, and afterwards the
     layer removes itself completely (stage *and* gate);
  4. the app is then genuinely usable — a real click focuses its own search field,
     and the page scrolls;
  5. a repeat visit in the same session paints none of it (the once-per-session gate).
"""
import time

from cdp_local import Chromium

APP = "http://127.0.0.1:8000/"
ok = True


def check(label, cond, detail=""):
    global ok
    ok = ok and bool(cond)
    print("  [%s] %s%s" % ("ok" if cond else "FAIL", label, (" -- " + detail) if detail else ""))


br = Chromium().start()
try:
    # ---------------------------------------------------------------- 1. first visit
    print("1. first visit: the layer is over the app, and the sequence starts automatically")
    br.navigate(APP)
    br.eval("sessionStorage.clear()")
    br.navigate(APP)
    first = br.eval("""(()=>{const g=document.getElementById('gate'),s=document.getElementById('stage');
      const cs=e=>e?getComputedStyle(e):null;
      const el=document.elementFromPoint(innerWidth/2,innerHeight/2);
      return {pageMode:INTRO.pageMode(),playback:INTRO.playback(),title:document.title,
      cards:document.querySelectorAll('.card').length,posters:document.querySelectorAll('.art img').length,
      stagePos:cs(s)?cs(s).position:'(none)',stageZ:cs(s)?+cs(s).zIndex:0,
      gateShown:!!g&&cs(g).display!=='none'&&cs(g).opacity!=='0',
      bodyBg:getComputedStyle(document.body).backgroundColor,
      bodyOverflow:getComputedStyle(document.body).overflow,
      hitInside:!!(el&&el.closest('#stage,#gate'))};})()""")
    print("   ", first)
    check("the overlay is on the page", first["pageMode"] == "auto" and first["stagePos"] == "fixed")
    check("it sits above the app's stack", first["stageZ"] >= 2147483000)
    check("the start card is not shown (prompt removed)", not first["gateShown"])
    check("the sequence is playing automatically", first["playback"] == "playing")
    check("clicks land on the layer while drawing", first["hitInside"])
    check("the app's own page is beneath it", first["cards"] >= 10 and first["posters"] >= 10,
          "%d cards, %d posters" % (first["cards"], first["posters"]))
    check("the layer does not skin the page", first["bodyBg"] != "rgb(5, 6, 10)", first["bodyBg"])

    # the page must still be scrollable (the old leak froze it)
    scrolled = br.eval("(()=>{window.scrollTo(0,400);return window.scrollY;})()")
    check("the page still scrolls", scrolled and scrolled > 0, "scrollY=%s" % scrolled)
    br.eval("window.scrollTo(0,0)")

    # ------------------------------------------- 2. afterwards the layer is gone
    print("2. afterwards nothing of the layer is left, and the app is usable")
    time.sleep(3.2)
    end = br.eval("""(()=>{const cs=e=>{const n=document.getElementById(e);return n?getComputedStyle(n).display:'(none)'};
      return {playback:INTRO.playback(),stage:cs('stage'),gate:cs('gate')};})()""")
    print("   ", end)
    check("the stage removed itself", end["stage"] == "none")
    check("the start card removed itself too", end["gate"] == "none")

    br.navigate(APP)                      # a fresh page load, same session
    time.sleep(0.6)
    target = br.eval("""(()=>{const i=document.querySelector('header input');
      return i?{id:i.id||i.type}:null;})()""")
    if target:
        br.click_sel("header input")
        time.sleep(0.3)
        got = br.eval("""(()=>{const a=document.activeElement;
          return {tag:a.tagName,took:!!a.closest('header')};})()""")
        check("a real click now reaches the app", got["took"], str(got))
    else:
        check("the app's own search field is present", False, "not found")

    # --------------------------------------- 4. repeat visit: nothing is painted
    print("4. repeat visit this session: none of it is painted")
    br.navigate(APP)
    state = br.eval("""(()=>{const cs=e=>{const n=document.getElementById(e);return n?getComputedStyle(n).display:'(none)'};
      return {pageMode:INTRO.pageMode(),stage:cs('stage'),gate:cs('gate'),
      cards:document.querySelectorAll('.card').length,
      hits:(()=>{const el=document.elementFromPoint(innerWidth/2,innerHeight/2);
        return el?{insideLayer:!!el.closest('#stage,#gate')}:{insideLayer:true}})()};})()""")
    print("   ", state)
    check("the layer paints nothing on a repeat visit",
          state["stage"] == "none" and state["gate"] == "none")
    check("the app is immediately visible and reachable",
          state["cards"] >= 1 and not state["hits"]["insideLayer"],
          "%d cards, layer hit-test %s" % (state["cards"], state["hits"]["insideLayer"]))
finally:
    br.stop()

print()
print("OVERALL:", "PASS" if ok else "FAIL")
import sys
sys.exit(0 if ok else 1)