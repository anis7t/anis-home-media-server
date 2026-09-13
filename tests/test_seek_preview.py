from pathlib import Path

from app.services.preview_service import preview_dir, preview_meta


def test_preview_dir_is_deterministic(tmp_path):
    media = tmp_path / 'movie.mp4'
    media.write_bytes(b'test')
    assert preview_dir(media) == preview_dir(Path(media))


def test_preview_meta_rejects_zero_duration(monkeypatch, tmp_path):
    media = tmp_path / 'movie.mp4'
    media.write_bytes(b'test')
    monkeypatch.setattr('app.services.preview_service.probe_media', lambda _: {'format': {'duration': 0}})
    assert preview_meta(media) is None
