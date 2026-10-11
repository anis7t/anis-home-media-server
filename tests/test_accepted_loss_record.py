"""`_record_accepted_loss` must actually write hls.loss.json.

Defect (pre-existing on main, found 2026-10-11 while verifying the tail-chunk fix):
`_record_accepted_loss` called `chunk_content_deficits` with **no import in its scope**, while its
three sibling call sites each do a function-local import (a module-level one would be circular,
since transcode_service imports from chunk_transcode_service). The resulting NameError was
swallowed by a broad `except` logged at `debug`, so the accepted-shortfall record AGENTS.md
documents was **never written**.

That is worse than a missing feature: "no hls.loss.json" is used as an acceptance signal, and a
broken recorder makes a clean cache indistinguishable from a short one. These tests pin that the
name resolves, that the file appears with every documented field, and - the part that would have
caught the original defect - that no NameError is being silently absorbed.
"""
import json
import logging
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.services import chunk_transcode_service as cts  # noqa: E402
from app.services import transcode_service as ts  # noqa: E402


def _job(tmp_path, name="Movie.2026.mkv"):
    hls = tmp_path / "hls"
    hls.mkdir()
    media = tmp_path / name
    media.write_bytes(b"x" * 1024)
    job = cts.DualGPUTranscodeJob(name, media, hls, hls / "playlist.m3u8")
    job.total_duration = 600.0
    return job, hls


def _stub_deficits(monkeypatch, reported):
    """Replace the accounting with a stub that reports *reported* and flags no chunk.

    The keyword is named `totals` because that is what the caller passes. A stub using any other
    name raises TypeError, which the blanket `except` absorbs silently - a trap worth naming.
    """
    def fake(hls_dir, total_duration, source_path=None, chunk_ids=None, totals=None):
        if totals is not None:
            totals.update(reported)
        return []
    monkeypatch.setattr(ts, "chunk_content_deficits", fake)


# The Project.Hail.Mary reference figures: 133 frames of accepted priming loss over 157 chunks.
HAIL_MARY_TOTALS = {
    "frames_expected": 226080, "frames_found": 225947, "missing_frames": 133,
    "missing_s": 5.54, "chunks_measured": 157, "fps": 24.0,
    "per_chunk_tolerance_frames": 17, "aggregate_ceiling_frames": 360,
}


# --------------------------------------------------------------------------
# The regression itself.
# --------------------------------------------------------------------------

def test_the_accounting_name_resolves_without_a_nameerror(tmp_path, monkeypatch, caplog):
    """THE regression: the call must not raise NameError and quietly write nothing.

    Asserted on the log, not on the return value, because the defect was invisible by design - the
    broad `except` swallowed it at `debug` and the method returned None exactly as it would have on
    success.
    """
    job, hls = _job(tmp_path)
    _stub_deficits(monkeypatch, HAIL_MARY_TOTALS)

    with caplog.at_level(logging.DEBUG, logger="app.services.chunk_transcode_service"):
        job._record_accepted_loss([])

    swallowed = [r.getMessage() for r in caplog.records
                 if "Could not record accepted loss" in r.getMessage()]
    assert not swallowed, f"accounting failed silently: {swallowed}"
    assert (hls / "hls.loss.json").is_file(), "the record was not written"


def test_accepted_loss_is_written_with_every_documented_field(tmp_path, monkeypatch):
    """AGENTS.md promises frames, seconds, chunks, both thresholds, timestamp and reason."""
    job, hls = _job(tmp_path)
    _stub_deficits(monkeypatch, HAIL_MARY_TOTALS)

    job._record_accepted_loss([])

    data = json.loads((hls / "hls.loss.json").read_text(encoding="utf-8"))
    assert data["media"] == "Movie.2026.mkv"
    assert data["missing_frames"] == 133
    # missing_s is RECOMPUTED from missing_frames / fps, not copied from the totals dict.
    assert data["missing_s"] == round(133 / 24.0, 3), data["missing_s"]
    assert data["chunks_measured"] == 157
    assert data["per_chunk_tolerance_frames"] == 17
    assert data["aggregate_ceiling_frames"] == 360
    assert data["reason"]
    assert data["recorded_utc"]


def test_the_record_announces_itself_at_info_level(tmp_path, monkeypatch, caplog):
    """A silent recorder is how this hid for so long; the write is logged at INFO."""
    job, hls = _job(tmp_path)
    _stub_deficits(monkeypatch, HAIL_MARY_TOTALS)

    with caplog.at_level(logging.INFO, logger="app.services.chunk_transcode_service"):
        job._record_accepted_loss([])

    assert any("hls.loss.json" in r.getMessage() for r in caplog.records), \
        [r.getMessage() for r in caplog.records]


# --------------------------------------------------------------------------
# It must not over-report.
# --------------------------------------------------------------------------

