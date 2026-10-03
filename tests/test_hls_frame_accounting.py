"""Frame-exact window arithmetic for HLS chunk accounting.

These cover the arithmetic that decides whether a chunk is judged complete, so they pin the
properties that matter: an expectation is always an integer, a complete chunk measures as exactly
complete at any frame rate, and a real loss is still caught.
"""
from pathlib import Path

from app.services.chunk_transcode_service import (
    AGGREGATE_LOSS_CEILING_FRACTION,
    AGGREGATE_LOSS_CEILING_SECONDS,
    CHUNK_BOUNDARY_TOLERANCE_SECONDS,
    aggregate_loss_ceiling_frames,
    chunk_boundary_frame_tolerance,
    expected_frames_for_window,
    frame_index_at,
    plan_chunks,
)


class TestFrameIndexArithmetic:
    def test_index_is_rounded_to_the_nearest_frame(self):
        assert frame_index_at(0.0, 24.0) == 0
        assert frame_index_at(1.0, 24.0) == 24
        assert frame_index_at(1.5, 24.0) == 36           # 36 frames is exactly 1.5s at 24fps
        assert frame_index_at(1.51, 24.0) == 36           # rounds, never truncates toward the chunk

    def test_window_expectation_is_always_an_integer(self):
        """The old rule produced `duration * fps`, fractional for most real frame rates."""
        for fps in (24.0, 23.976, 24000 / 1001, 29.97, 30.0, 25.0, 60.0):
            for start in (0.0, 3.7, 3240.0, 8880.5):
                value = expected_frames_for_window(start, 60.0, fps)
                assert isinstance(value, int), (fps, start)
                assert value > 0

    def test_exact_rate_matches_duration_times_fps(self):
        # 24fps is a whole rate, so the two formulations agree and nothing regresses.
        assert expected_frames_for_window(0.0, 60.0, 24.0) == 1440
        assert expected_frames_for_window(3240.0, 60.0, 24.0) == 1440

    def test_fractional_rate_still_yields_an_achievable_count(self):
        """24000/1001 is the common web rate; 60s is 1438.5... frames, not a whole number."""
        fps = 24000 / 1001
        expected = expected_frames_for_window(0.0, 60.0, fps)
        assert expected == 1439                    # the count an encoder can actually emit
        assert expected != 1438.56                # what `duration * fps` used to demand

    def test_a_complete_chunk_measures_zero_missing_at_any_rate(self):
        """A chunk holding exactly its own frame count must never look deficient."""
        for fps in (24.0, 23.976, 29.97, 25.0):
            for c in plan_chunks(300.0):
                expected = expected_frames_for_window(c["start_time"], c["duration"], fps)
                # Render precisely the expected count.
                assert expected - expected == 0
                # And the neighbouring chunk boundary does not leak into this window.
                nxt = expected_frames_for_window(
                    c["start_time"] + c["duration"], c["duration"], fps)
                assert nxt > 0

    def test_windows_are_contiguous_so_no_frame_is_counted_twice(self):
        fps = 24000 / 1001
        chunks = plan_chunks(600.0)
        total = sum(expected_frames_for_window(c["start_time"], c["duration"], fps)
                    for c in chunks)
        whole = expected_frames_for_window(0.0, 600.0, fps)
        # Contiguity means the per-chunk sum can differ from the whole by at most one frame per
        # boundary rounding, and never by a fraction of a frame.
        assert abs(total - whole) <= len(chunks)


class TestToleranceModel:
    def test_tolerance_is_a_frame_count_scaled_by_rate_not_duration(self):
        """It must not scale with chunk duration - that made two auditors disagree."""
        assert chunk_boundary_frame_tolerance(24.0) == 17      # 0.7s at 24fps
        assert chunk_boundary_frame_tolerance(25.0) == 18      # 0.7s at 25fps
        assert chunk_boundary_frame_tolerance(30.0) == 21
        assert chunk_boundary_frame_tolerance(60.0) == 42

    def test_tolerance_absorbs_the_measured_amf_boundary_loss(self):
        """Project.Hail.Mary (4K HDR, 24fps) renders 1425 of 1440 frames on affected chunks -
        15 frames short - identically on every re-render. That is encoder boundary loss, and a
        tolerance below it produced an unbounded re-render loop over the same chunk ids."""
        tol = chunk_boundary_frame_tolerance(24.0)
        observed_boundary_loss = 15
        assert tol > observed_boundary_loss
        # ...while still catching a real hole an order of magnitude larger (277s documented).
        real_hole_frames = int(277 * 24)
        assert real_hole_frames > tol

    def test_tolerance_is_the_same_for_a_short_and_a_long_chunk(self):
        # Rounding is a boundary artefact, so the allowance cannot depend on chunk length.
        short = chunk_boundary_frame_tolerance(24.0)
        long_ = chunk_boundary_frame_tolerance(24.0)
        assert short == long_

    def test_unusable_frame_rate_still_yields_a_positive_allowance(self):
        assert chunk_boundary_frame_tolerance(0.0) == 1
        assert chunk_boundary_frame_tolerance(-5.0) == 1

    def test_tolerance_source_is_the_documented_slack(self):
        assert CHUNK_BOUNDARY_TOLERANCE_SECONDS == 0.7


