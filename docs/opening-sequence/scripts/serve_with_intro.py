#!/usr/bin/env python3
"""Serve the running media server with the intro overlay injected over it.

The overlay *reveals the app itself* rather than a copy of it: this proxy forwards
every request to the live app and appends the overlay to HTML responses, so the
curtain opens onto the real, already-loaded, interactive page. Nothing is written
into the app repo or the app's own files.

    python serve_with_intro.py                     # http://127.0.0.1:8001/
    python serve_with_intro.py --port 8080 --app http://127.0.0.1:8000

Modes (query string on any HTML request):
    (none)          the app wearing the intro
    ?intro=off      the app untouched - use it to sanity-check the app itself
    ?intro=capture  the app with its clock stopped, for frame-accurate capture

The capture mode is the only mode-specific injection: a script is placed before
any page script runs that replaces setInterval/setTimeout/rAF with no-ops, so the
app renders from its server-side HTML and then holds perfectly still while frames
are captured. The page is server-rendered, so nothing is missing without timers.
"""
import argparse
import http.server
import os
import re
import socketserver
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OVERLAY = os.path.join(HERE, "intro-overlay.html")

FREEZE = """<script>
/* capture mode: stop the app's clock so captured frames are reproducible.
   Installed before any page script, so the app never schedules periodic work.
   The overlay drives itself from renderAt(), which needs no timers. */
(function(){try{var n=function(){return 0};
window.setInterval=n;window.setTimeout=n;window.requestAnimationFrame=n;
window.webkitRequestAnimationFrame=n;window.mozRequestAnimationFrame=n;}catch(e){}})();
</script>"""

HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
              "te", "trailers", "transfer-encoding", "upgrade", "content-length",
              "content-encoding"}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "intro-proxy"

    def log_message(self, fmt, *args):                                  # noqa: A003
        if os.environ.get("INTRO_PROXY_VERBOSE"):
            sys.stderr.write("  %s\n" % (fmt % args))

    # ---------------------------------------------------------------- proxying
    def _forward(self, method):
        target = self.server.app + self.path
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None

        req = urllib.request.Request(target, data=body, method=method)
        for k, v in self.headers.items():
            if k.lower() in HOP_BY_HOP or k.lower() in ("host", "accept-encoding"):
                continue
            req.add_header(k, v)
        # upstream must not compress: the body is rewritten and re-measured
        req.add_header("Accept-Encoding", "identity")

        try:
            with urllib.request.urlopen(req, timeout=60) as up:
                status, headers, payload = up.status, list(up.headers.items()), up.read()
        except urllib.error.HTTPError as e:
            status, headers, payload = e.code, list(e.headers.items()), e.read()
        except Exception as e:                                          # noqa: BLE001
            self.send_error(502, "upstream failed: %s" % e)
            return

        ctype = ""
        for k, v in headers:
            if k.lower() == "content-type":
                ctype = v.lower()
        if "text/html" in ctype and payload:
            payload = self._inject(payload)

        self.send_response(status)
        for k, v in headers:
            if k.lower() in HOP_BY_HOP or k.lower() == "accept-ch":
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if method != "HEAD":
            self.wfile.write(payload)

    def do_GET(self):                                                   # noqa: N802
        self._forward("GET")

    def do_HEAD(self):                                                  # noqa: N802
        self._forward("HEAD")

    def do_POST(self):                                                  # noqa: N802
        self._forward("POST")

    # -------------------------------------------------------------- injection
    def _inject(self, payload):
        html = payload.decode("utf-8", "replace")
        mode = "on"
        m = re.search(r"[?&]intro=([a-z]+)", self.path)
        if m:
            mode = m.group(1)
        if mode == "off":
            return payload
        with open(OVERLAY, encoding="utf-8") as fh:
            overlay = fh.read()
        overlay = overlay.replace("__INTRO_MODE__", mode)

        if mode == "capture":
            # before any page script, stop the clock
            if re.match(r"\s*<!doctype", html, re.I):
                html = re.sub(r"(?i)^(\s*<!doctype[^>]*>)", r"\1" + FREEZE, html, count=1)
            else:
                html = FREEZE + html
        # the overlay goes last: the app's own scripts have already run, so the
        # curtain opens onto a fully initialised, interactive page
        html += "\n<!-- intro overlay (injected by serve_with_intro.py, not part of the app) -->\n" + overlay
        return html.encode("utf-8")


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8001)
    ap.add_argument("--app", default="http://127.0.0.1:8000")
    ap.add_argument("--host", default="127.0.0.1")
    args = ap.parse_args()

    if not os.path.exists(OVERLAY):
        sys.exit("missing overlay fragment: %s" % OVERLAY)

    srv = Server((args.host, args.port), Handler)
    srv.app = args.app.rstrip("/")
    print("intro proxy  http://%s:%d/  ->  %s" % (args.host, args.port, srv.app))
    print("  overlay: %s (%d bytes)" % (OVERLAY, os.path.getsize(OVERLAY)))
    print("  modes:   (none) intro · ?intro=off app only · ?intro=capture still page")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()