#!/usr/bin/env python3
"""Normalise captured frames and encode the two intro videos.

The frame capture runs in a cloud browser whose device pixel ratio drifts
between sessions, so the PNGs come out at different rasters (3840x2160,
2400x1350, 2160x3840, ...). ffmpeg's image sequence demuxer needs one size, so
every frame is first scaled to the delivery raster, then the sequence is
encoded with the theme's audio track.

    python encode_videos.py            # both orientations
    python encode_videos.py landscape  # just one

Frames: 90 per orientation at 30 fps -> exactly 3.000 s.
"""

from __future__ import annotations

import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
AUDIO = os.path.join(HERE, "intro-theme.wav")

JOBS = {
    "landscape": {"dir": "frames", "size": (1920, 1080), "out": "intro-demo.mp4"},
    "portrait": {"dir": "frames-portrait", "size": (1080, 1920), "out": "intro-demo-portrait.mp4"},
}
FPS = 30
CRF = "17"


def png_size(path):
    with open(path, "rb") as f:
        return struct.unpack(">II", f.read(33)[16:24])


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("command failed: %s\n%s" % (" ".join(cmd), r.stderr[-2000:]))
    return r


def normalise(dirname, size):
    """Scale every frame to `size`; returns (count, rescaled, already_ok)."""
    d = os.path.join(HERE, dirname)
    frames = sorted(f for f in os.listdir(d) if f.endswith(".png"))
    if len(frames) != 90:
        raise SystemExit("%s holds %d frames, expected 90" % (dirname, len(frames)))
    rescaled = ok = 0
    for i, name in enumerate(frames):
        p = os.path.join(d, name)
        got = png_size(p)
        if got == size:
            ok += 1
            continue
        tmp = p + ".tmp.png"
        run(["ffmpeg", "-v", "error", "-y", "-i", p,
             "-vf", "scale=%d:%d:flags=lanczos" % size, tmp])
        os.replace(tmp, p)
        rescaled += 1
        if (i + 1) % 30 == 0:
            print("    normalised %d/90" % (i + 1))
    return len(frames), rescaled, ok


def encode(dirname, out, size):
    d = os.path.join(HERE, dirname)
    pattern = os.path.join(d, "f_%04d.png")
    tmp = os.path.join(HERE, out + ".tmp.mp4")
    run(["ffmpeg", "-v", "error", "-y",
         "-framerate", str(FPS), "-i", pattern,
         "-i", AUDIO,
         "-c:v", "libx264", "-crf", CRF, "-preset", "slow",
         "-pix_fmt", "yuv420p", "-r", str(FPS),
         "-c:a", "aac", "-b:a", "192k", "-ar", "44100",
         "-movflags", "+faststart", "-shortest",
         "-vf", "scale=%d:%d:flags=lanczos" % size,
         tmp])
    os.replace(tmp, os.path.join(HERE, out))
    return os.path.join(HERE, out)


def main():
    which = sys.argv[1:] or list(JOBS)
    for key in which:
        job = JOBS[key]
        print("== %s ==" % key)
        count, rescaled, ok = normalise(job["dir"], job["size"])
        print("  frames: %d  (rescaled %d, already %dx%d %d)"
              % (count, rescaled, job["size"][0], job["size"][1], ok))
        path = encode(job["dir"], job["out"], job["size"])
        print("  wrote %s  (%.1f MB)" % (job["out"], os.path.getsize(path) / 1e6))
    return 0


if __name__ == "__main__":
    sys.exit(main())