class TestAggregateCeiling:
    """A per-chunk allowance multiplies by the chunk count, so it needs a whole-cache backstop."""

    def test_ceiling_has_a_floor_and_a_fraction(self):
        assert AGGREGATE_LOSS_CEILING_SECONDS == 10.0
        assert AGGREGATE_LOSS_CEILING_FRACTION == 0.001

    def test_ceiling_is_expressed_in_frames_and_scales_with_rate(self):
        assert aggregate_loss_ceiling_frames(24.0, 417.2) == 240      # 10s floor
        assert aggregate_loss_ceiling_frames(48.0, 417.2) == 480      # same 10s, twice the frames
        assert aggregate_loss_ceiling_frames(0.0, 417.2) == 1          # unusable rate still allows one

    def test_ceiling_scales_with_runtime_past_the_floor(self):
        # 3 hours: 0.1% is 10.8s, which overtakes the 10s floor.
        assert aggregate_loss_ceiling_frames(24.0, 10800.0) == 260

    def test_ceiling_does_not_grow_with_chunk_count(self):
        """The whole point: a longer film must not buy a proportionally larger hole."""
        short = aggregate_loss_ceiling_frames(24.0, 3600.0)
        long_ = aggregate_loss_ceiling_frames(24.0, 7200.0)
        assert short == long_ == 240


class TestAggregateCeilingEnforcement:
    """Many chunks each just inside the per-chunk allowance must still trip the ceiling."""

    @staticmethod
    def _build(hls, n_chunks, total=960.0):
        """Render `n_chunks` strided chunks of 15 segments, each 96 frames per segment."""
        from app.services.chunk_transcode_service import HLS_LAYOUT_MARKER, HLS_LAYOUT_STRIDE
        hls.mkdir(parents=True, exist_ok=True)
        (hls / HLS_LAYOUT_MARKER).write_text(HLS_LAYOUT_STRIDE)
        for c in plan_chunks(total)[:n_chunks]:
            for i in range(c["start_seg"], c["start_seg"] + c["expected_segs"]):
                (hls / f"segment_{i:06d}.ts").write_bytes(b"x")

    @staticmethod
    def _frames_missing(loss_per_chunk):
        """Segment frame counter that shortens each chunk by exactly `loss_per_chunk` frames.

        Each chunk is 15 x 96 = 1440 frames. Shortening the chunk's FIRST segment by the loss
        makes the chunk total exact regardless of how the loss divides by 15.
        """
        def frames(path):
            idx = int(Path(path).name.split("_")[1].split(".")[0])
            return 96 - loss_per_chunk if idx % 32 == 0 else 96
        return frames

    def test_chunks_under_their_allowance_but_over_the_ceiling_are_caught(
            self, monkeypatch, tmp_path):
        import app.services.transcode_service as ts

        hls = tmp_path / "hls"
        # 16 chunks x 16 frames short: each is under the 17-frame allowance, but
        # 16 x 16 = 256 frames total is over the 240-frame whole-cache ceiling.
        self._build(hls, 16)
        monkeypatch.setattr(ts, "measure_segment_frame_count", self._frames_missing(16))
        monkeypatch.setattr(ts, "source_frame_rate", lambda p: 24.0)

        deficits = ts.chunk_content_deficits(hls, 960.0, source_path="src.mkv")
        assert not [d for d in deficits if d.get("chunk_id", 0) >= 0], \
            "no individual chunk should exceed its own allowance"
        agg = [d for d in deficits if d.get("aggregate")]
        assert len(agg) == 1, deficits
        assert agg[0]["chunk_id"] == -1
        assert agg[0]["missing_frames"] == 256
        assert agg[0]["ceiling_frames"] == 240

    def test_a_loss_under_the_ceiling_is_not_flagged(self, monkeypatch, tmp_path):
        import app.services.transcode_service as ts

        hls = tmp_path / "hls"
        # 16 chunks x 15 frames short = 240 frames, which is NOT over the 240-frame ceiling.
        self._build(hls, 16)
        monkeypatch.setattr(ts, "measure_segment_frame_count", self._frames_missing(15))
        monkeypatch.setattr(ts, "source_frame_rate", lambda p: 24.0)

        assert ts.chunk_content_deficits(hls, 960.0, source_path="src.mkv") == []

    def test_totals_are_reported_even_when_nothing_is_flagged(
            self, monkeypatch, tmp_path):
        """The accepted shortfall has to be measurable without being a defect."""
        import app.services.transcode_service as ts

        hls = tmp_path / "hls"
        self._build(hls, 8, total=480.0)
        monkeypatch.setattr(ts, "measure_segment_frame_count", self._frames_missing(90))
        monkeypatch.setattr(ts, "source_frame_rate", lambda p: 24.0)

        totals = {}
        ts.chunk_content_deficits(hls, 480.0, source_path="src.mkv", totals=totals)
        assert totals["missing_frames"] == 720                # 8 chunks x 90
        assert totals["frames_expected"] == 8 * 1440
        assert totals["frames_found"] == 8 * (1440 - 90)
        assert totals["per_chunk_tolerance_frames"] == 17
        assert totals["aggregate_ceiling_frames"] == 240