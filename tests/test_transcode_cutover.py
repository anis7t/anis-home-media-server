"""Tests for Phase 6 Slice 3: Transcoder single-ownership cutover to Rust.

Verifies that when DISABLE_FLASK_TRANSCODING is active, Flask transcode routines
fail closed / delegate to Rust and never spawn local FFmpeg workers or competing schedulers.
"""
from unittest.mock import patch, MagicMock
from pathlib import Path
import app.config as config
from app.services import worker_service
from app.services import transcode_service


def test_auto_transcoder_loop_exits_when_disabled(monkeypatch):
    monkeypatch.setattr(config, "DISABLE_FLASK_TRANSCODING", True)
    # auto_transcoder_loop must return immediately without looping
    with patch.object(worker_service, "video_paths") as mock_paths:
        worker_service.auto_transcoder_loop()
        mock_paths.assert_not_called()


def test_start_auto_transcoder_worker_skips_when_disabled(monkeypatch):
    monkeypatch.setattr(config, "DISABLE_FLASK_TRANSCODING", True)
    with patch("threading.Thread") as mock_thread:
        worker_service.start_auto_transcoder_worker()
        mock_thread.assert_not_called()


def test_ensure_hls_transcode_delegates_to_rust_when_disabled(monkeypatch, tmp_path):
    monkeypatch.setattr(config, "DISABLE_FLASK_TRANSCODING", True)
    fake_video = tmp_path / "sample.mkv"
    fake_video.write_bytes(b"dummy")

    with patch("app.services.transcode_service.safe_path", return_value=fake_video), \
         patch("app.services.transcode_service.is_video", return_value=True), \
         patch("app.services.transcode_service.get_rel_path", return_value="sample.mkv"), \
         patch("urllib.request.urlopen") as mock_urlopen:
        
        proc = transcode_service.ensure_hls_transcode("sample.mkv")
        # Must return None (no local Python/FFmpeg process started)
        assert proc is None
        # Must have called the Rust queue endpoint
        assert mock_urlopen.called
        req = mock_urlopen.call_args[0][0]
        assert "http://127.0.0.1:8001/api/transcode/jobs/sample.mkv" in req.full_url
