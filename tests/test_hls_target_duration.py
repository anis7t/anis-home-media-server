"""Tests for the `#EXT-X-TARGETDURATION` declaration an HLS playlist carries.

RFC 8216 requires every segment to be no longer than the declared target duration. The AMF encoders
do not keep the planned 4s cadence - real caches were found holding 5.0s segments while declaring 4 -
and a player is entitled to trust the declaration. The value comes from the segment labels, which are
honest; container durations are not (they carry the audio pre-roll).
"""
import re

import pytest

from app import config, create_app, init_db
from app.routes import media as media_route
from app.services.transcode_service import hls_cache_dir, honest_target_duration


# --------------------------------------------------------------------------- the declaration rule
def test_a_playlist_that_understates_its_segments_is_corrected():
    text = '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:5.000000,\nsegment_000000.ts\n'

    assert '#EXT-X-TARGETDURATION:5' in honest_target_duration(text)


def test_a_label_just_over_a_whole_second_rounds_up():
    """ceil, not floor: a 4.2s segment cannot be declared as 4."""
    text = '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.200000,\nsegment_000000.ts\n'

    assert '#EXT-X-TARGETDURATION:5' in honest_target_duration(text)


def test_a_correct_declaration_is_left_alone():
    """Idempotent, so it can sit on a path that runs on every request."""
    text = '#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5.000000,\nsegment_000000.ts\n'

    assert honest_target_duration(text) == text


def test_a_playlist_without_segments_is_returned_unchanged():
    text = '#EXTM3U\n#EXT-X-VERSION:3\n'

    assert honest_target_duration(text) == text


def test_a_missing_declaration_is_inserted_after_the_header():
    text = '#EXTM3U\n#EXTINF:6.000000,\nsegment_000000.ts\n'

    out = honest_target_duration(text)

    assert out.splitlines()[:2] == ['#EXTM3U', '#EXT-X-TARGETDURATION:6']


# ------------------------------------------------------------------- the playlist a receiver reads
@pytest.fixture
def client(tmp_path, monkeypatch):
    """Flask test client with an isolated database and a 10-byte media file."""
    monkeypatch.setattr(config, 'DATABASE', tmp_path / 'test_target_duration.db')
    media_dir = tmp_path / 'media'
    media_dir.mkdir(parents=True, exist_ok=True)
    monkeypatch.setattr(config, 'MEDIA_ROOT', media_dir)
    init_db()

    (media_dir / 'Example.2026.mp4').write_bytes(b'0123456789')

    import app.services.media_service as media_service
    media_service._paths = (0, [])

    app = create_app()
    app.config['TESTING'] = True
    return app.test_client()


@pytest.fixture
def cache_declaring_four(client, monkeypatch):
    """A cache that under-declares its target duration, as the live caches do."""
    path = config.MEDIA_ROOT / 'Example.2026.mp4'
    directory = hls_cache_dir(path)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'playlist.m3u8').write_text(
        '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n'
        '#EXTINF:5.000000,\nsegment_000000.ts\n#EXTINF:3.750000,\nsegment_000001.ts\n',
        encoding='utf-8',
    )
    (directory / 'segment_000000.ts').write_bytes(b'\x47' * 188)
    (directory / 'segment_000001.ts').write_bytes(b'\x47' * 188)
    monkeypatch.setattr(media_route, 'ensure_hls_transcode', lambda filename, **kwargs: None)
    return directory


def test_the_served_playlist_declares_its_longest_segment(client, cache_declaring_four):
    """The correction happens on the way out; the cache file keeps what the encoder wrote."""
    response = client.get('/hls/Example.2026.mp4/playlist.m3u8')

    assert response.status_code == 200
    body = response.get_data(as_text=True)
    labels = [float(m) for m in re.findall(r'#EXTINF:([\d.]+)', body)]
    declared = int(re.search(r'#EXT-X-TARGETDURATION:(\d+)', body).group(1))
    assert labels, 'the fixture playlist should still hold segments'
    assert declared >= max(labels)

    on_disk = (cache_declaring_four / 'playlist.m3u8').read_text(encoding='utf-8')
    assert '#EXT-X-TARGETDURATION:4' in on_disk, 'the file is the content record and stays as written'
    assert response.headers['Access-Control-Allow-Origin'] == '*', 'a receiver still needs CORS'