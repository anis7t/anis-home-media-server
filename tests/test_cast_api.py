"""Tests for the casting API and its discovery/control helpers.

Nothing here touches the network: the SOAP/mDNS transports are covered through their
pure helpers, and the registry is driven with fake devices, so the suite stays fast
and independent of whether a TV happens to be switched on.
"""
import json
from collections.abc import Callable

import pytest

from app import config, create_app, get_db, init_db
from app.services import cast_service as cs


@pytest.fixture
def client(tmp_path, monkeypatch):
    """Flask test client with an isolated database and media directory."""
    test_db = tmp_path / "test_cast.db"
    media_dir = tmp_path / "media"
    media_dir.mkdir(parents=True, exist_ok=True)

    monkeypatch.setattr(config, "DATABASE", test_db)
    monkeypatch.setattr(config, "MEDIA_ROOT", media_dir)
    init_db()

    (media_dir / "Castable_Movie.2026.mp4").write_bytes(b"dummy video content")
    (media_dir / "Matroska_Movie.2026.mkv").write_bytes(b"dummy video content")

    import app.services.media_service as media_service
    media_service._paths = (0, [])

    app = create_app()
    app.config["TESTING"] = True
    return app.test_client()


@pytest.fixture
def fake_registry(monkeypatch):
    """A registry with one fake DLNA renderer, so routes never scan the network."""
    reg = cs.CastRegistry()
    reg._devices = {
        "dlna:test-tv": {
            "id": "dlna:test-tv", "kind": "dlna", "name": "Test TV", "model": "Fake",
            "host": "192.168.1.50", "control_url": "http://192.168.1.50:9197/av",
            "rendering_control_url": "http://192.168.1.50:9197/rc",
            "location": "http://192.168.1.50:9197/dd.xml",
        }
    }
    reg._scanned_at = cs.time.time()
    monkeypatch.setattr(cs, "_REGISTRY", reg)
    return reg


# ------------------------------------------------------------- Google Cast channels
class _FakeStatus:
    """The fields the status route reads off a receiver's MediaStatus."""

    def __init__(self, player_state='PLAYING', current_time=0.0, duration=0.0):
        self.player_state = player_state
        self.current_time = current_time
        self.duration = duration


class _FakeMediaController:
    """Records the commands the server sends a Cast receiver."""

    def __init__(self):
        self.calls = []
        self.session_error: Exception | None = None
        self.status: _FakeStatus | None = None
        # What the receiver does when asked for its status: update the value, then answer.
        self.refresh: Callable[[_FakeMediaController], None] | None = None

    def update_status(self, callback_function=None):
        self.calls.append(('update_status',))
        if self.refresh is not None:
            self.refresh(self)
            if callback_function:
                callback_function(True, {})

    def play_media(self, url, content_type, **kwargs):
        self.calls.append(('play_media', url, content_type, kwargs))

    def block_until_active(self, timeout=None):
        self.calls.append(('block_until_active', timeout))
        if self.session_error:
            raise self.session_error

    def play(self):
        self.calls.append(('play',))

    def pause(self):
        self.calls.append(('pause',))

    def stop(self):
        self.calls.append(('stop',))

    def seek(self, position, timeout=10.0):
        self.calls.append(('seek', position))


class _FakeCast:
    def __init__(self):
        self.media_controller = _FakeMediaController()


def test_cast_load_puts_the_resume_point_in_the_load_message(monkeypatch):
    """A Seek sent after a load races the receiver's media session and is refused.

    Live: the Samsung DU7000 rejected it ("Failed to execute seek 180.0") while the media
    played on from the beginning, and pychromecast's default stream type is LIVE, which
    tells the receiver the artifact cannot be seeked at all.
    """
    fake = _FakeCast()
    monkeypatch.setattr(cs, '_cast_connect', lambda device, timeout=12.0: fake)

    cs.cast_load({'id': 'cast:1'}, 'http://host/media/A Movie.mp4', 'A Movie', 'video/mp4', position=180)

    assert fake.media_controller.calls == [
        (
            'play_media', 'http://host/media/A Movie.mp4', 'video/mp4',
            {'title': 'A Movie', 'stream_type': 'BUFFERED', 'current_time': 180.0, 'autoplay': True},
        ),
    ]


