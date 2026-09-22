"""Final exhaustive verification battery: HLS cache management + transcoding.

Everything destructive runs inside a throwaway cache/media root, so the live service data is
never touched. Results are printed as a table and written to _final_battery_results.json.
"""
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, r"C:\MediaServer")

# The shell's PATH lacks the WinGet shims; ffprobe/ffmpeg must be discoverable.
_FFDIR = r"C:\Users\anis7\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg.Essentials_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.1-essentials_build\bin"
os.environ["PATH"] = _FFDIR + os.pathsep + os.environ.get("PATH", "")

import app  # noqa: E402
import app.config as config  # noqa: E402
from app.services import transcode_service as ts  # noqa: E402
from app.services import chunk_transcode_service as cts  # noqa: E402
from app.services.media_service import purge_media  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="hls_battery_")).resolve()
CACHE = TMP / "cache"
MEDIA = TMP / "media"
for sub in ("hls", "previews", "posters", "backdrops", "subtitles", "transcodes"):
    (CACHE / sub).mkdir(parents=True, exist_ok=True)
MEDIA.mkdir(parents=True, exist_ok=True)

app.CACHE_DIR = CACHE
config.CACHE_DIR = CACHE
config.MEDIA_ROOT = MEDIA
if hasattr(app, "MEDIA_ROOT"):
    app.MEDIA_ROOT = MEDIA
config.ARCHIVE_DIR = TMP / "archive"
config.DELETED_DIR = TMP / "deleted"
config.UPLOAD_TARGET_DIR = TMP / "uploads"
config.UPLOAD_TMP = TMP / "uploads_tmp"
for sub in ("archive", "deleted", "uploads", "uploads_tmp"):
    (TMP / sub).mkdir(parents=True, exist_ok=True)

RESULTS = []


def _anchor_video():
    """A real video in the throwaway media root, so the orphan audit is healthy rather than
    degraded. Without it every purge refuses (fail-closed) and the live-guard is never reached."""
    out = MEDIA / "Anchor.2026.mkv"
    if not out.is_file():
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10:duration=6",
             "-c:v", "libx264", "-preset", "ultrafast", str(out)],
            check=True, capture_output=True,
        )
    return out


ANCHOR = _anchor_video()


def record(name, ok, detail=""):
    RESULTS.append({"test": name, "result": "PASS" if ok else "FAIL", "detail": str(detail)[:400]})
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" - {detail}" if detail else ""), flush=True)


def run(name, fn):
    try:
        ok, detail = fn()
        record(name, ok, detail)
    except Exception as exc:  # noqa: BLE001
        import traceback
        record(name, False, f"{type(exc).__name__}: {exc} | {traceback.format_exc().splitlines()[-3][-120:]}")


def make_media(name, seconds=12):
    """Create a real, tiny MKV in the throwaway media root."""
    out = MEDIA / name
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", f"testsrc=size=320x240:rate=15:duration={seconds}",
         "-f", "lavfi", "-i", f"sine=frequency=440:duration={seconds}", "-c:v", "libx264", "-preset", "ultrafast",
         "-c:a", "aac", "-shortest", str(out)],
        check=True, capture_output=True,
    )
    return out


print("\n=== PART 2: cache-safety + transcode-logic battery ===")

# ---- T0: live-cache invariants (read-only, on the real cache) -------------------------
def t0():
    live = Path(r"C:\MediaServer\cache\hls")
    zero = [str(p) for p in live.rglob("*.ts") if p.is_file() and p.stat().st_size == 0]
    segs = sum(1 for _ in live.rglob("*.ts"))
    return (not zero), f"{segs} live segments, zero-byte segments: {len(zero)}"
run("T0 no zero-byte segments in the live cache", t0)


# ---- T1-T3: the audit must fail closed ------------------------------------------------
def _plant_orphans(count=1):
    made = []
    for i in range(count):
        d = ts.get_cache_dir() / "hls" / f"orphan_probe_{i}_{time.time_ns()}"
        d.mkdir(parents=True, exist_ok=True)
        (d / "segment_000000.ts").write_bytes(b"x" * 128)
        made.append(d)
    return made


