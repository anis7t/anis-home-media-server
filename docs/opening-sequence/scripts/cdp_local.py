#!/usr/bin/env python3
"""Drive a local headless Chromium (Edge/Chrome) over CDP.

Local, same-origin HTTP, real input events, screenshots with any clip/scale.
Replaces the cloud browser for this project: no data: URLs, no session drops,
and the page under test is the real app served by serve_with_intro.py.

    from cdp_local import Chromium
    br = Chromium().start()
    br.navigate("http://127.0.0.1:8001/?intro=capture")
    print(br.eval("[innerWidth, innerHeight, devicePixelRatio]"))
    br.screenshot("f.png", clip=br.rect("#stage"), scale=1.0)
    br.stop()
"""
import base64
import json
import os
import shutil
import subprocess
import time
import urllib.request

from websockets.sync.client import connect

EDGE_PATHS = [
    r"C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
    r"C:/Program Files/Microsoft/Edge/Application/msedge.exe",
    r"C:/Program Files/Google/Chrome/Application/chrome.exe",
    r"C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
]
SCRATCH = r"C:/Users/anis7/AppData/Local/hermes/cache/scratch"


def find_browser():
    for p in EDGE_PATHS:
        if os.path.exists(p):
            return p
    raise SystemExit("no Edge/Chrome found in %s" % EDGE_PATHS)


class Chromium:
    def __init__(self, port=9333, profile=None, window=(1920, 1080), dpr=1, verbose=False):
        self.port = port
        self.profile = profile or os.path.join(SCRATCH, "edge-profile-%d" % port)
        self.window = window
        self.dpr = dpr
        self.verbose = verbose
        self.proc = None
        self.ws = None
        self.session = None
        self._id = 0

    # ---------------------------------------------------------------- lifecycle
    def start(self):
        exe = find_browser()
        self.proc = subprocess.Popen(
            [exe, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
             "--disable-extensions", "--disable-background-networking", "--mute-audio",
             "--remote-allow-origins=*", "--remote-debugging-port=%d" % self.port,
             "--user-data-dir=%s" % self.profile,
             "--window-size=%d,%d" % self.window,
             "--force-device-scale-factor=%s" % self.dpr,
             "about:blank"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        url = None
        for _ in range(120):
            try:
                with urllib.request.urlopen("http://127.0.0.1:%d/json/version" % self.port, timeout=1) as r:
                    url = json.load(r)["webSocketDebuggerUrl"]
                break
            except Exception:                                           # noqa: BLE001
                time.sleep(0.25)
        if not url:
            raise RuntimeError("browser did not expose CDP on port %d" % self.port)
        self.ws = connect(url, max_size=200 * 1024 * 1024, open_timeout=30)
        return self

    def stop(self):
        try:
            if self.ws:
                self.ws.close()
        except Exception:                                               # noqa: BLE001
            pass
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except Exception:                                           # noqa: BLE001
                self.proc.kill()
        shutil.rmtree(self.profile, ignore_errors=True)

    # -------------------------------------------------------------------- cdp
    def send(self, method, _timeout=120, **params):
        self._id += 1
        msg = {"id": self._id, "method": method, "params": params}
        if self.session and not method.startswith("Target."):
            msg["sessionId"] = self.session
        self.ws.send(json.dumps(msg))
        deadline = time.time() + _timeout
        while time.time() < deadline:
            raw = self.ws.recv(timeout=max(1, deadline - time.time()))
            m = json.loads(raw)
            if m.get("id") == self._id:
                if "error" in m:
                    raise RuntimeError("%s -> %s" % (method, m["error"]))
                return m.get("result", {})
            if self.verbose:
                print("   ·", m.get("method"), m.get("params", {}))
        raise TimeoutError(method)

    # ------------------------------------------------------------------- page
    def navigate(self, url, wait=True, timeout=60):
        if not self.session:
            t = self.send("Target.createTarget", url="about:blank")["targetId"]
            self.session = self.send("Target.attachToTarget", targetId=t, flatten=True)["sessionId"]
            self.send("Page.enable")
            self.send("Runtime.enable")
        self.send("Page.navigate", url=url)
        if not wait:
            return self
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.eval("document.readyState") in ("interactive", "complete"):
                return self
            time.sleep(0.15)
        raise TimeoutError("page never became interactive: %s" % url)

    def eval(self, expr, await_promise=False):
        r = self.send("Runtime.evaluate", expression=expr, returnByValue=True,
                      awaitPromise=await_promise)
        res = r.get("result", {})
        if r.get("exceptionDetails"):
            ed = r["exceptionDetails"]
            msg = (ed.get("exception") or {}).get("description") or ed.get("text") or "eval failed"
            raise RuntimeError("eval failed: %s" % msg.split("\n")[0])
        return res.get("value")

    def rect(self, selector):
        return self.eval("(()=>{const e=document.querySelector(%s);if(!e)return null;"
                         "const r=e.getBoundingClientRect();"
                         "return {x:r.left,y:r.top,w:r.width,h:r.height};})()" % json.dumps(selector))

    def metrics(self, width, height, dpr=1, mobile=False):
        if not self.session:                 # Emulation is a page-domain method
            self.navigate("about:blank")
        self.send("Emulation.setDeviceMetricsOverride", width=width, height=height,
                  deviceScaleFactor=dpr, mobile=mobile)

    def screenshot(self, path, clip=None, scale=None, beyond=False, _timeout=180):
        params = {"format": "png"}
        if clip:
            params["clip"] = {"x": clip["x"], "y": clip["y"], "width": clip["w"], "height": clip["h"],
                              "scale": scale if scale is not None else 1}
        params["captureBeyondViewport"] = bool(beyond)
        r = self.send("Page.captureScreenshot", _timeout=_timeout, **params)
        raw = base64.b64decode(r["data"])
        with open(path, "wb") as fh:
            fh.write(raw)
        return len(raw)

    def click(self, x, y):
        """A trusted (real input) click - needed for audio/autoplay tests."""
        for t in ("mousePressed", "mouseReleased"):
            self.send("Input.dispatchMouseEvent", type=t, x=x, y=y, button="left",
                      clickCount=1, buttons=1 if t == "mousePressed" else 0)

    def click_sel(self, selector):
        r = self.rect(selector)
        if not r:
            raise RuntimeError("no element for %s" % selector)
        self.click(r["x"] + r["w"] / 2, r["y"] + r["h"] / 2)


if __name__ == "__main__":
    br = Chromium().start()
    try:
        br.navigate("http://127.0.0.1:8001/?intro=off")
        print("viewport:", br.eval("[innerWidth, innerHeight, devicePixelRatio]"))
        print("cards:", br.eval("document.querySelectorAll('.card').length"))
        n = br.screenshot(os.path.join(SCRATCH, "cdp-smoke.png"))
        print("screenshot bytes:", n)
    finally:
        br.stop()