def test_cast_load_without_a_position_leaves_the_start_time_open(monkeypatch):
    fake = _FakeCast()
    monkeypatch.setattr(cs, '_cast_connect', lambda device, timeout=12.0: fake)

    cs.cast_load({'id': 'cast:1'}, 'http://host/media/a.mp4', 'A Movie', 'video/mp4')

    kwargs = fake.media_controller.calls[0][3]
    assert kwargs['current_time'] is None
    assert kwargs['stream_type'] == 'BUFFERED'


@pytest.mark.parametrize("action,expected", [
    ('play', ('play',)),
    ('pause', ('pause',)),
    ('seek', ('seek', 600.0)),
])
def test_cast_controls_wait_for_the_media_session_first(monkeypatch, action, expected):
    """A command sent before the receiver has a session is rejected, so wait for it."""
    fake = _FakeCast()
    monkeypatch.setattr(cs, '_cast_connect', lambda device, timeout=12.0: fake)

    cs.cast_command({'id': 'cast:1'}, action, 600)

    calls = fake.media_controller.calls
    assert calls[0][0] == 'block_until_active'
    assert calls[1] == expected


def test_a_receiver_that_never_opens_a_session_still_gets_the_command(monkeypatch):
    """The wait is bounded: a device that never starts must not turn a scrub into a 500."""
    fake = _FakeCast()
    fake.media_controller.session_error = RuntimeError('no session')
    monkeypatch.setattr(cs, '_cast_connect', lambda device, timeout=12.0: fake)

    cs.cast_command({'id': 'cast:1'}, 'seek', 600)

    assert fake.media_controller.calls[-1] == ('seek', 600.0)


def test_stop_does_not_wait_on_a_session(monkeypatch):
    """Stop is the way out of a stuck cast - it must never block behind a session."""
    fake = _FakeCast()
    monkeypatch.setattr(cs, '_cast_connect', lambda device, timeout=12.0: fake)

    cs.cast_command({'id': 'cast:1'}, 'stop')

    assert fake.media_controller.calls == [('stop',)]


def test_cast_status_asks_the_receiver_instead_of_reporting_a_stale_push(monkeypatch):
    """A receiver pushes MEDIA_STATUS on transitions only - measured minutes apart while
    playing - so a cached read froze the phone's cast bar on an old position."""
    fake = _FakeCast()
    fake.media_controller.status = _FakeStatus(current_time=82.279, duration=4717.024)
    fake.media_controller.refresh = lambda controller: setattr(
        controller, 'status', _FakeStatus(current_time=255.2, duration=4717.024),
    )
    monkeypatch.setattr(cs, '_cast_connect', lambda device, timeout=12.0: fake)

    status = cs.cast_status({'id': 'cast:1'})

    assert ('update_status',) in fake.media_controller.calls
    assert status == {'state': 'playing', 'position': 255.2, 'duration': 4717.024}


def test_the_status_refresh_is_bounded_and_falls_back_to_the_cached_value():
    """A silent receiver must not turn every poll into a hang - the app polls every 5 s."""
    fake = _FakeCast()  # refresh stays None: the receiver never answers
    fake.media_controller.status = _FakeStatus(current_time=10.0, duration=100.0)

    started = cs.time.time()
    cs._refresh_cast_status(fake.media_controller, timeout=0.05)

    assert cs.time.time() - started < 1.0
    cached = fake.media_controller.status
    assert cached is not None
    assert cached.current_time == 10.0


def test_a_device_the_scan_missed_is_still_controllable_while_connected(monkeypatch):
    """A scan replaces the discovery map and an mDNS window misses the TV now and then
    (one scan of three, measured) - which answered "Unknown device - rescan and try
    again." for every button while the phone was visibly casting to that TV."""
    fake = _FakeCast()
    registry = cs.CastRegistry()
    registry._devices = {}
    registry.remember_cast_connection('cast:tv', fake, None)
    monkeypatch.setattr(cs, '_REGISTRY', registry)

    resolved = registry.resolve_device('cast:tv')
    assert resolved is not None and resolved['kind'] == 'cast'
    assert registry.control('cast:tv', 'pause') == {'ok': True}
    assert ('pause',) in fake.media_controller.calls
    # a device with neither a scan entry nor a connection is still unknown
    assert registry.resolve_device('cast:gone') is None


# ------------------------------------------------------------------ pure helpers
def test_soap_envelope_carries_the_action_and_arguments():
    body = cs._soap_envelope(cs.AVTRANSPORT_ST, "Seek", {"InstanceID": 0, "Target": "00:01:30"})
    assert f'xmlns:u="{cs.AVTRANSPORT_ST}"' in body
    assert "<u:Seek" in body and "</u:Seek>" in body
    assert "<Target>00:01:30</Target>" in body
    assert "<InstanceID>0</InstanceID>" in body