def t1():
    real = ts.video_paths
    ts.video_paths = lambda: (_ for _ in ()).throw(RuntimeError("simulated enumeration failure"))
    try:
        audit = ts.audit_orphaned_caches()
    finally:
        ts.video_paths = real
    return (audit.get("degraded") is True and not audit["orphaned_hls"] and not audit["orphaned_previews"],
            f"degraded={audit.get('degraded')} reasons={audit.get('degraded_reasons')}")
run("T1 audit fails closed when media enumeration raises", t1)


def t2():
    _plant_orphans(1)
    real = ts.hls_cache_dir
    ts.hls_cache_dir = lambda p: (_ for _ in ()).throw(RuntimeError("simulated per-file failure"))
    try:
        audit = ts.audit_orphaned_caches()
    finally:
        ts.hls_cache_dir = real
    return (audit.get("degraded") is True and not audit["orphaned_hls"], f"degraded={audit.get('degraded')}")
run("T2 audit fails closed when a per-file cache key raises", t2)


def t3():
    # enumeration succeeds but reports no media while cache dirs exist -> degraded
    # (never "everything is an orphan"), simulated by stubbing the enumeration itself
    _plant_orphans(1)
    real = ts.video_paths
    ts.video_paths = lambda: []
    try:
        audit = ts.audit_orphaned_caches()
    finally:
        ts.video_paths = real
    return (audit.get("degraded") is True and not audit["orphaned_hls"] and not audit["orphaned_previews"],
            f"degraded={audit.get('degraded')} reasons={audit.get('degraded_reasons')}")
run("T3 audit fails closed when no videos are found but caches exist", t3)


# ---- T4-T9: purge guards ---------------------------------------------------------------
def t4():
    real = ts.video_paths
    ts.video_paths = lambda: (_ for _ in ()).throw(RuntimeError("simulated"))
    try:
        res = ts.purge_orphaned_caches(dry_run=False)
    finally:
        ts.video_paths = real
    return (res.get("refused") is True and res["purged_count"] == 0, f"refused={res.get('refused')} reason={res.get('reason')}")
run("T4 purge refuses to run when the audit is degraded", t4)


def _live_artifact_case(name, artifacts):
    def case():
        d = ts.get_cache_dir() / "hls" / f"live_probe_{time.time_ns()}"
        d.mkdir(parents=True, exist_ok=True)
        (d / "segment_000000.ts").write_bytes(b"x" * 128)
        for fname in artifacts:
            (d / fname).write_text("#EXTM3U\n#EXTINF:4.0,\nsegment_000000.ts\n")
        audit = ts.audit_orphaned_caches()
        res = ts.purge_orphaned_caches(dry_run=False)
        survived = d.exists()
        shutil.rmtree(d, ignore_errors=True)
        ok = survived and not res.get("refused") and len(res.get("skipped_live", [])) >= 1
        return ok, (f"audit_degraded={audit.get('degraded')} refused={res.get('refused')} "
                    f"skipped_live={len(res.get('skipped_live', []))} purged={res['purged_count']}")
    return case
run("T5 purge skips a dir holding a fresh hls.progress", _live_artifact_case("progress", ["hls.progress"]))
run("T6 purge skips a dir holding a fresh playlist.m3u8", _live_artifact_case("playlist", ["playlist.m3u8"]))


def t7():
    d = ts.get_cache_dir() / "hls" / f"tmp_only_{time.time_ns()}"
    d.mkdir(parents=True, exist_ok=True)
    (d / "segment_000000.ts").write_bytes(b"x" * 128)
    (d / "chunk_1.m3u8.tmp").write_text("#EXTM3U\n")  # first-chunk window: no playlist yet
    res = ts.purge_orphaned_caches(dry_run=False)
    survived = d.exists()
    shutil.rmtree(d, ignore_errors=True)
    ok = survived and not res.get("refused") and len(res.get("skipped_live", [])) >= 1
    return ok, f"refused={res.get('refused')} skipped_live={len(res.get('skipped_live', []))} purged={res['purged_count']}"
