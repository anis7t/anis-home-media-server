#!/usr/bin/env python3
"""Convert intro.html from "standalone page with a library snapshot" into
"overlay layer injected over the running app".

One-shot, deterministic, and asserted: every edit must match exactly once or the
script exits without writing. Kept in the folder as the record of the change.

    python convert_to_overlay.py intro.html intro-overlay.html
"""
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "intro.html"
DST = sys.argv[2] if len(sys.argv) > 2 else "intro-overlay.html"

text = open(SRC, encoding="utf-8").read()
done = []


def sub(name, old, new, count=1):
    global text
    got = text.count(old)
    if got != count:
        sys.exit("EDIT %s: expected %d occurrence(s), found %d -- nothing written" % (name, count, got))
    text = text.replace(old, new, count)
    done.append(name + " (%d)" % count)


# --------------------------------------------------------------- 1. markup: out with the library layer
sub("markup/library-layer", """<div id="stage">
  <!-- what the curtain opens onto: the real library page, in an inert iframe
       (loaded live from the app's origin when served, else the snapshot) -->
  <div id="library" aria-hidden="true">
    <div id="libFallback">Library layer unavailable<br>
      <span style="letter-spacing:.02em;text-transform:none;font-weight:600">serve this folder over http:// so the curtain can open onto the real library</span></div>
    <iframe id="libFrame" title="Library" sandbox="" style="display:none"></iframe>
  </div>

  <!-- the curtain: two halves of one backdrop -->""",
"""<!-- ============================================================== the overlay
     Not a page of its own: an overlay layer injected over the running app by
     serve_with_intro.py. The curtain parts onto the app itself -- already
     loaded, already interactive -- and this layer removes itself once it has. -->
<div id="stage">
  <!-- the curtain: two halves of one backdrop -->""")

# ---------------------------------------------------------------- 2. css: overlay stack above the app
sub("css/overlay-mode", """</style>
</head>
<body>""",
"""/* ============================== overlay mode (injected over the running app)
   The layer sits at the very top of the app's stack and is transparent wherever
   it is not drawing: what shows through the parted curtain is the app itself,
   live. body.intro-mode outranks the standalone capture box below, which is
   left inert; body.intro-capture is the still-page mode used for frame capture
   (the proxy also stops the app's clock there, so frames are reproducible). */
body.intro-mode #stage{position:fixed!important;inset:0!important;left:0!important;top:0!important;
  width:auto!important;height:auto!important;margin:0!important;border:0!important;
  border-radius:0!important;background:transparent!important;z-index:2147483000!important}
body.intro-mode #gate{position:fixed!important;inset:0!important;z-index:2147483001!important}
body.intro-mode #hud{display:none!important}
/* the app is clickable again the instant it is fully visible */
body.intro-mode #stage.handover{pointer-events:none!important}
body.intro-capture,body.intro-capture *{animation:none!important;transition:none!important}
body.intro-capture #stage{pointer-events:none!important}
</style>
</head>
<body>""")

# ------------------------------------------------------- 3. js: drop the loader
sub("js/loader", """/* ======================================= 3. the library layer (the reveal)
   The curtain opens onto the REAL library page -- nothing about it is faked.
   Served by the app, it is fetched live from the same origin, so the reveal
   always shows whatever the library holds at that moment; opened from disk it
   comes from library-snapshot.html, a real script-free copy of the page.
   Either way the markup is script-stripped before it enters the sandboxed
   iframe, so the library cannot poll, animate, or reach this document. */
function loadLibrary(){
  var f=el.libFrame,fb=el.libFallback;
  function strip(h){
    /* scripts out, and motion frozen: the library layer is a still copy, so
       nothing inside it may animate while the curtain reveals it (the real
       page underneath the overlay is untouched and stays live) */
    return h.replace(/<script\\b[\\s\\S]*?<\\/script>/gi,'').replace(/<script\\b[^>]*\\/>/gi,'')
      + '<style>*,*::before,*::after{animation:none!important;transition:none!important}</style>';
  }
  function use(h){
    /* the app's page is a fragment -- no <html>/<body> tags, the parser infers
       them -- so validate by shape: a style block plus the header */
    if(!h||h.length<200||!/<style/i.test(h)||!/<header/i.test(h))return false;
    f.srcdoc=strip(h);f.style.display='block';
    if(fb)fb.style.display='none';
    return true;
  }
  /* a file:// document cannot fetch a sibling file, but it can frame one --
     and only there: a data: URL cannot resolve a relative frame either, and
     Chrome fires `load` on its error page, which would reveal a blank box */
  function fromFile(){
    if(location.protocol!=='file:')return;
    f.onload=function(){f.style.display='block';if(fb)fb.style.display='none'};
    f.src='library-snapshot.html';
  }
  function fromSnapshot(){
    return fetch('library-snapshot.html',{cache:'no-store'})
      .then(function(r){return r.ok?r.text():''})
      .then(function(h){if(!use(h))fromFile()})
      .catch(fromFile);
  }
  /* an inlined snapshot (capture harness) wins outright: a data: URL has no
     origin, and its fetch() throws before a promise even exists */
  if(window.__LIB_SNAPSHOT__&&use(window.__LIB_SNAPSHOT__))return;
  try{
    fetch('/',{cache:'no-store'})
      .then(function(r){return r.ok?r.text():''})
      .then(function(h){if(!use(h))fromSnapshot()})
      .catch(fromSnapshot);
  }catch(e){fromSnapshot()}
}

""",
"""/* ======================================= 3. the reveal is the app itself ===
   There is nothing to load: this layer is injected over the running app, so the
   curtain parts onto the real page with its own scripts already run and its own
   request handlers already live. See serve_with_intro.py. */

""")