def test_didl_metadata_is_escaped():
    body = cs._didl_metadata(
        "Tom & Jerry <Best>", "http://host/media/a&b.mp4", "video/mp4",
        size=1234, duration=3661.5,
    )
    assert "Tom &amp; Jerry &lt;Best&gt;" in body
    assert "a&amp;b.mp4" in body
    # The fourth protocolInfo field is what a renderer reads before enabling FF/prev:
    # '*' (what we sent before) means "no DLNA operations" and greys the buttons out.
    assert f'protocolInfo="http-get:*:video/mp4:{cs.DLNA_CONTENT_FEATURES}"' in body
    assert 'DLNA.ORG_OP=01' in body and 'DLNA.ORG_FLAGS=01700000000000000000000000000000' in body
    assert 'size="1234"' in body
    assert 'duration="1:01:01.500"' in body


def test_didl_metadata_omits_size_and_duration_it_does_not_have():
    """Unknown values must not be sent as empty or zero attributes."""
    body = cs._didl_metadata("A Movie", "http://host/media/a.mp4", "video/mp4")

    assert ' size=' not in body and ' duration=' not in body
    assert f':{cs.DLNA_CONTENT_FEATURES}"' in body


@pytest.mark.parametrize("seconds,expected", [
    (0, "0:00:00.000"),
    (90.5, "0:01:30.500"),
    (3661.4, "1:01:01.400"),
    (4717.024, "1:18:37.024"),
])
def test_dlna_duration_format(seconds, expected):
    assert cs._dlna_duration(seconds) == expected


@pytest.mark.parametrize("raw,expected", [
    ("PLAYING", "playing"),
    ("PAUSED_PLAYBACK", "paused"),
    ("TRANSITIONING", "buffering"),
    ("STOPPED", "stopped"),
    ("NO_MEDIA_PRESENT", "stopped"),
    (None, "unknown"),
])
def test_map_state(raw, expected):
    assert cs._map_state(raw) == expected


def test_hhmmss_round_trip():
    assert cs._hhmmss(0) == "00:00:00"
    assert cs._hhmmss(3661.4) == "01:01:01"
    assert cs._parse_hhmmss("01:01:01") == 3661
    assert cs._parse_hhmmss("00:01:30.500") == pytest.approx(90.5)
    assert cs._parse_hhmmss("NOT_IMPLEMENTED") == 0.0
    assert cs._parse_hhmmss(None) == 0.0


@pytest.mark.parametrize("origin,expected", [
    ("http://192.168.1.16:8000", "http://192.168.1.16:8000"),
    ("http://10.1.2.3", "http://10.1.2.3"),
    ("http://172.20.0.9:9000", "http://172.20.0.9:9000"),
    ("http://127.0.0.1:8000", "http://127.0.0.1:8000"),
    # a public host is only allowed when configured, so it is rejected by default
    ("http://evil.example.com", None),
    ("https://evil.example.com:8443", None),
    # paths, queries, odd schemes and garbage are never origins
    ("http://192.168.1.16:8000/x", None),
    ("http://192.168.1.16:8000/?a=1", None),
    ("file:///etc/passwd", None),
    ("javascript:alert(1)", None),
    ("", None),
    (None, None),
])
def test_validate_origin(origin, expected):
    assert cs.validate_origin(origin) == expected


def test_resolve_origin_uses_a_private_request_host_but_not_a_public_one():
    assert cs.resolve_origin(None, "http://192.168.1.16:8000/") == "http://192.168.1.16:8000"
    assert cs.resolve_origin(None, "https://media.example.com/") is None
    assert cs.resolve_origin("http://10.0.0.5:7000", "http://192.168.1.16:8000/") == "http://10.0.0.5:7000"
    # an unusable explicit origin falls back to the LAN default, never to the attacker
    assert cs.resolve_origin("http://evil.example.com", "https://media.example.com/") is None