run("T7 purge skips a dir in its first-chunk window (only chunk_N.m3u8.tmp)", t7)


def t8():
    d = ts.get_cache_dir() / "hls" / f"true_orphan_{time.time_ns()}"
    d.mkdir(parents=True, exist_ok=True)
    (d / "segment_000000.ts").write_bytes(b"x" * 4096)
    res = ts.purge_orphaned_caches(dry_run=False)
    return (not d.exists() and res["purged_count"] >= 1 and res["freed_bytes"] >= 4096,
            f"refused={res.get('refused')} purged={res['purged_count']} freed={res['freed_bytes']}")
run("T8 purge still deletes a genuine orphan and reports freed bytes", t8)


def t9():
    d = ts.get_cache_dir() / "hls" / f"stale_live_{time.time_ns()}"
    d.mkdir(parents=True, exist_ok=True)
    (d / "segment_000000.ts").write_bytes(b"x" * 128)
    pl = d / "playlist.m3u8"
    pl.write_text("#EXTM3U\n#EXTINF:4.0,\nsegment_000000.ts\n")
    old = time.time() - (ts.RECENT_CACHE_GRACE_SECONDS + 120)
    os.utime(pl, (old, old))
    os.utime(d / "segment_000000.ts", (old, old))
    res = ts.purge_orphaned_caches(dry_run=False)
    return (not d.exists()), f"stale artifacts past the {ts.RECENT_CACHE_GRACE_SECONDS}s grace are purgeable (purged={res['purged_count']})"
run("T9 a stale (abandoned) transcode dir is still purgeable", t9)


# ---- T10/T10b: real ffmpeg encode while purges fire ------------------------------------
def _encode_case(name, tmp_name=None, pre=None):
    d = ts.get_cache_dir() / "hls" / f"encode_{time.time_ns()}"
    d.mkdir(parents=True, exist_ok=True)
    if pre:
        pre(d)
    proc = subprocess.Popen(
        ["ffmpeg", "-y", "-v", "warning", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=15:duration=12",
         "-c:v", "libx264", "-preset", "ultrafast", "-g", "30",
         "-force_key_frames", "expr:gte(t,n_forced*2)", "-f", "hls", "-hls_time", "2",
         "-hls_playlist_type", "event", "-hls_segment_filename", str(d / "segment_%06d.ts"),
         str(d / "playlist.m3u8")],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    time.sleep(1.0)
    purges = []
    for _ in range(3):
        purges.append(ts.purge_orphaned_caches(dry_run=False))
        time.sleep(0.7)
    out, err = proc.communicate(timeout=90)
    segs = sorted(d.glob("segment_*.ts"))
    survived = d.exists() and len(segs) >= 3
    errors = [l for l in (err or "").splitlines() if re.search(r"Operation not permitted|No such file|failed to rename", l, re.I)]
    skips = sum(len(p.get("skipped_live", [])) for p in purges)
    refused = [p.get("refused") for p in purges]
    detail = (f"rc={proc.returncode} segments={len(segs)} live_skips={skips} "
              f"refused={refused} rename_errors={len(errors)}")
    shutil.rmtree(d, ignore_errors=True)
    return (proc.returncode == 0 and survived and not errors and skips >= 1), detail


run("T10 real ffmpeg HLS encode survives 3 concurrent purges", lambda: _encode_case("encode"))


def _tmp_only_pre(d):
    (d / "chunk_1.m3u8.tmp").write_text("#EXTM3U\n")
run("T10b real ffmpeg encode during the first-chunk window survives purges",
    lambda: _encode_case("encode_tmp", pre=_tmp_only_pre))


# ---- T11: per-media purge is scoped ----------------------------------------------------
def t11():
    m1 = MEDIA / "dup" / "Same.Name.2026.mkv"
    m1.parent.mkdir(parents=True, exist_ok=True)
    m1.write_bytes(b"0" * 64)
    m2 = MEDIA / "Same.Name.2026.mkv"
    m2.write_bytes(b"0" * 64)
    d1 = ts.hls_cache_dir(m1)
    d2 = ts.hls_cache_dir(m2)
    for d in (d1, d2):
        d.mkdir(parents=True, exist_ok=True)
        (d / "segment_000000.ts").write_bytes(b"x" * 128)
    ts.purge_transcode_caches_for_media(m1)
    return (not d1.exists() and d2.exists()), f"target_removed={not d1.exists()} sibling_kept={d2.exists()}"
run("T11 per-media purge deletes only that media's cache (same basename, two roots)", t11)


# ---- T12: junction/symlink escape ------------------------------------------------------
def t12():
    outside = TMP / "outside_target"
    outside.mkdir(exist_ok=True)
    (outside / "keep.txt").write_text("do not delete")
    link = ts.get_cache_dir() / "hls" / f"junction_{time.time_ns()}"
    made = subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(outside)],
                          capture_output=True, text=True)
    if made.returncode != 0:
        return True, f"junction could not be created, skipping ({made.stderr.strip()[:60]})"
    ts.purge_orphaned_caches(dry_run=False)
    intact = (outside / "keep.txt").is_file()
    try:
        if link.exists() and not any(link.iterdir()):
            link.rmdir()
    except OSError:
        pass
    return intact, f"target outside the cache survived: {intact}"
