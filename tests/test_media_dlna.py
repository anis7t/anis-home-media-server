"""DLNA behaviour of the /media route: feature headers and time-range seeking.

A renderer decides whether to enable its FF/prev buttons from the DLNA feature string it
reads, and it asks for positions in *play time* - which the route has to translate into
the byte range a file can actually be served with. Both are covered here without a TV:
the keyframe lookup is injected, and everything else runs against a real 10-byte file.
"""
import pytest

from app import config, create_app, init_db
from app.routes import media as media_route

DLNA_FEATURES = 'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000'


@pytest.fixture
def client(tmp_path, monkeypatch):
    """Flask test client with an isolated database and a 10-byte media file."""
    monkeypatch.setattr(config, 'DATABASE', tmp_path / 'test_media_dlna.db')
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


# ------------------------------------------------------------- feature advertisement
def test_media_advertises_the_dlna_features_a_renderer_checks(client):
    """Without contentFeatures.dlna.org a renderer treats the stream as non-seekable.

    The Samsung DU7000 greys out FF/prev exactly because nothing told it the media
    supports byte-range seek.
    """
    response = client.get('/media/Example.2026.mp4')

    assert response.status_code == 200
    assert response.headers['contentFeatures.dlna.org'] == DLNA_FEATURES
    assert response.headers['transferMode.dlna.org'] == 'Streaming'


def test_media_answers_a_dlna_time_seek_with_the_keyframe_byte_range(client, monkeypatch):
    """Renderers ask for a time; the file can only be sliced by bytes.

    The 206 must start at the mapped keyframe and declare both the bytes and the time
    range it actually served.
    """
    monkeypatch.setattr(media_route, '_seek_point_for_time', lambda path, seconds: (4, 4.0, 10.0))

    response = client.get('/media/Example.2026.mp4', headers={'TimeSeekRange.dlna.org': 'npt=4-'})

    assert response.status_code == 206
    assert response.data == b'456789'
    assert response.headers['Content-Range'] == 'bytes 4-9/10'
    assert response.headers['TimeSeekRange.dlna.org'] == 'npt=4.000-10.000/10.000'
    assert response.headers['contentFeatures.dlna.org'] == DLNA_FEATURES


def test_the_requested_time_reaches_the_seek_mapper(client, monkeypatch):
    """Both npt forms are understood: plain seconds and the colon notation."""
    seen = {}

    def fake(path, seconds):
        seen['seconds'] = seconds
        return 4, 4.0, 10.0

    monkeypatch.setattr(media_route, '_seek_point_for_time', fake)
    client.get('/media/Example.2026.mp4', headers={'TimeSeekRange.dlna.org': 'npt=0:00:04.5-'})

    assert seen['seconds'] == pytest.approx(4.5)


def test_a_byte_range_request_is_never_treated_as_a_time_seek(client, monkeypatch):
    """Byte ranges stay the byte-range path - time seeking must not repurpose them."""
    called = []
    monkeypatch.setattr(
        media_route, '_seek_point_for_time', lambda path, seconds: called.append(seconds),
    )

    response = client.get(
        '/media/Example.2026.mp4',
        headers={'TimeSeekRange.dlna.org': 'npt=4-', 'Range': 'bytes=2-5'},
    )

    assert response.status_code == 206
    assert response.data == b'2345'
    assert response.headers['Content-Range'] == 'bytes 2-5/10'
    assert called == []


# ------------------------------------------------------------------- fallback paths
def test_a_seek_to_the_start_serves_from_byte_zero(client, monkeypatch):
    """A seek to 0 must include the container header, not start at the first packet."""
    monkeypatch.setattr(media_route, '_container_duration', lambda path: 10.0)

    response = client.get('/media/Example.2026.mp4', headers={'TimeSeekRange.dlna.org': 'npt=0-'})

    assert response.status_code == 206
    assert response.data == b'0123456789'
    assert response.headers['Content-Range'] == 'bytes 0-9/10'
    assert response.headers['TimeSeekRange.dlna.org'] == 'npt=0.000-10.000/10.000'


def test_a_missing_keyframe_answer_falls_back_to_a_linear_offset(client, monkeypatch):
    """No FFprobe, or no keyframe in range: estimate the offset from the duration."""
    monkeypatch.setattr(media_route, '_seek_point_for_time', lambda path, seconds: None)
    monkeypatch.setattr(media_route, '_container_duration', lambda path: 10.0)

    response = client.get('/media/Example.2026.mp4', headers={'TimeSeekRange.dlna.org': 'npt=5-'})

    assert response.status_code == 206
    assert response.data == b'56789'
    assert response.headers['Content-Range'] == 'bytes 5-9/10'
    assert response.headers['TimeSeekRange.dlna.org'] == 'npt=5.000-10.000/10.000'


def test_a_time_seek_that_cannot_be_resolved_still_serves_the_file(client, monkeypatch):
    """A time seek we cannot map must not cost the renderer its stream (no 500)."""
    monkeypatch.setattr(media_route, '_seek_point_for_time', lambda path, seconds: None)
    monkeypatch.setattr(media_route, '_container_duration', lambda path: 0.0)

    response = client.get('/media/Example.2026.mp4', headers={'TimeSeekRange.dlna.org': 'npt=5-'})

    assert response.status_code == 200
    assert response.data == b'0123456789'
    assert response.headers['contentFeatures.dlna.org'] == DLNA_FEATURES


def test_an_unreadable_time_seek_header_still_serves_the_file(client):
    response = client.get(
        '/media/Example.2026.mp4', headers={'TimeSeekRange.dlna.org': 'npt=not-a-time-'},
    )

    assert response.status_code == 200
    assert response.data == b'0123456789'


# ----------------------------------------------------------------------- npt parsing
@pytest.mark.parametrize('header,expected', [
    ('npt=300-', 300.0),
    ('npt=300.5-600', 300.5),
    ('npt=0:05:00-', 300.0),
    ('npt=0:00:04.5-0:00:09', 4.5),
    ('npt=1:00:00-', 3600.0),
    # a negative or zero position is the start of the file
    ('npt=-5-', 0.0),
    ('npt=0-', 0.0),
    # no live stream for "now" to mean anything, and nothing else is readable
    ('npt=now-', None),
    ('npt=', None),
    ('bytes=0-', None),
    ('', None),
    (None, None),
])
def test_parse_npt_start(header, expected):
    assert media_route._parse_npt_start(header) == expected