def test_build_media_url_quotes_the_name_and_prefers_the_lan_address(monkeypatch, tmp_path):
    media = tmp_path / "media"
    media.mkdir()
    name = "A Movie & Friends 2026.mp4"
    (media / name).write_bytes(b"x")
    monkeypatch.setattr(config, "MEDIA_ROOT", media)
    monkeypatch.setattr(cs, "lan_ip", lambda: "192.168.1.16")
    monkeypatch.setattr(cs, "server_port", lambda: 8000)

    url = cs.build_media_url(media / name)
    assert url.startswith("http://192.168.1.16:8000/media/")
    assert " " not in url and "&" not in url.split("/media/", 1)[1]

    hls = cs.build_media_url(media / name, hls=True)
    assert hls.endswith("/playlist.m3u8") and "/hls/" in hls


# ------------------------------------------------------------------------ routes
def test_devices_endpoint_reports_scan_state(client, fake_registry):
    payload = client.get("/api/cast/devices").get_json()
    assert [d["id"] for d in payload["devices"]] == ["dlna:test-tv"]
    assert payload["devices"][0]["name"] == "Test TV"
    assert payload["errors"] == {}


def test_play_requires_device_and_filename(client, fake_registry):
    assert client.post("/api/cast/play", json={}).status_code == 400
    assert client.post("/api/cast/play", json={"device_id": "dlna:test-tv"}).status_code == 400
    assert client.post("/api/cast/play", json={"filename": "Castable_Movie.2026.mp4"}).status_code == 400


def test_play_rejects_an_unknown_device(client, fake_registry):
    response = client.post("/api/cast/play", json={"device_id": "dlna:nope", "filename": "Castable_Movie.2026.mp4"})
    assert response.status_code == 400
    assert "Unknown device" in response.get_json()["error"]


def test_play_rejects_traversal_names(client, fake_registry):
    """Names that escape the media roots are refused before anything reaches a device."""
    for name in ("../../etc/passwd", "..\\..\\windows\\win.ini", "/etc/shadow"):
        response = client.post("/api/cast/play", json={"device_id": "dlna:test-tv", "filename": name})
        assert response.status_code == 400, name
        assert "Unknown media file" in response.get_json()["error"], name


def test_play_rejects_a_name_that_is_not_a_video(client, fake_registry):
    """A plausible but absent name resolves inside the root and is then refused as media."""
    response = client.post("/api/cast/play", json={"device_id": "dlna:test-tv", "filename": "missing.mp4"})
    assert response.status_code == 400
    assert "Not a playable video file" in response.get_json()["error"]


def test_play_reports_a_missing_hls_version_for_cast_only_containers(client, fake_registry, monkeypatch):
    """A Cast device cannot play Matroska, so the registry must ask for an HLS build."""
    reg = cs.CastRegistry()
    reg._devices = {"cast:test": {"id": "cast:test", "kind": "cast", "name": "Cast TV", "model": "", "host": "192.168.1.60"}}
    reg._scanned_at = cs.time.time()
    monkeypatch.setattr(cs, "_REGISTRY", reg)
    monkeypatch.setattr(cs, "_hls_playlist", lambda path: None)

    response = client.post("/api/cast/play", json={"device_id": "cast:test", "filename": "Matroska_Movie.2026.mkv"})
    assert response.status_code == 400
    assert "cannot play" in response.get_json()["error"]


def test_play_hands_the_media_url_to_the_device(client, fake_registry, monkeypatch):
    """The URL a device receives is built server-side from the validated filename."""
    started = {}

    def fake_load(device, url, title, content_type, position=None, **kwargs):
        started.update(url=url, title=title, content_type=content_type, **kwargs)

    monkeypatch.setattr(cs, "dlna_load", fake_load)
    response = client.post(
        "/api/cast/play",
        json={"device_id": "dlna:test-tv", "filename": "Castable_Movie.2026.mp4", "position": 30},
    )
    assert response.status_code == 200 and response.get_json()["ok"] is True
    for _ in range(50):
        if started:
            break
        cs.time.sleep(0.05)
    assert started["url"].startswith("http://") and started["url"].endswith("Castable_Movie.2026.mp4")
    assert "/media/" in started["url"]
    assert started["content_type"] == "video/mp4"
    assert started["title"] == "Castable_Movie.2026.mp4"
    # The DIDL metadata needs the file size (and duration when it can be probed) - a
    # renderer uses them to draw a scrub bar and to decide the item is seekable.
    assert started["size"] == len(b"dummy video content")
    assert started["duration"] == 0.0


