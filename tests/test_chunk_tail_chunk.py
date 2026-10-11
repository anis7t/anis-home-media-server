"""A zero-frame tail chunk must never be planned, and must never retire a GPU worker.

Defect (2026-10-11): when a source duration divides (near-)exactly, float residue makes
``plan_chunks`` emit a final chunk whose ``duration`` is ~1e-13s. ``expected_segs`` is
``max(1, ...)``, so that unrenderable window still claims one segment; ``_chunk_output_ok`` then
fails it, and the caller retires the worker for the job. The cascade happens at the very END of a
run - after all real work is done - so a healthy transcode sealed ENDLIST with zero deficits while
logging alarming "GPU worker ... retiring it for this job" lines. In the worst case the last
chunk cannot be produced by any healthy worker and the job aborts.

The fix is in ``plan_chunks`` (the defect is upstream); ``_chunk_output_ok`` carries a companion
guard. The index-stability assertions here are the safety-critical part: dropping the tail must
not move any segment index, because ``start_seg = chunk_id * SEGMENTS_PER_CHUNK_STRIDE`` is the
property that stops chunks overwriting each other (AGENTS.md: real past data loss).
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.services import chunk_transcode_service as cts  # noqa: E402


# Durations that produced a degenerate tail before the fix, together with real feature lengths.
# The jitters are the float residues an ffprobe-reported duration actually arrives with.
RESIDUE_CASES = [
    (60.000000001, 60.0), (60.0000000000002, 60.0), (60.000000000000014, 60.0),
    (120.000000001, 120.0), (180.0000000000002, 180.0), (600.000000001, 600.0),
    (600.0000000000002, 600.0), (1200.000000001, 1200.0), (1800.000000001, 1800.0),
    (3600.000000001, 3600.0), (7200.000000001, 7200.0), (11808.000000001, 11808.0),
]


def _structural(plan):
    """The fields the strided layout is built from, ignoring the duration value itself."""
    return [(c["chunk_id"], c["start_time"], c["start_seg"]) for c in plan]


# --------------------------------------------------------------------------
# 1. The exact-multiple case: N chunks, no tail.
# --------------------------------------------------------------------------

@pytest.mark.parametrize("total,expected_chunks", [
    (60.0, 1), (120.0, 2), (180.0, 3), (600.0, 10), (3600.0, 60),
])
def test_exact_multiple_plans_exactly_n_chunks_and_no_tail(total, expected_chunks):
    """A duration that divides exactly into 60s chunks plans exactly N chunks, all full-size."""
    plan = cts.plan_chunks(total)

    assert len(plan) == expected_chunks, plan
    assert all(c["duration"] == 60.0 for c in plan), plan
    # The residue this defect came from must not reappear at the end.
    assert plan[-1]["duration"] >= cts.MIN_PLANNABLE_CHUNK_SECONDS


def test_exact_multiple_never_emits_a_zero_length_chunk():
    """The specific regression: N chunks, none of them degenerate."""
    plan = cts.plan_chunks(600.0)

    assert len(plan) == 10
    assert min(c["duration"] for c in plan) >= cts.MIN_PLANNABLE_CHUNK_SECONDS
    assert not any(c["duration"] <= 0.0 for c in plan)


# --------------------------------------------------------------------------
# 2. Float-residue cases: the degenerate tail is gone, indices are unmoved.
# --------------------------------------------------------------------------

@pytest.mark.parametrize("residued,clean", RESIDUE_CASES)
def test_float_residue_does_not_emit_a_degenerate_tail(residued, clean):
    """The exact durations that used to append an ~1e-13s tail chunk no longer do."""
    plan = cts.plan_chunks(residued)

    assert plan, "a 60s+ source must still plan chunks"
    assert min(c["duration"] for c in plan) >= cts.MIN_PLANNABLE_CHUNK_SECONDS, plan
    assert not any(c["duration"] <= 0.0 for c in plan), plan


@pytest.mark.parametrize("residued,clean", RESIDUE_CASES)
def test_float_residue_does_not_shift_any_segment_index(residued, clean):
    """SAFETY-CRITICAL: the tail is always last, so dropping it moves no existing index.

    An off-by-one here would shift every subsequent chunk's segment range and corrupt the strided
    layout - the property AGENTS.md records as the cause of real past data loss.
    """
    assert _structural(cts.plan_chunks(residued)) == _structural(cts.plan_chunks(clean))


def test_dropping_the_tail_keeps_chunk_ids_contiguous_and_indices_on_the_stride():
    """Chunk ids stay 0..N-1 and start_seg stays chunk_id * SEGMENTS_PER_CHUNK_STRIDE."""
    for residued, clean in RESIDUE_CASES:
        plan = cts.plan_chunks(residued)
        assert [c["chunk_id"] for c in plan] == list(range(len(plan))), residued
        assert [c["start_seg"] for c in plan] == [
            i * cts.SEGMENTS_PER_CHUNK_STRIDE for i in range(len(plan))
        ], residued


def test_a_residue_bearing_source_plans_structurally_like_the_clean_source():
    """Whole-plan structural identity, and the residue is absorbed by the last REAL chunk.

    The 1ns of residue does not disappear: it lands in the final genuine chunk's duration
    (48.000000001 rather than 48.0), so coverage stays exact and no phantom chunk appears.
    """
    for residued, clean in RESIDUE_CASES:
        assert _structural(cts.plan_chunks(residued)) == _structural(cts.plan_chunks(clean)), residued
        # Coverage is preserved to within the jitter, not silently truncated.
        assert sum(c["duration"] for c in cts.plan_chunks(residued)) == pytest.approx(
            residued, abs=1e-6), residued


def test_no_planned_chunk_anywhere_is_below_the_zero_frame_threshold():
    """Broad sweep: every chunk of every plan is renderable in principle."""
    for n in range(1, 181):
        for base in (60.0, 600.0, 3600.0, 11808.0, 6721.6, 59.94, 7200.0):
            total = base * n
            if total > 20000:
                continue
            for jitter in (0, 1e-9, -1e-9, 2e-13, -2e-13, 1.4e-14, -1.4e-14):
                dur = total + jitter
                if dur <= 0:
                    continue
                for c in cts.plan_chunks(dur):
                    assert c["duration"] >= cts.MIN_PLANNABLE_CHUNK_SECONDS, (dur, c)


# --------------------------------------------------------------------------
# 3. Genuine fractional tails are preserved - the fix must not eat content.
# --------------------------------------------------------------------------

@pytest.mark.parametrize("total,tail", [
    (150.0, 30.0),      # 2.5 x 60s
    (125.5, 5.5),       # sub-chunk tail
    (6721.6, 1.6),      # real measured feature length (Teenage Sex and Death at Camp Miasma)
    (179.25, 59.25),
    (1254.999, 54.999), # tail just under a chunk
])
def test_genuine_fractional_tail_is_still_planned(total, tail):
    """A real fractional tail must survive - this is the content-loss risk of a magic epsilon."""
    plan = cts.plan_chunks(total)

    assert plan[-1]["duration"] == pytest.approx(tail), plan[-1]
    assert plan[-1]["duration"] >= cts.MIN_PLANNABLE_CHUNK_SECONDS


@pytest.mark.parametrize("total", [150.0, 125.5, 6721.6, 179.25, 1254.999, 600.5])
def test_chunks_still_cover_the_whole_source(total):
    """Coverage is exact: the sum of the planned windows is the source duration.

    This is the assertion that would catch an over-large threshold silently truncating a tail.
    """
    plan = cts.plan_chunks(total)
    assert sum(c["duration"] for c in plan) == pytest.approx(total, abs=1e-6), plan


def test_the_threshold_does_not_swallow_a_short_but_real_tail():
    """A 0.5s tail is one real window; a 1ms threshold keeps it and a 0.5s one would not.

    Documents *why* the constant is 1e-3 and not something rounder: at 120fps one frame is 8.3ms,
    so any window under ~1ms is provably frame-free at every rate - but 0.5s is 60 frames of real
    video and dropping it would be silent content loss.
    """
    assert cts.MIN_PLANNABLE_CHUNK_SECONDS <= 1.0 / 120.0
    assert cts.MIN_PLANNABLE_CHUNK_SECONDS < 0.5

    plan = cts.plan_chunks(120.5)
    assert len(plan) == 3, plan
    assert plan[-1]["duration"] == pytest.approx(0.5), plan[-1]


def test_expected_segs_of_a_dropped_tail_is_the_reason_the_worker_was_retired():
    """Why this mattered: a ~0s window still claimed a segment, so no render could satisfy it."""
    residue = 600.0000000000002
    plan = cts.plan_chunks(residue)

    # Pre-fix behaviour, reconstructed: the 11th chunk existed with duration ~2e-13 and
    # expected_segs == 1 (from max(1, round(dur / 4.0))), which _chunk_output_ok must fail.
    assert len(plan) == 10
    assert max(c["expected_segs"] for c in plan) == 15
    assert all(c["expected_segs"] >= 1 for c in plan)


# --------------------------------------------------------------------------
# 4. The companion guard in _chunk_output_ok.
# --------------------------------------------------------------------------

def _job(tmp_path):
    hls = tmp_path / "hls"
    hls.mkdir()
    media = tmp_path / "Movie.2026.mkv"
    media.write_bytes(b"x" * 1024)
    job = cts.DualGPUTranscodeJob("Movie.2026.mkv", media, hls, hls / "playlist.m3u8")
    job.total_duration = 300.0
    return job, hls


def test_companion_guard_does_not_retire_a_worker_for_a_zero_frame_window(tmp_path):
    """A zero-length render of a sub-millisecond window is not a GPU fault.

    Unreachable through plan_chunks now, which is the point of it being a companion: if a
    degenerate chunk ever reaches the check by another route, judging nothing is correct, because
    the window cannot hold a frame to lose.
    """
    job, hls = _job(tmp_path)
    (hls / "chunk_1.m3u8").write_text(
        "#EXTM3U\n#EXTINF:0.000000,\nsegment_000032.ts\n", encoding="utf-8")

    assert job._chunk_output_ok({
        "chunk_id": 1, "start_time": 60.0, "duration": 2.2737367544323206e-13,
        "start_seg": 32, "expected_segs": 1,
    }) is True


def test_companion_guard_does_not_weaken_the_real_yield_check(tmp_path):
    """A sub-millisecond window is excused; a normal one that renders nothing is still a failure.

    Without this the guard would be an open door - the exact failure it exists to contain.
    """
    job, hls = _job(tmp_path)
    (hls / "chunk_1.m3u8").write_text(
        "#EXTM3U\n#EXTINF:0.000000,\nsegment_000032.ts\n", encoding="utf-8")

    assert job._chunk_output_ok({
        "chunk_id": 1, "start_time": 60.0, "duration": 60.0,
        "start_seg": 32, "expected_segs": 15,
    }) is False


def test_companion_guard_keeps_the_healthy_full_yield_path(tmp_path):
    """Sanity: a healthy 60s chunk still passes."""
    job, hls = _job(tmp_path)
    (hls / "chunk_1.m3u8").write_text(
        "#EXTM3U\n#EXT-X-VERSION:3\n" + "".join(
            f"#EXTINF:4.000000,\nsegment_{32 + i:06d}.ts\n" for i in range(15)
        ), encoding="utf-8")

    assert job._chunk_output_ok({
        "chunk_id": 1, "start_time": 60.0, "duration": 60.0,
        "start_seg": 32, "expected_segs": 15,
    }) is True


# --------------------------------------------------------------------------
# 5. Downstream consumers see a consistent plan.
# --------------------------------------------------------------------------

def test_master_playlist_discontinuities_exclude_the_dropped_tail(tmp_path):
    """_update_master_playlist derives chunk boundaries from plan_chunks; no phantom boundary."""
    job, hls = _job(tmp_path)
    job.total_duration = 600.0000000000002

    boundaries = {c["start_seg"] for c in cts.plan_chunks(job.total_duration) if c["chunk_id"] > 0}
    clean = {c["start_seg"] for c in cts.plan_chunks(600.0) if c["chunk_id"] > 0}
    assert boundaries == clean
    assert len(boundaries) == 9          # 10 chunks -> 9 interior boundaries, not 10
    assert 10 * cts.SEGMENTS_PER_CHUNK_STRIDE not in boundaries