# --------------------------------------------------------- 4. js: drop library refs
sub("js/el-refs", """  library:document.getElementById('library'),libFrame:document.getElementById('libFrame'),
  libFallback:document.getElementById('libFallback'),
""", "")

# --------------------------------------------------- 5. js: the driver's library line
sub("js/driver-library-line", """  /* the real library eases in behind the parting halves */
  st(el.library,'transform','scale('+lerp(1.055,1,eOutCubic(pk)).toFixed(5)+')');
""",
"""  /* what eases in behind the parting halves is the app itself: already there,
     nothing to animate -- the veils simply stop covering it */
""")

# --------------------------------------------------------------- 6. js: drop the call
sub("js/load-call", "loadLibrary();", "/* nothing to load: the app is already beneath this layer */")

# ------------------------------------------------------------------ 7. js: the hud flag
sub("js/hud-flag", "el.hud.classList.toggle('show',mode!=='gate');",
    "el.hud.classList.toggle('show',SHOW_HUD&&mode!=='gate');")

# --------------------------------------------------- 8. js: handover + finish in the loop
sub("js/loop", """  if(mode==='playing'&&t>=DURATION){mode='done';updateHud()}
  if(t>3.35){window.cancelAnimationFrame(raf);raf=0}""",
"""  if(mode==='playing'){
    /* once everything of this layer is off-screen -- veils, dressing, lockup --
       the app underneath is the only thing left, so let it be touched */
    if(t>=T.curtain+0.62)root.classList.add('handover');
    if(t>=DURATION){mode='done';updateHud();finish()}
  }
  if(t>3.35){window.cancelAnimationFrame(raf);raf=0}""")

# ------------------------------------------------------------- 9. js: the mode block
sub("js/mode-block", """/* ================================================== 9. capture / debug API */""",
"""/* ============================================ 8b. how this layer is being used
   Injected over the running app, this layer owns the viewport until the outro
   is finished -- it must not let the app be touched while it is still drawing,
   must hand the app back the moment it is visible, and must then clear out so
   nothing of it is left in the page.  Modes come from the query string:
     gate     (default) the click-to-start card, so the theme plays with sound
     auto     straight in, silent until the page is first touched
     capture  still page: the capture harness drives renderAt() itself
   ========================================================================= */
var root=el.stage;
var qs='gate';
var qm=location.search.match(/[?&]intro=([a-z]+)/);
if(qm)qs=qm[1];
if(qs!=='gate'&&qs!=='auto'&&qs!=='capture')qs='gate';
document.body.classList.add('intro-mode');
var CAPTURE=(qs==='capture');
if(CAPTURE)document.body.classList.add('intro-capture');
/* the layer is the real thing now, so the demo HUD (skip/replay/mute chrome)
   stays out of the way; click or space still skip while it is playing */
var SHOW_HUD=false;
var finished=false;
function finish(){
  if(finished)return;finished=true;
  st(root,'display','none');          /* the app has the viewport back */
  root.classList.remove('handover');
  document.body.classList.remove('intro-capture');
  if(Audio.suspend){try{Audio.suspend()}catch(e){}}
}

/* ================================================== 9. capture / debug API */""")

# ------------------------------------------------------------------ 10. js: the api
sub("js/api", """  audio:Audio,reduced:REDUCED,reloadLibrary:loadLibrary,
  version:'1.1.0'""",
"""  audio:Audio,reduced:REDUCED,finish:finish,mode:function(){return qs},
  version:'1.2.0'""")