def test_control_validates_actions_and_values(client, fake_registry, monkeypatch):
    sent = []
    monkeypatch.setattr(cs, "dlna_command", lambda device, action, value=None: sent.append((action, value)))
    assert client.post("/api/cast/control", json={"device_id": "dlna:test-tv", "action": "bogus"}).status_code == 400
    assert client.post("/api/cast/control", json={"device_id": "dlna:test-tv", "action": "seek"}).status_code == 400
    assert client.post("/api/cast/control", json={"device_id": "dlna:test-tv", "action": "volume", "value": 500}).status_code == 400
    assert client.post("/api/cast/control", json={"action": "play"}).status_code == 400
    ok = client.post("/api/cast/control", json={"device_id": "dlna:test-tv", "action": "pause"})
    assert ok.status_code == 200 and ok.get_json()["ok"] is True
    assert sent == [("pause", None)]

    seek = client.post("/api/cast/control", json={"device_id": "dlna:test-tv", "action": "seek", "value": 42})
    assert seek.status_code == 200
    assert sent[-1] == ("seek", 42.0)


def test_control_reports_device_errors_as_json(client, fake_registry, monkeypatch):
    def boom(device, action, value=None):
        raise RuntimeError("renderer refused")

    monkeypatch.setattr(cs, "dlna_command", boom)
    response = client.post("/api/cast/control", json={"device_id": "dlna:test-tv", "action": "play"})
    assert response.status_code == 400
    assert "renderer refused" in response.get_json()["error"]


def test_status_requires_a_device_id(client, fake_registry):
    assert client.get("/api/cast/status").status_code == 400
    assert client.get("/api/cast/status?device_id=dlna:nope").status_code == 400


def test_status_returns_transport_state(client, fake_registry, monkeypatch):
    monkeypatch.setattr(cs, "dlna_status", lambda device: {"state": "playing", "position": 12.5, "duration": 90.0})
    payload = client.get("/api/cast/status?device_id=dlna:test-tv").get_json()
    assert payload["ok"] is True
    assert payload["state"] == "playing" and payload["position"] == 12.5
    assert payload["device"] == "Test TV" and payload["kind"] == "dlna"


def test_devices_endpoint_starts_a_scan_without_blocking(client, monkeypatch):
    reg = cs.CastRegistry()
    monkeypatch.setattr(cs, "_REGISTRY", reg)
    payload = client.get("/api/cast/devices?refresh=1").get_json()
    assert payload["scanning"] is True and payload["devices"] == []
    # a second call while scanning must not start another scan
    assert client.get("/api/cast/devices").get_json()["scanning"] is True


# --------------------------------------------------------------------------------------
# SSDP interface selection
# --------------------------------------------------------------------------------------

def _iface(name_address, family, address):
    class _Snica:
        def __init__(self):
            self.family = family
            self.address = address

    return _Snica()


def test_multicast_interfaces_skips_loopback_and_link_local(monkeypatch):
    """A dual-homed host must be searched from every usable address.

    The live bug: an unbound SSDP socket left over Wi-Fi, so the M-SEARCH never
    reached the TV on the wired LAN and discovery reported no devices at all.
    """
    import psutil
    import socket as _socket

    monkeypatch.setattr(
        psutil, 'net_if_addrs',
        lambda: {
            'Loopback': [_iface('lo', _socket.AF_INET, '127.0.0.1')],
            'WLAN virtual 1': [_iface('v1', _socket.AF_INET, '169.254.3.6')],
            'Ethernet': [_iface('eth', _socket.AF_INET, '192.168.1.16')],
            'Wi-Fi': [_iface('wifi', _socket.AF_INET, '192.168.1.12')],
            'v6': [_iface('v6', _socket.AF_INET6, 'fe80::1')],
        },
    )

    assert cs._multicast_interfaces() == ['192.168.1.12', '192.168.1.16']


def test_multicast_interfaces_falls_back_to_the_lan_address(monkeypatch):
    import psutil

    monkeypatch.setattr(psutil, 'net_if_addrs', lambda: {})
    monkeypatch.setattr(cs, 'lan_ip', lambda: '10.0.0.5')

    assert cs._multicast_interfaces() == ['10.0.0.5']


def test_device_listing_keeps_the_shared_response_shape(client):
    """Every cast endpoint answers `ok`; the web picker refuses a scan without it.

    Live bug: /api/cast/devices omitted `ok`, so the web player reported "Could not
    list cast devices" while the TV was listed - the Flutter client tolerated the
    omission, the web one did not.
    """
    body = client.get('/api/cast/devices').get_json()

    assert body['ok'] is True
    assert isinstance(body['devices'], list)
    assert 'scanning' in body and 'errors' in body
