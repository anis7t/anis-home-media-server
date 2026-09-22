"""Guards that keep vanished/phantom media from spinning the HLS transcode path.

A repeated request for a media name whose file no longer exists (a stale client, a queue entry
captured before a deletion) must be refused and must never create or probe a cache directory.
"""
import logging
import sys
import threading
import time
from pathlib import Path

import pytest
import types

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app.config as config  # noqa: E402
from app.services import transcode_service as ts  # noqa: E402
from app.services import worker_service as ws  # noqa: E402


class _Collector(logging.Handler):
    def __init__(self):
        super().__init__()
        self.messages = []

    def emit(self, record):
        self.messages.append(record.getMessage())


@pytest.fixture()
def temp_root(tmp_path, monkeypatch):
    root = tmp_path / "media"
    root.mkdir()
    cache = tmp_path / "cache"
    (cache / "hls").mkdir(parents=True)
    monkeypatch.setattr(config, "MEDIA_ROOT", root)
    monkeypatch.setattr(config, "CACHE_DIR", cache)
    monkeypatch.setattr(ts, "get_cache_dir", lambda: cache)
    return root


def test_ensure_hls_transcode_refuses_missing_media(temp_root):
    """A name with no file on disk returns None, logs, and creates no cache directory."""
    collector = _Collector()
    ts.logger.addHandler(collector)
    try:
        proc = ts.ensure_hls_transcode("Does.Not.Exist.2026.mkv")
    finally:
        ts.logger.removeHandler(collector)
    created = list((ts.get_cache_dir() / "hls").iterdir())
    assert proc is None
    assert created == [], f"a phantom name created cache dirs: {created}"
    assert not any("Transcoding" in m for m in collector.messages)


def test_ensure_hls_transcode_refuses_deleted_file(temp_root):
    """A real media file that is deleted between listing and request is refused."""
    media = temp_root / "Gone.Tomorrow.2026.mkv"
    media.write_bytes(b"0" * 2048)
    media.unlink()
    collector = _Collector()
    ts.logger.addHandler(collector)
    try:
        proc = ts.ensure_hls_transcode(media.name)
    finally:
        ts.logger.removeHandler(collector)
    assert proc is None
    assert list((ts.get_cache_dir() / "hls").iterdir()) == []


def _capture_logger():
    """A private logger, so capture cannot depend on global logging state or levels."""
    logger = logging.getLogger("test.capture.transcode_service")
    logger.handlers = []
    logger.setLevel(logging.INFO)
    logger.propagate = False
    collector = _Collector()
    logger.addHandler(collector)
    return logger, collector


def test_resume_check_log_names_the_media(tmp_path, monkeypatch):
    """The resume-check line must identify the media, not only an opaque cache hash."""
    logger, collector = _capture_logger()
    monkeypatch.setattr(ts, "logger", logger)
    directory = tmp_path / "cache_dir"
    directory.mkdir()
    # playlist that references a segment which is not on disk -> the "0 valid segments"
    # branch (the one that logs) is the branch under test
    (directory / "playlist.m3u8").write_text("#EXTM3U\n#EXTINF:4.0,\nsegment_000000.ts\n")
    try:
        resume, count = ts._hls_resume_point(directory, directory / "playlist.m3u8",
                                             label="Some.Movie.2026.mkv")
    finally:
        pass
    assert (resume, count) == (0.0, 0)
    joined = " | ".join(collector.messages)
    assert "Some.Movie.2026.mkv" in joined, f"media name missing from log: {joined}"