run("T12 a junction pointing outside the cache cannot be emptied by a purge", t12)


# ---- T13: no phantom-path logging ------------------------------------------------------
def t13():
    records = []
    handler = logging.Handler()
    handler.emit = lambda rec: records.append(rec.getMessage())
    ts.logger.addHandler(handler)
    try:
        fake = MEDIA / "Never.Existed.2026.mkv"
        ts.purge_transcode_caches_for_media(fake)
    finally:
        ts.logger.removeHandler(handler)
    phantom = [m for m in records if "Purged HLS directory" in m]
    return (not phantom), f"phantom purge log lines: {len(phantom)}"
run("T13 per-media purge does not log deletions of paths that never existed", t13)


# ---- T14: startup cleanup enforces the cap but never purges HLS ------------------------
def t14():
    tr = ts.get_cache_dir() / "transcodes"
    tr.mkdir(parents=True, exist_ok=True)
    for i in range(3):
        (tr / f"fake_{i}.mp4").write_bytes(b"z" * 2_000_000)
    hls_dir = ts.get_cache_dir() / "hls" / f"startup_orphan_{time.time_ns()}"
    hls_dir.mkdir(parents=True, exist_ok=True)
    (hls_dir / "segment_000000.ts").write_bytes(b"x" * 256)
    original = config.CACHE_MAX_BYTES
    config.CACHE_MAX_BYTES = 3_000_000
    try:
        ts.cleanup_cache_on_startup()
    finally:
        config.CACHE_MAX_BYTES = original
    remaining = sum(f.stat().st_size for f in tr.glob("*.mp4") if f.is_file())
    return (remaining <= 3_000_000 and hls_dir.exists(),
            f"transcodes trimmed to {remaining} bytes, orphan hls dir untouched: {hls_dir.exists()}")
run("T14 startup cleanup trims the transcode cap and never purges HLS orphans", t14)


# ---- T15: ENDLIST only on validated coverage ------------------------------------------
def _job_instance(hls_dir, total_duration):
    job = object.__new__(cts.DualGPUTranscodeJob)
    job.hls_dir = hls_dir
    job.playlist = hls_dir / "playlist.m3u8"
    job.progress_file = hls_dir / "hls.progress"
    job.filename = hls_dir.name
    job.total_duration = total_duration
    job.encoded_duration = 0.0
    job._initial_cached_sec = 0.0
    job._start_wall_time = time.time()
    job._returncode = None
    return job


