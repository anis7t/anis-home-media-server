"""Segment count per GPU for the chunk render: why the layout cannot trust the plan.

Runs the job's exact HLS command on each detected AMF GPU. Measured on this host:
  Vega 8   no -g -> 16 segments (first 2.5s)   -g 96 -> 15 segments (first 4.0s)
  RX 560X  no -g -> 16 segments (first 2.5s)   -g 96 -> ONE 60s segment
So no encoder setting makes both GPUs emit the planned 15 segments, and pinning -g can be
worse than leaving it alone. Content is complete either way; only the count varies, which
is why segment indices are strided (SEGMENTS_PER_CHUNK_STRIDE) instead.

Usage:  python scripts/hls_per_gpu_segments.py
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

_BIN = (r"C:\Users\anis7\AppData\Local\Microsoft\WinGet\Packages"
        r"\Gyan.FFmpeg.Essentials_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.1-essentials_build\bin")
os.environ["PATH"] = _BIN + os.pathsep + os.environ.get("PATH", "")
sys.path.insert(0, r"C:\MediaServer")
FFMPEG, FFPROBE = str(Path(_BIN) / "ffmpeg.exe"), str(Path(_BIN) / "ffprobe.exe")

from app.services.gpu_service import get_gpu_workers  # noqa: E402

START, DUR, FPS = 60.0, 60.0, 24.0
GOP = int(round(4.0 * FPS))


def count(path):
    out = subprocess.run([FFPROBE, "-v", "error", "-select_streams", "v:0", "-count_packets",
                          "-show_entries", "stream=nb_read_packets", "-of", "default=nw=1:nk=1",
                          str(path)], capture_output=True, text=True, timeout=300)
    for line in out.stdout.splitlines():
        line = line.strip()
        if line and line != "N/A":
            return int(float(line))
    return -1


def main():
    tmp = Path(tempfile.mkdtemp(prefix="pergpu_hls_"))
    src = tmp / "synth.mkv"
    subprocess.run([FFMPEG, "-y", "-v", "error", "-f", "lavfi",
                    "-i", "testsrc=size=320x240:rate=24:duration=300",
                    "-f", "lavfi", "-i", "sine=frequency=440:duration=300",
                    "-c:v", "libx264", "-x264-params", "keyint=48:min-keyint=48:scenecut=0",
                    "-preset", "veryfast", "-c:a", "aac", "-shortest", str(src)],
                   check=True, capture_output=True)
    for worker in get_gpu_workers():
        for gop_label, gop_args in (("pinned -g 96", ["-g", str(GOP), "-keyint_min", str(GOP)]),
                                    ("no -g", [])):
            hls = tmp / f"hls_{worker.adapter_id}_{len(gop_args)}"
            hls.mkdir()
            cmd = ([FFMPEG, "-y", "-hide_banner", "-loglevel", "error"]
                   + worker.get_ffmpeg_init_args()
                   + ["-ss", f"{START:.3f}", "-i", str(src), "-t", f"{DUR:.3f}",
                      "-map", "0:v:0", "-map", "0:a:0?"]
                   + worker.get_ffmpeg_video_args() + gop_args + ["-c:a", "copy"]
                   + ["-output_ts_offset", f"{START:.3f}", "-muxdelay", "0",
                      "-force_key_frames", "expr:gte(t,n_forced*4)",
                      "-f", "hls", "-hls_time", "4", "-hls_list_size", "0",
                      "-hls_flags", "independent_segments", "-start_number", "15",
                      "-hls_segment_filename", str(hls / "segment_%06d.ts"), "-nostats",
                      str(hls / "chunk_1.m3u8")])
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
            segs = sorted(hls.glob("segment_*.ts"))
            total = sum(count(s) for s in segs)
            first = count(segs[0]) if segs else -1
            err = (proc.stderr or "").strip().splitlines()
            print(f"{worker.name[:28]:<28} {gop_label:>12}: rc={proc.returncode} "
                  f"{len(segs)} segments, {total} frames (expected 1440), first={first} frames"
                  f"{' | ' + err[-1][:70] if proc.returncode else ''}", flush=True)


if __name__ == "__main__":
    main()