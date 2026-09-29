"""CORS on the media paths a cast receiver fetches itself.

An HLS manifest and its segments are fetched by the receiver's own loader - a web runtime (CAF) - so
a missing `Access-Control-Allow-Origin` means the receiver downloads the playlist and can read
nothing out of it, and the media session ends with no error this server can see. That is the whole of
"MP4 casts, MKV does not": a media element is not a CORS request, while the HLS loader's fetches are.
"""
import urllib.parse

import pytest

from app import config, create_app, init_db
from app.routes import media as media_route
from app.services.cast_service import build_media_url
from app.services.transcode_service import hls_cache_dir

ALLOW_ORIGIN = 'Access-Control-Allow-Origin'


@pytest.fixture
def client(tmp_path, monkeypatch):
    """Flask test client with an isolated database and a 10-byte media file."""
    monkeypatch.setattr(config, 'DATABASE', tmp_path / 'test_media_cors.db')
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
def hls_cache(client, monkeypatch):
    """A ready-made cache directory, so the HLS routes serve files instead of starting a transcode."""
    path = config.MEDIA_ROOT / 'Example.2026.mp4'
    directory = hls_cache_dir(path)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'playlist.m3u8').write_text(
        '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n'
        '#EXTINF:4.000000,\nsegment_000000.ts\n'
    )
    (directory / 'segment_000000.ts').write_bytes(b'\x47' * 188)
    monkeypatch.setattr(media_route, 'ensure_hls_transcode', lambda filename, **kwargs: None)
    return directory


# --------------------------------------------------------------- what a receiver may read
def test_media_bytes_are_readable_from_another_origin(client):
    """A receiver's own fetches are cross-origin; the bytes have to carry the permission."""
    response = client.get('/media/Example.2026.mp4')

    assert response.status_code == 200
    assert response.headers[ALLOW_ORIGIN] == '*'
    assert 'Content-Range' in response.headers['Access-Control-Expose-Headers']


def test_hls_manifest_and_segments_are_readable_from_another_origin(client, hls_cache):
    """The manifest is fetched by the receiver's HLS loader, so it needs CORS as much as a segment.

    This is the request that failed silently: the playlist arrived, the loader could not read it,
    and no segment was ever asked for.
    """
    playlist = client.get('/hls/Example.2026.mp4/playlist.m3u8')
    segment = client.get('/hls/Example.2026.mp4/segment_000000.ts')

    assert playlist.status_code == 200
    assert playlist.headers[ALLOW_ORIGIN] == '*'
    assert segment.status_code == 200
    assert segment.headers[ALLOW_ORIGIN] == '*'


def test_a_preflight_for_a_ranged_fetch_is_answered(client, hls_cache):
    """`Range` is not a safelisted request header, so a loader that sends one preflights first."""
    response = client.options(
        '/hls/Example.2026.mp4/segment_000000.ts',
        headers={
            'Origin': 'https://192.168.1.16:8000',
            'Access-Control-Request-Method': 'GET',
            'Access-Control-Request-Headers': 'range',
        },
    )

    assert response.status_code in (200, 204)
    assert response.headers[ALLOW_ORIGIN] == '*'
    assert 'Range' in response.headers['Access-Control-Allow-Headers']


def test_the_api_stays_unreadable_from_another_origin(client):
    """CORS is scoped to media delivery on purpose: another site must not read this server's API."""
    response = client.get('/api/seek-preview-meta/Example.2026.mp4')

    assert ALLOW_ORIGIN not in response.headers


def test_every_url_a_receiver_is_handed_lives_on_a_cors_path():
    """The cast helper and the CORS policy have to agree, or a format silently stops working."""
    path = config.MEDIA_ROOT / 'Example.2026.mp4'

    for hls in (False, True):
        url = build_media_url(path, origin='http://127.0.0.1:8000', hls=hls)
        assert urllib.parse.urlsplit(url).path.startswith(media_route.CORS_PATHS), url