def test_completeness_requires_validated_coverage_not_90_percent(tmp_path, monkeypatch):
    """An abandoned partial cache must not count as complete just for ~90% coverage."""
    media = tmp_path / "Partial.2026.mkv"
    media.write_bytes(b"0" * 1024)
    directory = tmp_path / "hls"
    directory.mkdir()
    playlist = directory / "playlist.m3u8"
    monkeypatch.setattr(ts, "probe_media", lambda _p: {"format": {"duration": "1000.0"}})

    def write_playlist(seconds):
        segs = max(1, int(seconds // 4))
        body = "".join(f"#EXTINF:4.0,\nsegment_{i:06d}.ts\n" for i in range(segs))
        playlist.write_text("#EXTM3U\n#EXT-X-VERSION:3\n" + body)
        for i in range(segs):
            f = directory / f"segment_{i:06d}.ts"
            if not f.is_file():
                f.write_bytes(b"x" * 64)
        return segs

    write_playlist(950)   # 95% - previously accepted as complete
    assert ts._is_hls_truly_complete(playlist, media) is False
    write_playlist(990)   # 99% - validated coverage
    assert ts._is_hls_truly_complete(playlist, media) is True
    with playlist.open("a") as fh:
        fh.write("#EXT-X-ENDLIST\n")
    assert ts._is_hls_truly_complete(playlist, media) is True


def test_chunk_with_middle_hole_is_not_treated_as_rendered(tmp_path):
    """A chunk is only rendered when every expected segment exists, not just the first/last."""
    from app.services import chunk_transcode_service as cts

    import tempfile
    hls = tmp_path / "hls"
    hls.mkdir()
    job = object.__new__(cts.DualGPUTranscodeJob)
    job.hls_dir = hls
    chunk = {"chunk_id": 0, "start_time": 0.0, "duration": 40.0, "start_seg": 0, "expected_segs": 10}
    for i in range(10):
        (hls / f"segment_{i:06d}.ts").write_bytes(b"x" * 256)
    assert job._chunk_fully_rendered(chunk) is True
    # remove a middle segment: previously this still counted as "already cached"
    (hls / "segment_000004.ts").unlink()
    assert job._chunk_fully_rendered(chunk) is False
    # a zero-byte segment is not usable either
    (hls / "segment_000004.ts").write_bytes(b"")
    assert job._chunk_fully_rendered(chunk) is False


def test_validation_shortfall_forces_tail_rerender(tmp_path):
    """A short validation must schedule the tail for re-encoding on the next attempt."""
    from app.services import chunk_transcode_service as cts

    hls = tmp_path / "hls"
    hls.mkdir()
    for i in range(5):
        (hls / f"segment_{i:06d}.ts").write_bytes(b"x" * 1024)
    job = object.__new__(cts.DualGPUTranscodeJob)
    job.hls_dir = hls
    job.playlist = hls / "playlist.m3u8"
    job.progress_file = hls / "hls.progress"
    job.filename = "Tail.2026.mkv"
    job.total_duration = 100.0
    job.encoded_duration = 0.0
    job._initial_cached_sec = 0.0
    job._start_wall_time = time.time()
    job._returncode = None
    cts._VALIDATION_FAILURES.pop(str(hls), None)
    cts._FORCE_TAIL_RERENDER.pop(str(hls), None)
    job._finalize()
    assert cts._FORCE_TAIL_RERENDER.get(str(hls)) is True
    assert job._returncode == 1
    # and the selection itself must nominate the chunks covering the tail
    chunks = cts.plan_chunks(100.0, chunk_duration=20.0)
    tail = job._tail_chunks(chunks)
    assert tail, "tail selection returned nothing"
    assert all(c["start_time"] + c["duration"] > 95.0 for c in tail)
    # three short validations must NOT mark the cache complete (ENDLIST is authoritative and
    # would permanently hide the missing seconds)
    job._finalize()
    job._finalize()
    assert "#EXT-X-ENDLIST" not in job.playlist.read_text(errors="replace")
    assert cts._TAIL_REPAIR_ATTEMPTS.get(str(hls), 0) >= 1
    cts._VALIDATION_FAILURES.pop(str(hls), None)
    cts._FORCE_TAIL_RERENDER.pop(str(hls), None)
    cts._TAIL_REPAIR_ATTEMPTS.pop(str(hls), None)


def test_auto_transcoder_skips_missing_media(temp_root, monkeypatch):
    """The worker loop must skip an enumerated-but-gone file instead of retrying it."""
    missing = temp_root / "Vanished.2026.mkv"
    monkeypatch.setattr(ws, "video_paths", lambda: [missing])
    monkeypatch.setattr(ws, "needs_transcode", lambda _p: True)
    monkeypatch.setattr(config, "PRECACHE_INTERVAL", 0.1)
    logger, collector = _capture_logger()
    monkeypatch.setattr(ws, "logger", logger)
    config.SHUTDOWN_EVENT.clear()
    thread = threading.Thread(target=ws.auto_transcoder_loop, daemon=True)
    thread.start()
    time.sleep(6.5)  # auto_transcoder_loop sleeps 5s before its first pass

    config.SHUTDOWN_EVENT.set()
    thread.join(timeout=5)
    config.SHUTDOWN_EVENT.clear()
    assert any("skipping missing media file" in m for m in collector.messages), collector.messages

# ---------------------------------------------------------------------------
# Content integrity: #EXTINF labels are not evidence.  A resume that trusted the
# mislabelled chunk boundaries re-rendered later content over the boundary content, so
# finished caches could contain real holes while every segment measured sanely.
# ---------------------------------------------------------------------------
from app.services import chunk_transcode_service as cts  # noqa: E402
import os  # noqa: E402


def _age(path, seconds=120):
    """Make a file look old enough to be measured (fresh files are skipped on purpose)."""
    stamp = time.time() - seconds
    os.utime(path, (stamp, stamp))


def test_segment_measurement_is_memoised(temp_root, monkeypatch, tmp_path):
    """The 1 Hz playlist rebuild must not re-probe every boundary once per second."""
    ts.clear_segment_probe_cache()
    seg = tmp_path / "segment_000000.ts"
    seg.write_bytes(b"x" * 4096)
    _age(seg)
    calls = []

    class _Out:
        stdout = "4.0\n"

    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        return _Out()

    monkeypatch.setattr(ts, "_ffprobe_bin", lambda: "ffprobe")
    monkeypatch.setattr(ts.subprocess, "run", fake_run)
    assert ts.measure_segment_duration(seg) == 4.0
    assert ts.measure_segment_duration(seg) == 4.0
    assert len(calls) == 1, f"segment was re-probed {len(calls)} times"


def test_fresh_segment_is_not_measured(temp_root, monkeypatch, tmp_path):
    """A segment ffmpeg is still writing must not be measured: the probe would be meaningless."""
    ts.clear_segment_probe_cache()
    seg = tmp_path / "segment_000001.ts"
    seg.write_bytes(b"x" * 4096)  # mtime is now
    monkeypatch.setattr(ts, "_ffprobe_bin", lambda: "ffprobe")
    assert ts.measure_segment_duration(seg) == 0.0


def test_resume_position_uses_the_honest_label_sum(temp_root, monkeypatch, tmp_path):
    """Regression: the resume position must be the label sum, NOT measured container durations.

    Container durations include audio pre-roll (~1s per segment). Resuming from them put the
    transcode past content that still had to be produced, which is how one cache lost 279s of
    video frames across 101 chunks.
    """
    cache = ts.get_cache_dir() / "hls" / "resume"
    cache.mkdir(parents=True)
    for i in range(3):
        (cache / f"segment_{i:06d}.ts").write_bytes(b"x" * 4096)
    (cache / "playlist.m3u8").write_text(
        "#EXTM3U\n"
        "#EXTINF:2.400000,\nsegment_000000.ts\n"
        "#EXTINF:3.880000,\nsegment_000001.ts\n"
        "#EXTINF:3.880000,\nsegment_000002.ts\n")
    # a container-duration probe would report ~4.8s per segment and resume at ~14.4s
    monkeypatch.setattr(ts, "measure_segment_duration", lambda p: 4.8)
    resume_time, start_seg = ts._hls_resume_point(cache, cache / "playlist.m3u8", label="Movie.mkv")
    assert start_seg == 3
    assert resume_time == pytest.approx(2.4 + 3.88 + 3.88), resume_time


def test_chunk_content_holes_detects_skipped_content(temp_root, monkeypatch, tmp_path):
    """Diagnostic only (never a gate): PTS jumps are reported, and they are expected at chunk
    boundaries because the playlist declares #EXT-X-DISCONTINUITY there."""
    from app.services import chunk_transcode_service as cts

    hls = tmp_path / "hls"
    hls.mkdir()
    # Strided layout: chunk 1 starts at its own stride, so the segment before the boundary is the
    # highest existing index below it - not idx - 1.
    boundary = cts.SEGMENTS_PER_CHUNK_STRIDE
    prev_name = f"segment_{boundary - 1:06d}.ts"
    this_name = f"segment_{boundary:06d}.ts"
    (hls / prev_name).write_bytes(b"x")
    (hls / this_name).write_bytes(b"x")
    spans = {prev_name: (56.0, 60.0), this_name: (68.4, 72.4)}
    monkeypatch.setattr(ts, "measure_segment_video_span", lambda p: spans.get(Path(p).name))
    holes = ts.chunk_content_holes(hls, 120.0)
    assert len(holes) == 1, holes
    assert holes[0]["chunk_id"] == 1 and holes[0]["hole"] == 8.4


def test_chunk_content_holes_clean_when_contiguous(temp_root, monkeypatch, tmp_path):
    from app.services import chunk_transcode_service as cts

    hls = tmp_path / "hls"
    hls.mkdir()
    boundary = cts.SEGMENTS_PER_CHUNK_STRIDE
    prev_name = f"segment_{boundary - 1:06d}.ts"
    this_name = f"segment_{boundary:06d}.ts"
    (hls / prev_name).write_bytes(b"x")
    (hls / this_name).write_bytes(b"x")
    spans = {prev_name: (56.0, 60.0), this_name: (60.04, 64.04)}
    monkeypatch.setattr(ts, "measure_segment_video_span", lambda p: spans.get(Path(p).name))
    assert ts.chunk_content_holes(hls, 120.0) == []


def test_completeness_uses_the_video_end(temp_root, monkeypatch, tmp_path):
    """A container that runs past the last video frame must not mark a finished cache incomplete."""
    cache = ts.get_cache_dir() / "hls" / "cafebabe"
    cache.mkdir(parents=True)
    playlist = cache / "playlist.m3u8"
    playlist.write_text("#EXTM3U\n#EXTINF:980.000000,\nsegment_000000.ts\n")
    source = temp_root / "Movie.2026.mkv"
    source.write_bytes(b"x" * 1024)
    monkeypatch.setattr(ts, "probe_media", lambda p: {"format": {"duration": "2000"}})
    monkeypatch.setattr(ts, "source_video_duration", lambda p, fallback=None: 1000.0)
    assert ts._is_hls_truly_complete(playlist, source) is True


def test_finalize_refuses_endlist_when_content_has_holes(temp_root, monkeypatch, tmp_path):
    """Coverage can be 100% while positions jump: ENDLIST must not be written over holes."""
    hls = tmp_path / "cache" / "hls" / "holed"
    hls.mkdir(parents=True)
    job = object.__new__(cts.DualGPUTranscodeJob)
    job.hls_dir = hls
    job.filename = "Holed.2026.mkv"
    job.total_duration = 120.0
    job.progress_file = hls / "hls.progress"
    job._returncode = None
    writes = []
    job._update_master_playlist = lambda is_complete=False: writes.append(is_complete)
    job._measure_coverage = lambda: (119.0, True, 0.99)
    monkeypatch.setattr(ts, "chunk_content_deficits",
                        lambda *a, **k: [{"chunk_id": 1, "start": 60.0, "expected_frames": 1440,
                                          "frames": 1200, "missing_s": 10.0}])
    cts._VALIDATION_FAILURES.pop(str(hls), None)
    job._finalize()
    assert True not in writes, "ENDLIST was written for a cache with missing content"


def test_chunk_with_boundary_hole_is_not_rendered(temp_root, monkeypatch, tmp_path):
    hls = tmp_path / "hls"
    hls.mkdir()
    for i in range(15, 30):
        (hls / f"segment_{i:06d}.ts").write_bytes(b"x" * 2048)
    job = object.__new__(cts.DualGPUTranscodeJob)
    job.hls_dir = hls
    job.filename = "Chunked.2026.mkv"
    job.total_duration = 120.0
    monkeypatch.setattr(ts, "chunk_content_deficits",
                        lambda *a, **k: [{"chunk_id": 1, "start": 60.0, "expected_frames": 1440,
                                          "frames": 1200, "missing_s": 10.0}])
    chunk = {"chunk_id": 1, "start_seg": 15, "expected_segs": 15}
    assert job._chunk_fully_rendered(chunk) is False


def test_repair_understated_caches_strips_endlist_when_content_is_missing(temp_root, monkeypatch, tmp_path):
    cache = ts.get_cache_dir() / "hls" / "holed2"
    cache.mkdir(parents=True)
    playlist = cache / "playlist.m3u8"
    body = "".join(f"#EXTINF:4.000000,\nsegment_{i:06d}.ts\n" for i in range(30))
    playlist.write_text("#EXTM3U\n" + body + "#EXT-X-ENDLIST\n")
    media = temp_root / "Holed.2026.mkv"
    media.write_bytes(b"x" * 1024)
    monkeypatch.setattr("app.services.media_service.video_paths", lambda: [media])
    monkeypatch.setattr(ts, "hls_cache_dir", lambda p: cache)
    monkeypatch.setattr(ts, "source_video_duration", lambda p, fallback=None: 120.0)
    monkeypatch.setattr(ts, "chunk_content_deficits",
                        lambda *a, **k: [{"chunk_id": 1, "start": 60.0, "expected_frames": 1440,
                                          "frames": 1200, "missing_s": 10.0}])
    queued = []
    monkeypatch.setattr(ts, "ensure_hls_transcode",
                        lambda rel, force=False: queued.append((rel, force)) or object())
    result = ts.repair_understated_caches()
    # labels claim 100% here: the holes alone must trigger the audit (the Spider-Man state)
    assert result["stripped"] and not result["repaired"]
    # and the re-render must actually be queued: the auto-transcoder's label-based gate would
    # otherwise call this same cache complete and never touch it
    assert queued == [(media.name, True)], queued
    assert "#EXT-X-ENDLIST" not in playlist.read_text(), "a cache with holes still claims completion"


def test_find_ffmpeg_for_path_works_when_proc_is_absent(monkeypatch, tmp_path):
    """The duplicate-job guard must work on Windows, where /proc does not exist.

    Live consequence of the original /proc-only scan: the auto-transcoder started a second job on
    a cache another job was already rendering, doubling GPU work on the same segment indices.
    """
    import psutil
    import app.services.transcode_service as ts

    media = tmp_path / "Guarded.2026.mkv"
    media.write_bytes(b"x")

    class FakeProc:
        def __init__(self, info):
            self.info = info

    class FakePsutil:
        NoSuchProcess = psutil.NoSuchProcess
        AccessDenied = psutil.AccessDenied
        ZombieProcess = psutil.ZombieProcess

        @staticmethod
        def process_iter(attrs):
            return [
                FakeProc({"pid": 111, "name": "ffmpeg.exe",
                          "cmdline": ["ffmpeg.exe", "-i", "Other.mkv", "-f", "hls", "x.m3u8"]}),
                FakeProc({"pid": 222, "name": "ffmpeg.exe",
                          "cmdline": ["ffmpeg.exe", "-ss", "60", "-i", str(media), "-f", "hls",
                                      "-hls_segment_filename",
                                      str(tmp_path / "hls" / "segment_%06d.ts"),
                                      "chunk_1.m3u8"]}),
                FakeProc({"pid": 333, "name": "python.exe", "cmdline": ["python", str(media)]}),
            ]

    monkeypatch.setitem(sys.modules, "psutil", FakePsutil)
    pid, hls_dir = ts.find_ffmpeg_info_for_path(media)
    assert pid == 222, pid
    assert hls_dir == tmp_path / "hls"


def test_force_bypasses_the_label_completeness_gate(temp_root, monkeypatch, tmp_path):
    """force=True must start a job for a cache whose labels look complete.

    The label gate is what stranded Spider-Man: ENDLIST stripped, frames short, labels 99.88%,
    so `_is_hls_truly_complete()` said complete and nothing ever re-rendered it.
    """
    import subprocess as sp

    media = temp_root / "Forced.2026.mkv"
    media.write_bytes(b"x" * 1024)
    cache = tmp_path / "hls" / "forced"
    cache.mkdir(parents=True)
    playlist = cache / "playlist.m3u8"
    playlist.write_text("#EXTM3U\n#EXTINF:4.000000,\nsegment_000000.ts\n")   # no ENDLIST

    monkeypatch.setattr(ts, "hls_cache_dir", lambda p: cache)
    monkeypatch.setattr(ts, "find_ffmpeg_info_for_path", lambda p: (None, None))
    monkeypatch.setattr(ts, "probe_media", lambda p: {"streams": [{"codec_type": "video", "codec_name": "h264"}]})
    monkeypatch.setattr(ts, "_hls_resume_point", lambda *a, **k: (0.0, 0))
    monkeypatch.setattr(ts, "_is_hls_truly_complete", lambda *a, **k: True)   # labels say complete
    started = []

    class FakeProc:
        def poll(self):
            return None

    monkeypatch.setattr(sp, "Popen", lambda *a, **k: started.append(a) or FakeProc())
    monkeypatch.setattr(ts, "ProcessProxy", lambda *a, **k: FakeProc())
    ts.config.HLS_PROCESSES.pop(media.name, None)

    assert ts.ensure_hls_transcode(media.name) is None        # gate respected by default
    ts.config.HLS_PROCESSES.pop(media.name, None)
    assert ts.ensure_hls_transcode(media.name, force=True) is not None
    assert started, "force must reach the ffmpeg spawn"


def test_already_stripped_deficient_cache_is_requeued(temp_root, monkeypatch, tmp_path):
    """A cache left without ENDLIST by an earlier pass is still queued for re-render.

    Without this the heal is one-shot: the worker strips ENDLIST, the auto-transcoder's
    label-based gate calls the cache complete, and a failed render is never retried.
    """
    cache = ts.get_cache_dir() / "hls" / "requeue"
    cache.mkdir(parents=True)
    playlist = cache / "playlist.m3u8"
    body = "".join(f"#EXTINF:4.000000,\nsegment_{i:06d}.ts\n" for i in range(30))
    playlist.write_text("#EXTM3U\n" + body)          # NO ENDLIST: stripped by a previous pass
    media = temp_root / "Requeue.2026.mkv"
    media.write_bytes(b"x" * 1024)
    monkeypatch.setattr("app.services.media_service.video_paths", lambda: [media])
    monkeypatch.setattr(ts, "hls_cache_dir", lambda p: cache)
    monkeypatch.setattr(ts, "source_video_duration", lambda p, fallback=None: 120.0)
    monkeypatch.setattr(ts, "chunk_content_deficits",
                        lambda *a, **k: [{"chunk_id": 1, "start": 60.0, "expected_frames": 1440,
                                          "frames": 1200, "missing_s": 10.0}])
    queued = []
    monkeypatch.setattr(ts, "ensure_hls_transcode",
                        lambda rel, force=False: queued.append((rel, force)) or object())
    result = ts.repair_understated_caches()
    assert queued == [(media.name, True)], queued
    assert result["queued"] == [media.name]
    assert result["stripped"] == []                    # nothing left to strip


def test_repair_understated_caches_leaves_healthy_cache_alone(temp_root, monkeypatch, tmp_path):
    cache = ts.get_cache_dir() / "hls" / "healthy"
    cache.mkdir(parents=True)
    playlist = cache / "playlist.m3u8"
    body = "".join(f"#EXTINF:4.000000,\nsegment_{i:06d}.ts\n" for i in range(30))  # exactly 120s
    playlist.write_text("#EXTM3U\n" + body + "#EXT-X-ENDLIST\n")
    before = playlist.read_bytes()
    media = temp_root / "Healthy.2026.mkv"
    media.write_bytes(b"x" * 1024)
    monkeypatch.setattr("app.services.media_service.video_paths", lambda: [media])
    monkeypatch.setattr(ts, "hls_cache_dir", lambda p: cache)
    monkeypatch.setattr(ts, "source_video_duration", lambda p, fallback=None: 120.0)
    result = ts.repair_understated_caches()
    assert result["inspected"] == 0
    assert playlist.read_bytes() == before


def test_frame_count_takes_first_value_of_duplicated_program_output(temp_root, monkeypatch, tmp_path):
    """A segment read as two MPEG-TS programs makes ffprobe print the whole stream set twice.
    Summing the lines double-counted frames (so no deficit was ever detected); the first value
    is the segment's frame count."""
    ts.clear_segment_probe_cache()
    seg = tmp_path / "segment_000000.ts"
    seg.write_bytes(b"x" * 4096)
    _age(seg)

    class _Out:
        returncode = 0
        stdout = "120\n120\n"

    monkeypatch.setattr(ts, "_ffprobe_bin", lambda: "ffprobe")
    monkeypatch.setattr(ts.subprocess, "run", lambda cmd, **kw: _Out())
    assert ts.measure_segment_frame_count(seg) == 120


def test_frame_count_unknown_on_unreadable_file(temp_root, monkeypatch, tmp_path):
    """Unreadable is -1 (unknown), never 0 (empty): otherwise every chunk looks deficient."""
    ts.clear_segment_probe_cache()
    seg = tmp_path / "segment_000001.ts"
    seg.write_bytes(b"not a video")
    _age(seg)

    class _Out:
        returncode = 1
        stdout = ""

    monkeypatch.setattr(ts, "_ffprobe_bin", lambda: "ffprobe")
    monkeypatch.setattr(ts.subprocess, "run", lambda cmd, **kw: _Out())
    assert ts.measure_segment_frame_count(seg) == -1


def test_chunk_content_deficits_flags_missing_frames(temp_root, monkeypatch, tmp_path):
    """Frame accounting is the real content-loss signal: 24fps x 60s needs 1440 frames."""
    from app.services import chunk_transcode_service as cts

    hls = tmp_path / "hls"
    hls.mkdir()
    from app.services.chunk_transcode_service import HLS_LAYOUT_MARKER, HLS_LAYOUT_STRIDE
    (hls / HLS_LAYOUT_MARKER).write_text(HLS_LAYOUT_STRIDE)
    plan = cts.plan_chunks(120.0)
    for c in plan:
        for i in range(c["start_seg"], c["start_seg"] + c["expected_segs"]):
            (hls / f"segment_{i:06d}.ts").write_bytes(b"x" * 2048)

    first_chunk = set(range(plan[0]["start_seg"], plan[0]["start_seg"] + plan[0]["expected_segs"]))

    def frames(path):
        idx = int(Path(path).name.split("_")[1].split(".")[0])
        return 96 if idx in first_chunk else 80     # 96/24fps = 4s; chunk 1 is 10s short

    monkeypatch.setattr(ts, "measure_segment_frame_count", frames)
    monkeypatch.setattr(ts, "source_frame_rate", lambda p: 24.0)
    deficits = ts.chunk_content_deficits(hls, 120.0, source_path=tmp_path / "Source.mkv")
    assert [d["chunk_id"] for d in deficits] == [1], deficits
    assert deficits[0]["missing_s"] == 10.0


def test_write_text_atomic_leaves_no_temp_file(tmp_path):
    target = tmp_path / "playlist.m3u8"
    assert ts.write_text_atomic(target, "#EXTM3U\n#EXT-X-ENDLIST\n") is True
    assert target.read_text() == "#EXTM3U\n#EXT-X-ENDLIST\n"
    assert list(tmp_path.glob("*.tmp")) == []

def test_repair_pass_rerenders_deficient_chunks_serially(temp_root, monkeypatch, tmp_path):
    """A chunk short of frames is re-rendered one at a time, and the loop is bounded.

    Two chunks encoding concurrently can each lose up to a GOP at the head of a seeked chunk, so
    the pipeline must frame-verify after the parallel pass and repair serially. It must not spin:
    at most max_chunks repairs per run, the rest left to the next pass.
    """
    from app.services import chunk_transcode_service as cts

    hls = tmp_path / "hls"
    hls.mkdir()
    media = tmp_path / "Movie.2026.mkv"
    media.write_bytes(b"x" * 1024)
    job = cts.DualGPUTranscodeJob("Movie.2026.mkv", media, hls, hls / "playlist.m3u8")
    job.total_duration = 300.0
    job.workers = [types.SimpleNamespace(name="fake-gpu", adapter_id=0)]

    deficits = [{"chunk_id": i, "start": i * 60.0, "expected_frames": 1500, "frames": 1410,
                 "missing_s": 1.25} for i in (1, 2, 3)]
    monkeypatch.setattr(ts, "chunk_content_deficits", lambda *a, **k: deficits)

    executed = []

    def fake_execute(chunk, worker):
        executed.append(chunk["chunk_id"])
        return True

    monkeypatch.setattr(job, "_execute_chunk", fake_execute)
    monkeypatch.setattr(job, "_update_master_playlist", lambda *a, **k: None)

    assert job._repair_deficient_chunks() == 3
    assert executed == [1, 2, 3], executed          # in order, one at a time
    assert len(executed) == len(set(executed))      # never twice

    executed.clear()
    assert job._repair_deficient_chunks(max_chunks=2) == 2
    assert executed == [1, 2], executed             # bounded


def test_repair_pass_does_nothing_when_frames_are_complete(temp_root, monkeypatch, tmp_path):
    from app.services import chunk_transcode_service as cts

    hls = tmp_path / "hls"
    hls.mkdir()
    media = tmp_path / "Movie.2026.mkv"
    media.write_bytes(b"x" * 1024)
    job = cts.DualGPUTranscodeJob("Movie.2026.mkv", media, hls, hls / "playlist.m3u8")
    job.total_duration = 300.0
    job.workers = [types.SimpleNamespace(name="fake-gpu", adapter_id=0)]
    monkeypatch.setattr(ts, "chunk_content_deficits", lambda *a, **k: [])
    calls = []
    monkeypatch.setattr(job, "_execute_chunk", lambda c, w: calls.append(c) or True)
    assert job._repair_deficient_chunks() == 0
    assert calls == []


def test_repair_pass_survives_a_failing_measurement(temp_root, monkeypatch, tmp_path):
    """A measurement error must never look like "everything is fine" nor crash the job."""
    from app.services import chunk_transcode_service as cts

    hls = tmp_path / "hls"
    hls.mkdir()
    media = tmp_path / "Movie.2026.mkv"
    media.write_bytes(b"x" * 1024)
    job = cts.DualGPUTranscodeJob("Movie.2026.mkv", media, hls, hls / "playlist.m3u8")
    job.total_duration = 300.0
    job.workers = [types.SimpleNamespace(name="fake-gpu", adapter_id=0)]

    def boom(*a, **k):
        raise RuntimeError("ffprobe missing")

    monkeypatch.setattr(ts, "chunk_content_deficits", boom)
    monkeypatch.setattr(job, "_execute_chunk", lambda c, w: True)
    assert job._repair_deficient_chunks() == 0   # no repair, no exception


def test_segment_indices_are_strided_per_chunk():
    """Regression: a chunk's segment indices must not overlap the next chunk's range.

    The AMF encoders do not honour a 4.0s GOP consistently (the RX 560X emits a single 60s segment
    with -g pinned), so a 60s chunk can emit 15, 16 or 1 segments against a plan of 15. With dense
    indices the overflow segment landed on the next chunk's first index and whichever render
    finished last won - 1.25s of video lost at every chunk boundary (4 of 5 chunks short in a
    synthetic 300s source; 101 chunks / 277.2s in a real cached movie).
    """
    from app.services import chunk_transcode_service as cts

    plan = cts.plan_chunks(600.0)
    assert len(plan) == 10
    starts = [c["start_seg"] for c in plan]
    assert starts == [i * cts.SEGMENTS_PER_CHUNK_STRIDE for i in range(10)], starts
    # every chunk must have room for a doubled segment count
    for c in plan:
        assert cts.SEGMENTS_PER_CHUNK_STRIDE >= c["expected_segs"] * 2, c


def test_chunk_output_ok_allows_extra_segments_inside_the_stride(temp_root, tmp_path):
    """A chunk that emits one or two extra segments is fine now - it cannot reach the next chunk."""
    from app.services import chunk_transcode_service as cts

    hls = tmp_path / "hls"
    hls.mkdir()
    media = tmp_path / "Movie.2026.mkv"
    media.write_bytes(b"x" * 1024)
    job = cts.DualGPUTranscodeJob("Movie.2026.mkv", media, hls, hls / "playlist.m3u8")
    job.total_duration = 300.0

    start_seg = 1 * cts.SEGMENTS_PER_CHUNK_STRIDE
    names = [f"segment_{start_seg + i:06d}.ts" for i in range(16)]     # 16, not 15
    for name in names:
        (hls / name).write_bytes(b"TS" * 100)
    (hls / "chunk_1.m3u8").write_text(
        "#EXTM3U\n" + "".join(f"#EXTINF:3.750000,\n{n}\n" for n in names))
    assert job._chunk_output_ok({"chunk_id": 1, "start_time": 60.0, "duration": 60.0,
                                 "start_seg": start_seg}) is True


def test_chunk_output_ok_rejects_a_chunk_that_leaves_its_stride(temp_root, tmp_path):
    from app.services import chunk_transcode_service as cts

    hls = tmp_path / "hls"
    hls.mkdir()
    media = tmp_path / "Movie.2026.mkv"
    media.write_bytes(b"x" * 1024)
    job = cts.DualGPUTranscodeJob("Movie.2026.mkv", media, hls, hls / "playlist.m3u8")
    job.total_duration = 300.0

    start_seg = 1 * cts.SEGMENTS_PER_CHUNK_STRIDE
    names = [f"segment_{start_seg + i:06d}.ts" for i in range(cts.SEGMENTS_PER_CHUNK_STRIDE + 1)]
    for name in names:
        (hls / name).write_bytes(b"TS" * 100)
    (hls / "chunk_1.m3u8").write_text(
        "#EXTM3U\n" + "".join(f"#EXTINF:1.000000,\n{n}\n" for n in names))
    assert job._chunk_output_ok({"chunk_id": 1, "start_time": 60.0, "duration": 60.0,
                                 "start_seg": start_seg}) is False


def test_legacy_dense_cache_is_cleared_before_rendering(temp_root, tmp_path):
    """A dense-grid cache cannot be resumed onto the strided grid: it must be re-rendered."""
    from app.services import chunk_transcode_service as cts

    hls = tmp_path / "hls"
    hls.mkdir()
    for i in range(30):                       # dense: 0..29
        (hls / f"segment_{i:06d}.ts").write_bytes(b"TS" * 100)
    (hls / "playlist.m3u8").write_text("#EXTM3U\n#EXTINF:4.0,\nsegment_000000.ts\n#EXT-X-ENDLIST\n")
    media = tmp_path / "Movie.2026.mkv"
    media.write_bytes(b"x" * 1024)
    job = cts.DualGPUTranscodeJob("Movie.2026.mkv", media, hls, hls / "playlist.m3u8")

    assert job._prepare_cache_layout() is True
    assert not list(hls.glob("segment_*.ts"))
    assert not (hls / "playlist.m3u8").exists()
    assert (hls / ".seg_layout").read_text().strip() == "stride32"
    # and a strided cache is left alone
    (hls / f"segment_{cts.SEGMENTS_PER_CHUNK_STRIDE:06d}.ts").write_bytes(b"TS")
    assert job._prepare_cache_layout() is True
    assert hls.glob("segment_*.ts")

def test_chunk_frame_accounting_counts_the_chunks_own_segment_run(temp_root, monkeypatch, tmp_path):
    """A chunk that emits 16 segments is complete, not 1.25s short.

    The plan expects 15 segments per 60s chunk but the muxer splits on the encoder's keyframes, so
    a chunk can legitimately write 15, 16 or 17. Measuring only the planned 15 made a complete
    chunk look short (and would have re-rendered every chunk of a healthy movie forever).
    """
    from app.services import chunk_transcode_service as cts

    hls = tmp_path / "hls"
    hls.mkdir()
    plan = cts.plan_chunks(60.0)
    first = plan[0]
    # 16 segments, every one a full 4s (96 frames at 24fps) - the real shape of a healthy chunk
    for i in range(first["start_seg"], first["start_seg"] + 16):
        (hls / f"segment_{i:06d}.ts").write_bytes(b"x" * 2048)
    monkeypatch.setattr(ts, "measure_segment_frame_count", lambda path: 96)
    monkeypatch.setattr(ts, "source_frame_rate", lambda p: 24.0)

    assert ts.chunk_content_deficits(hls, 60.0, source_path=tmp_path / "Source.mkv") == []


def test_chunk_frame_accounting_still_flags_a_real_shortfall(temp_root, monkeypatch, tmp_path):
    from app.services import chunk_transcode_service as cts

    hls = tmp_path / "hls"
    hls.mkdir()
    from app.services.chunk_transcode_service import HLS_LAYOUT_MARKER, HLS_LAYOUT_STRIDE
    (hls / HLS_LAYOUT_MARKER).write_text(HLS_LAYOUT_STRIDE)
    first = cts.plan_chunks(60.0)[0]
    for i in range(first["start_seg"], first["start_seg"] + 16):
        (hls / f"segment_{i:06d}.ts").write_bytes(b"x" * 2048)
    # every segment holds only 2s of video: 32s of a 60s window
    monkeypatch.setattr(ts, "measure_segment_frame_count", lambda path: 48)
    monkeypatch.setattr(ts, "source_frame_rate", lambda p: 24.0)
    deficits = ts.chunk_content_deficits(hls, 60.0, source_path=tmp_path / "Source.mkv")
    assert [d["chunk_id"] for d in deficits] == [0]
    assert deficits[0]["missing_s"] == 28.0

def test_dense_cache_is_migrated_onto_the_strided_grid_without_re_encoding(temp_root, tmp_path):
    """An intact dense cache is renumbered, not re-rendered.

    Nine of the ten live caches emitted exactly 15 segments per chunk, so their indices are
    contiguous and unambiguous - only the numbering predates the stride. Renaming preserves hours
    of GPU work; the honest labels and the mastered ENDLIST must survive.
    """
    from app.services import chunk_transcode_service as cts

    hls = tmp_path / "hls"
    hls.mkdir()
    stride = cts.SEGMENTS_PER_CHUNK_STRIDE
    for i in range(30):                      # dense: 0..29 = chunk 0 (15) + chunk 1 (15)
        (hls / f"segment_{i:06d}.ts").write_bytes(b"SEGMENT" * 10)
    for cid, base in ((0, 0), (1, 15)):
        body = "#EXTM3U\n"
        for k in range(15):
            body += f"#EXTINF:3.880000,\nsegment_{base + k:06d}.ts\n"
        (hls / f"chunk_{cid}.m3u8").write_text(body)
    (hls / "playlist.m3u8").write_text(
        "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n"
        + "".join(f"#EXTINF:3.880000,\nsegment_{i:06d}.ts\n" for i in range(30))
        + "#EXT-X-ENDLIST\n")

    job = cts.DualGPUTranscodeJob("Movie.2026.mkv", tmp_path / "Movie.2026.mkv", hls, hls / "playlist.m3u8")
    assert job._prepare_cache_layout() is True

    names = sorted(p.name for p in hls.glob("segment_*.ts"))
    assert len(names) == 30, names                      # nothing lost
    assert names == [f"segment_{i:06d}.ts" for i in range(15)] + \
                    [f"segment_{stride + i:06d}.ts" for i in range(15)], names
    assert (hls / ".seg_layout").read_text().strip() == "stride32"
    # chunk playlists and the served master keep their labels and follow the new names
    chunk1 = (hls / "chunk_1.m3u8").read_text()
    assert f"segment_{stride:06d}.ts" in chunk1 and "#EXTINF:3.880000," in chunk1
    master = (hls / "playlist.m3u8").read_text()
    assert f"segment_{stride:06d}.ts" in master and "#EXT-X-ENDLIST" in master
    assert "segment_000015.ts" not in master


def test_overlapping_dense_cache_is_cleared_for_re_render(temp_root, tmp_path):
    """Where two chunks claim the same index, one chunk's content is already gone: re-render."""
    from app.services import chunk_transcode_service as cts

    hls = tmp_path / "hls"
    hls.mkdir()
    for i in range(31):                      # chunk 0 wrote 16, chunk 1 starts at 15 -> overlap
        (hls / f"segment_{i:06d}.ts").write_bytes(b"SEGMENT" * 10)
    for cid, base, n in ((0, 0, 16), (1, 15, 16)):
        body = "#EXTM3U\n"
        for k in range(n):
            body += f"#EXTINF:3.750000,\nsegment_{base + k:06d}.ts\n"
        (hls / f"chunk_{cid}.m3u8").write_text(body)

    job = cts.DualGPUTranscodeJob("Movie.2026.mkv", tmp_path / "Movie.2026.mkv", hls, hls / "playlist.m3u8")
    assert job._prepare_cache_layout() is True
    assert not list(hls.glob("segment_*.ts"))
    assert (hls / ".seg_layout").read_text().strip() == "stride32"


def test_deficit_detection_ignores_dense_cache_windows(temp_root, monkeypatch, tmp_path):
    """A legacy dense cache whose chunks matched the plan is complete, not deficient.

    The live regression: the maintenance audit walked strided windows on a dense cache, read a
    neighbour's segments (or the near-empty tail of the numbering), and stripped ENDLIST from
    three complete 100-minute caches reporting 38.5s / 24.2s / 13.7s of "missing" video.
    """
    import app.services.transcode_service as ts

    hls = tmp_path / "hls"
    hls.mkdir()
    total = 300.0                                    # 5 chunks planned
    # dense numbering: chunk n owns segments 15n..15n+14, exactly the planned count
    for i in range(75):
        (hls / f"segment_{i:06d}.ts").write_bytes(b"x")
    monkeypatch.setattr(ts, "measure_segment_frame_count", lambda p: 96)
    monkeypatch.setattr(ts, "source_frame_rate", lambda p: 24.0)
    assert ts.chunk_content_deficits(hls, total, source_path="src.mkv") == []


def test_deficit_detection_flags_dense_cache_missing_content(temp_root, monkeypatch, tmp_path):
    """A dense cache that really lost content is still caught - as one aggregate entry."""
    import app.services.transcode_service as ts

    hls = tmp_path / "hls"
    hls.mkdir()
    total = 300.0
    for i in range(75):
        (hls / f"segment_{i:06d}.ts").write_bytes(b"x")
    # 15 segments worth of frames missing: 7200 expected, 5760 found
    calls = {"n": 0}

    def frames(path):
        calls["n"] += 1
        return 96 if calls["n"] <= 60 else 0

    monkeypatch.setattr(ts, "measure_segment_frame_count", frames)
    monkeypatch.setattr(ts, "source_frame_rate", lambda p: 24.0)
    deficits = ts.chunk_content_deficits(hls, total, source_path="src.mkv")
    assert len(deficits) == 1
    assert deficits[0]["chunk_id"] == -1             # aggregate, not a per-chunk window
    assert deficits[0]["legacy_layout"] is True
    assert deficits[0]["missing_s"] > 50


def test_dense_cache_tolerance_catches_a_small_real_hole(temp_root, monkeypatch, tmp_path):
    """A hole too small for the old 1.5%-of-a-feature rule must still be caught.

    On a 2h movie 1.5% is two minutes: a single destroyed chunk boundary (~2s, and the live
    damage ran to 277s) has to trip the audit, while encoder rounding must not.
    """
    import app.services.transcode_service as ts

    hls = tmp_path / "hls"
    hls.mkdir()
    total = 8183.8                                   # a feature-length dense cache
    for i in range(2046):
        (hls / f"segment_{i:06d}.ts").write_bytes(b"x")
    # 100s of frames genuinely missing (1.2% of the feature): under the old rule this passed
    per_seg = int(8183.8 * 25 / 2046)
    lost = int(100 * 25)
    calls = {"n": 0}

    def frames(path):
        calls["n"] += 1
        if calls["n"] <= lost // per_seg:
            return per_seg
        return 0

    monkeypatch.setattr(ts, "measure_segment_frame_count", frames)
    monkeypatch.setattr(ts, "source_frame_rate", lambda p: 25.0)
    deficits = ts.chunk_content_deficits(hls, total, source_path="src.mkv")
    assert len(deficits) == 1 and deficits[0]["missing_s"] > 50, deficits


def test_dense_cache_tolerance_ignores_encoder_rounding(temp_root, monkeypatch, tmp_path):
    """A handful of dropped frames across a feature is not content loss."""
    import app.services.transcode_service as ts

    hls = tmp_path / "hls"
    hls.mkdir()
    total = 8184.0                                   # 2046 segments x 100 frames at 25fps, exact
    for i in range(2046):
        (hls / f"segment_{i:06d}.ts").write_bytes(b"x")
    # every 50th segment drops one frame: 40 frames = 1.6s total, well inside the tolerance
    monkeypatch.setattr(ts, "measure_segment_frame_count",
                        lambda p: 100 - (1 if int(Path(p).name[8:14]) % 50 == 0 else 0))
    monkeypatch.setattr(ts, "source_frame_rate", lambda p: 25.0)
    assert ts.chunk_content_deficits(hls, total, source_path="src.mkv") == []


def test_deficit_detection_uses_per_chunk_windows_when_strided(temp_root, monkeypatch, tmp_path):
    """On the strided grid the per-chunk window is exact - keep reporting the chunk id."""
    import app.services.transcode_service as ts
    from app.services.chunk_transcode_service import HLS_LAYOUT_MARKER, HLS_LAYOUT_STRIDE

    hls = tmp_path / "hls"
    hls.mkdir()
    (hls / HLS_LAYOUT_MARKER).write_text(HLS_LAYOUT_STRIDE)
    total = 120.0                                    # 2 chunks
    for i in range(1 * 32, 1 * 32 + 15):              # chunk 1 rendered, chunk 0 never did
        (hls / f"segment_{i:06d}.ts").write_bytes(b"x")
    monkeypatch.setattr(ts, "measure_segment_frame_count", lambda p: 96)
    monkeypatch.setattr(ts, "source_frame_rate", lambda p: 24.0)
    assert ts.chunk_content_deficits(hls, total, source_path="src.mkv") == []