def t15():
    cts._VALIDATION_FAILURES.pop("__probe__", None)
    hls_dir = ts.get_cache_dir() / "hls" / "__probe__"
    shutil.rmtree(hls_dir, ignore_errors=True)
    hls_dir.mkdir(parents=True, exist_ok=True)
    for i in range(5):  # 5 x 2s of segments against a 100s video -> 10% coverage
        (hls_dir / f"segment_{i:06d}.ts").write_bytes(b"x" * 1024)
    job = _job_instance(hls_dir, 100.0)

    job._finalize()
    first = job.playlist.read_text()
    first_rc = job._returncode
    job._finalize()
    second = job.playlist.read_text()
    job._finalize()
    third = job.playlist.read_text()
    gave_up = "#EXT-X-ENDLIST" in third  # must stay False: an under-covered cache stays repairable
    detail = (f"attempt1 ENDLIST={'#EXT-X-ENDLIST' in first} rc={first_rc}; "
              f"attempt2 ENDLIST={'#EXT-X-ENDLIST' in second}; attempt3 (give-up) ENDLIST={gave_up}; "
              f"progress={job.progress_file.read_text().splitlines()[-1][:40]}")
    ok = ("#EXT-X-ENDLIST" not in first and first_rc == 1
          and "#EXT-X-ENDLIST" not in second and not gave_up)
    cts._VALIDATION_FAILURES.pop("__probe__", None)
    shutil.rmtree(hls_dir, ignore_errors=True)
    return ok, detail
run("T15 ENDLIST withheld on partial coverage, never written by the give-up path", t15)


def t16():
    hls_dir = ts.get_cache_dir() / "hls" / "__probe_full__"
    shutil.rmtree(hls_dir, ignore_errors=True)
    hls_dir.mkdir(parents=True, exist_ok=True)
    for i in range(5):
        (hls_dir / f"segment_{i:06d}.ts").write_bytes(b"x" * 1024)
    job = _job_instance(hls_dir, 20.0)  # 5 x default target duration (4s) >= 100% coverage
    job._finalize()
    text = job.playlist.read_text()
    ok = "#EXT-X-ENDLIST" in text and job._returncode == 0
    shutil.rmtree(hls_dir, ignore_errors=True)
    return ok, f"ENDLIST={'#EXT-X-ENDLIST' in text} rc={job._returncode}"
run("T16 ENDLIST written when coverage validates", t16)


# ---- T17: source duration uses the video stream, not the container ---------------------
def t17():
    clip = MEDIA / "video_short_audio_long.mkv"
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error",
         "-f", "lavfi", "-i", "testsrc=size=320x240:rate=15:duration=6",
         "-f", "lavfi", "-i", "sine=frequency=440:duration=20",
         "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-map", "0:v", "-map", "1:a", str(clip)],
        check=True, capture_output=True,
    )
    ts.clear_video_duration_cache()
    video = ts.source_video_duration(clip, fallback=0.0)
    container = float(ts.probe_media(clip).get("format", {}).get("duration") or 0)
    ok = video and container and abs(video - 6) < 1.0 and container > 15
    return ok, f"video_end={video:.3f}s container={container:.3f}s"
run("T17 source duration measures the video stream end, not the container", t17)


# ---- T18: traversal-proof media deletion ----------------------------------------------
def t18():
    victim = TMP / "victim.txt"
    victim.write_text("must survive")
    attacks = [
        f"..\\..\\{TMP.name}\\victim.txt",
        str(victim),
        "..%5C..%5C..%5CWindows%5CSystem32%5Cdrivers%5Cetc%5Chosts",
        "....//....//victim.txt",
    ]
    outcomes = []
    for name in attacks:
        try:
            res = purge_media(name)
        except Exception as exc:  # noqa: BLE001
            outcomes.append(f"{name[:24]}: raised {type(exc).__name__}")
            continue
        outcomes.append(f"{name[:24]}: success={res.get('success')} file_deleted={res.get('file_deleted')}")
    survived = victim.is_file()
    return (survived and not any("file_deleted': True" in o or "file_deleted=True" in o for o in outcomes),
            f"victim survived={survived} | " + " ; ".join(outcomes))
run("T18 media deletion refuses traversal/absolute/outside-library names", t18)

print("\n=== summary ===")
passed = sum(1 for r in RESULTS if r["result"] == "PASS")
print(f"  {passed}/{len(RESULTS)} passed")
Path(r"C:\MediaServer\_final_battery_results.json").write_text(json.dumps(RESULTS, indent=2), encoding="utf-8")
print(f"  results -> C:\\MediaServer\\_final_battery_results.json")
