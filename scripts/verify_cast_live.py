"""Live Cast verification against the real receiver.

Teardown is the point of this file's shape, not an afterthought. Every run
starts a cast on the user's television, so `stop` runs in a `finally` that no
early return, exception or timeout can skip. A verification script that can
leave a film playing on someone's TV is not a verification script.

The two commands run against :8001 by default and both quit the receiver app,
so the television returns to its home screen rather than sitting on an idle
black receiver app.

Usage:
    python scripts/verify_cast_live.py
    python scripts/verify_cast_live.py --base http://127.0.0.1:8000
    python scripts/verify_cast_live.py --skip-resume
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CAST_DEVICE_ID = "cast:72d252f1-e63a-4248-5c46-ad2ad74229c8"
SAMPLE = (
    "2001 A Space Odyssey (1968) [BluRay] [1080p] [YTS.AM]/"
    "2001.A.Space.Odyssey.1968.1080p.BluRay.x264-[YTS.AM].mp4"
)


def call(base, path, payload=None, timeout=120):
    url = base + path
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        url, data=data, method="POST" if payload is not None else "GET",
        headers={"Content-Type": "application/json"} if payload else {},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def try_call(base, path, payload=None, timeout=120):
    """Never raises - a failed call is a result, not an exception here."""
    try:
        return call(base, path, payload, timeout)
    except urllib.error.HTTPError as exc:
        try:
            return json.loads(exc.read().decode())
        except Exception:
            return {"ok": False, "error": f"HTTP {exc.code}"}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def find_cast_device(base, attempts=6):
    """Discovery misses a device roughly one scan in three, so retry."""
    for n in range(1, attempts + 1):
        try_call(base, "/api/cast/devices?refresh=1")
        for _ in range(20):
            time.sleep(3)
            listing = try_call(base, "/api/cast/devices")
            if not listing.get("scanning", False):
                cast = [d for d in listing.get("devices", []) if d.get("kind") == "cast"]
                if cast:
                    print(f"  cast device found on scan {n}: {cast[0]['id']}")
                    return cast[0]
    return None


def status(base, device_id):
    q = urllib.parse.quote(device_id, safe="")
    return try_call(base, f"/api/cast/status?device_id={q}")


def wait_for(predicate, timeout=45, interval=4):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = predicate()
        if last is not None:
            return last
        time.sleep(interval)
    return last


def report(label, ok, detail=""):
    print(f"  {'PASS' if ok else 'FAIL'}  {label}{('  ' + detail) if detail else ''}")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8001")
    ap.add_argument("--skip-resume", action="store_true")
    args = ap.parse_args()
    base = args.base.rstrip("/")

    print(f"target: {base}")
    print("NOTE: this starts playback on the receiver; teardown is guaranteed below.\n")

    device = find_cast_device(base)
    if not device:
        print("FAIL  no cast device discovered")
        return 1

    device_id = device["id"]
    results = []
    started = False

    try:
        target = args.skip_resume and None or 600
        print(f"--- casting at position {target} ---")
        played = try_call(base, "/api/cast/play",
                          {"device_id": device_id, "filename": SAMPLE, "position": target})
        started = bool(played.get("ok"))
        results.append(report("play accepted", started, json.dumps(played)[:160]))

        st = wait_for(lambda: (lambda s: s if s.get("state") == "playing" else None)(status(base, device_id)))
        results.append(report(
            "playing", bool(st and st.get("state") == "playing"),
            f"state={st.get('state') if st else None} pos={st.get('position') if st else None}"))

        if target and st and st.get("position", 0) > 100:
            results.append(report(
                "resume honoured", abs(st["position"] - target) < 30,
                f"asked {target}, receiver reports {st['position']:.1f}"))

        # The point of this phase: a session that dies must still be usable.
        print("\n--- idling 45s to let the session die, then commanding it ---")
        time.sleep(45)
        seeked = try_call(base, "/api/cast/control",
                          {"device_id": device_id, "action": "seek", "value": 1500})
        results.append(report("seek after session drop recovers", bool(seeked.get("ok")),
                              json.dumps(seeked)[:160]))

        # Volume and mute are asserted on the RECEIVER'S REPORTED VALUE, not on
        # the call's ok flag. An earlier version reported "volume accepted" and
        # "mute accepted" while the very next line showed vol=100.0
        # muted=False: the receiver acknowledged commands it did not apply, and
        # asserting on the ack hid that. An ack is not an effect.
        try_call(base, "/api/cast/control",
                 {"device_id": device_id, "action": "volume", "value": 40})
        time.sleep(4)
        vst = status(base, device_id)
        got_vol = vst.get("volume")
        results.append(report(
            "volume took effect", isinstance(got_vol, (int, float)) and abs(got_vol - 40) <= 2,
            f"asked 40, receiver reports {got_vol}"))

        try_call(base, "/api/cast/control",
                 {"device_id": device_id, "action": "mute", "value": True})
        time.sleep(4)
        mst = status(base, device_id)
        results.append(report(
            "mute took effect", mst.get("muted") is True,
            f"asked muted=True, receiver reports muted={mst.get('muted')}"))

        try_call(base, "/api/cast/control",
                 {"device_id": device_id, "action": "mute", "value": False})
        time.sleep(3)

        final = status(base, device_id)
        print(f"  receiver last reported: state={final.get('state')} "
              f"pos={final.get('position')} vol={final.get('volume')} muted={final.get('muted')}")

    finally:
        # The whole reason this script is shaped like this.
        print("\n--- teardown (guaranteed) ---")
        stopped = try_call(base, "/api/cast/control",
                           {"device_id": device_id, "action": "stop"}, timeout=120)
        print(f"  stop -> ok={stopped.get('ok')} {json.dumps(stopped)[:120]}")
        time.sleep(5)
        after = status(base, device_id)
        # Two different things, and only the second one is the blank-screen bug:
        #   * playback stopped  -> state is stopped/unknown
        #   * the receiver APP quit -> the television is really free
        # A quit app reports an empty media status, and so does an app left
        # running with nothing playing. Only the receiver's application list
        # tells them apart.
        app_running = bool(after.get("receiver_app_running"))
        playback_stopped = after.get("state") in ("unknown", "stopped") or not after.get("ok")
        idle = playback_stopped and not app_running
        print(f"  receiver after stop: state={after.get('state')} "
              f"app_running={app_running} -> {'IDLE' if idle else 'RECEIVER STILL UP'}")
        if playback_stopped and app_running:
            print("  NOTE: playback stopped but the receiver app is still running -")
            print("        the television is probably showing a blank screen with a cast icon.")

    passed = sum(1 for r in results if r)
    print(f"\n{passed}/{len(results)} checks passed")
    if started and not idle:
        print("WARNING: the receiver may still be playing - check the television.")
        return 2
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())