# ------------------------------------------------------------------- 11. js: autostart
sub("js/autostart", """/* paint the first frame so nothing flashes before playback starts */
renderAt(0);
updateHud();""",
"""/* paint the first frame so nothing flashes before playback starts */
renderAt(0);
updateHud();
/* gate is the default because browsers refuse to start audio without a gesture */
if(qs==='auto')play();""")

# --------------------------------------- 12. css: the gate is not in captured frames
sub("css/capture-no-gate", """body.intro-capture #stage{pointer-events:none!important}""",
"""body.intro-capture #stage{pointer-events:none!important}
/* the gate is not part of the sequence: a captured frame is the intro over the
   app, never the click-to-start card */
body.intro-capture #gate,body.intro-capture #hud{display:none!important}""")

# -------------------------------- 13. css: drop the now-dead library-layer rules
sub("css/dead-library-rules", """  /* ===================== the library underneath =====================
     The curtain opens onto the REAL library page. It is loaded live from the
     same origin when the intro is served by the app, and from
     library-snapshot.html (a real, script-free copy of the page) otherwise.
     It renders inside an iframe so the app's own CSS cannot reach this document. */
  #library{position:absolute;inset:0;z-index:1;overflow:hidden;background:#090b10}
  #libFrame{position:absolute;left:0;top:0;width:100%;height:100%;border:0;
    transform-origin:50% 50%;will-change:transform;background:#090b10}
  #libFallback{position:absolute;inset:0;display:grid;place-items:center;text-align:center;
    background:radial-gradient(ellipse 70% 58% at 50% 44%,rgba(229,9,20,.10) 0%,transparent 70%),#090b10;
    color:#5d6b80;font-size:12px;font-weight:700;letter-spacing:.16em;text-transform:uppercase;line-height:2.1}

""", "")

# --------------------------- 14. js: replay must put the layer back on screen
sub("js/replay-after-finish", """function replay(){
  mode='gate';
  Audio.stop(0.05);
  Audio.play();""",
"""function replay(){
  mode='gate';
  /* a finished outro has cleared this layer away; put it back before playing */
  if(typeof root!=='undefined'&&root&&finished){
    st(root,'display','block');finished=false;
    document.body.classList.remove('intro-capture');
  }
  Audio.stop(0.05);
  Audio.play();""")

# ------------------------------------------- 15. js: name the two modes clearly
sub("js/api-modes", """  audio:Audio,reduced:REDUCED,finish:finish,mode:function(){return qs},
  version:'1.2.0'""",
"""  audio:Audio,reduced:REDUCED,finish:finish,
  pageMode:function(){return qs},playback:function(){return mode},
  version:'1.2.0'""")

# --------------------- 16. css: scope the layer's skin to the layer, not the page
sub("css/scope-base", """  /* ===================== base ===================== */
  *,*::before,*::after{box-sizing:border-box}
  html,body{margin:0;padding:0;height:100%}
  body{
    background:#05060a;color:#f7f7f8;
    font:16px/1.4 system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    overflow:hidden;user-select:none;-webkit-user-select:none;
    -webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility;
  }
  button{font:inherit;cursor:pointer}""",
"""  /* ===================== base (scoped to this layer) =====================
     This fragment is injected OVER a real page, so nothing in it may style the
     document: `html,body` rules that are harmless standalone override the
     host's own (measured on the real page: its body background was replaced and
     its scrolling stopped). Everything is scoped to the two top-level layers. */
  #stage *,#stage *::before,#stage *::after,
  #gate *,#gate *::before,#gate *::after{box-sizing:border-box}
  #stage,#gate{
    color:#f7f7f8;
    font:16px/1.4 system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    user-select:none;-webkit-user-select:none;
    -webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility;
  }
  #stage button,#gate button{font:inherit;cursor:pointer}""")

# ------------------ 17. js: finish() means the whole layer is gone, gate included
sub("js/finish-hides-gate", """function finish(){
  if(finished)return;finished=true;
  st(root,'display','none');          /* the app has the viewport back */""",
"""function finish(){
  if(finished)return;finished=true;
  st(root,'display','none');          /* the app has the viewport back */
  if(el.gate)st(el.gate,'display','none');  /* and the start card goes with it */""")

open(DST, "w", encoding="utf-8", newline="").write(text)
print("wrote %s (%d bytes)" % (DST, len(text.encode("utf-8"))))
for d in done:
    print("  ok  " + d)