def test_a_clean_cache_writes_no_loss_file(tmp_path, monkeypatch):
    """Zero missing frames means nothing to record - the file must not appear."""
    job, hls = _job(tmp_path)
    _stub_deficits(monkeypatch, {
        "missing_frames": 0, "missing_s": 0.0, "chunks_measured": 10, "fps": 24.0,
        "per_chunk_tolerance_frames": 17, "aggregate_ceiling_frames": 36,
    })

    job._record_accepted_loss([])

    assert not (hls / "hls.loss.json").exists()


def test_a_negative_measurement_writes_no_loss_file(tmp_path, monkeypatch):
    """A rounding SURPLUS (negative missing frames) is not a loss - missing_frames <= 0 is the
    criterion, so a surplus must not produce a loss record."""
    job, hls = _job(tmp_path)
    _stub_deficits(monkeypatch, {
        "missing_frames": -4, "missing_s": -0.17, "chunks_measured": 10, "fps": 24.0,
        "per_chunk_tolerance_frames": 17, "aggregate_ceiling_frames": 36,
    })

    job._record_accepted_loss([])

    assert not (hls / "hls.loss.json").exists()


# --------------------------------------------------------------------------
# Accounting must never break sealing.
# --------------------------------------------------------------------------

def test_an_accounting_failure_does_not_propagate(tmp_path, monkeypatch, caplog):
    """Sealing is more important than the record; a raise here must not stop ENDLIST."""
    job, hls = _job(tmp_path)

    def boom(*a, **kw):
        raise RuntimeError("simulated accounting failure")

    monkeypatch.setattr(ts, "chunk_content_deficits", boom)

    with caplog.at_level(logging.DEBUG, logger="app.services.chunk_transcode_service"):
        job._record_accepted_loss([])      # must not raise

    assert not (hls / "hls.loss.json").exists()
    assert any("Could not record accepted loss" in r.getMessage() for r in caplog.records)


def test_a_nested_missing_dependency_would_still_be_swallowed(tmp_path, monkeypatch):
    """Documents the residual risk honestly: the broad `except` still catches everything.

    The NameError class of bug is now impossible (the name is imported in scope and pinned by
    test_the_accounting_name_resolves_without_a_nameerror), but the blanket except means a future
    typo would still fail quietly. This test records that trade-off rather than hiding it.
    """
    job, hls = _job(tmp_path)

    def raises_type_error(*a, **kw):
        raise TypeError("simulated typo in a totals key")

    monkeypatch.setattr(ts, "chunk_content_deficits", raises_type_error)
    job._record_accepted_loss([])          # must not raise

    assert not (hls / "hls.loss.json").exists()


# --------------------------------------------------------------------------
# The call site is only reachable when nothing was flagged.
# --------------------------------------------------------------------------

def test_finalize_records_accepted_loss_when_no_chunk_is_flagged(tmp_path, monkeypatch):
    """The end-to-end path: a cache within tolerance but short overall is sealed AND recorded.

    This is the state the record exists for - every chunk inside its boundary allowance, the cache
    as a whole a little short. It must still write hls.loss.json.
    """
    job, hls = _job(tmp_path)
    (hls / "segment_000000.ts").write_bytes(b"TS" * 200)

    _stub_deficits(monkeypatch, HAIL_MARY_TOTALS)
    monkeypatch.setattr(cts.DualGPUTranscodeJob, "_measure_coverage",
                        lambda self: (600.0, True, 1.0))
    monkeypatch.setattr(cts.DualGPUTranscodeJob, "_update_master_playlist",
                        lambda self, is_complete=False: None)

    job._finalize()

    assert job._returncode == 0, "a cache inside the ceiling must seal"
    assert (hls / "hls.loss.json").is_file(), "sealing without recording the shortfall"


def test_finalize_does_not_record_when_a_chunk_was_flagged(tmp_path, monkeypatch):
    """A flagged chunk means the cache is re-rendered, not sealed - nothing is 'accepted'."""
    job, hls = _job(tmp_path)
    (hls / "segment_000000.ts").write_bytes(b"TS" * 200)

    def flagged(hls_dir, total_duration, source_path=None, chunk_ids=None, totals_out=None):
        return [{"chunk_id": 3, "start": 180.0, "expected_frames": 1440, "frames": 1200,
                 "missing_frames": 240, "missing_s": 10.0}]

    monkeypatch.setattr(ts, "chunk_content_deficits", flagged)
    monkeypatch.setattr(cts.DualGPUTranscodeJob, "_measure_coverage",
                        lambda self: (600.0, True, 1.0))
    monkeypatch.setattr(cts.DualGPUTranscodeJob, "_update_master_playlist",
                        lambda self, is_complete=False: None)

    job._finalize()

    assert not (hls / "hls.loss.json").exists()
