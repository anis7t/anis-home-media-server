"""End-to-end exercise of the DLNA control path against a stub renderer.

The stub speaks the same SOAP dialect a real TV does, so this covers the real flow:
URL building, DIDL metadata, SetAVTransportURI -> optional Seek -> Play, the
transport/position reads, and pause/seek/volume/stop. Discovery is not covered here
(it needs a device on the LAN - it was verified against the owner's Samsung TV);
the device is injected into the registry instead.
"""
import http.server
import threading
import time
import xml.etree.ElementTree as ET

import pytest

from app import config
from app.services import cast_service as cs

AVT = 'urn:schemas-upnp-org:service:AVTransport:1'
RCS = 'urn:schemas-upnp-org:service:RenderingControl:1'


class StubRenderer:
    """Minimal UPnP AVTransport + RenderingControl responder that records calls."""

    def __init__(self, state='PLAYING', position='00:00:42', duration='01:16:00', volume=35):
        self.calls: list[tuple[str, dict]] = []
        self.state = state
        self.position = position
        self.duration = duration
        self.volume = volume
        self._lock = threading.Lock()
        stub = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, fmt, *args):  # keep the test output clean
                pass

            def do_POST(self):
                length = int(self.headers.get('Content-Length') or 0)
                body = self.rfile.read(length).decode('utf-8', 'replace')
                action = (self.headers.get('SOAPAction') or '').split('#')[-1].strip('"')
                args = {}
                for element in ET.fromstring(body).iter():
                    tag = element.tag.split('}')[-1]
                    if tag != action and element.text:
                        args[tag] = element.text
                with stub._lock:
                    stub.calls.append((action, args))
                    # A real renderer only accepts a seek once the transport is up; the
                    # Samsung answered UPnP 701 to anything else (verified on hardware).
                    refuse = action == 'Seek' and stub.state == 'STOPPED'
                    if action == 'Play':
                        stub.state = 'PLAYING'
                    elif action == 'Pause':
                        stub.state = 'PAUSED_PLAYBACK'
                    elif action == 'Stop':
                        stub.state = 'STOPPED'
                if refuse:
                    fault = (
                        '<?xml version="1.0"?>'
                        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
                        '<s:Body><s:Fault><faultcode>s:Client</faultcode>'
                        '<faultstring>UPnPError</faultstring><detail>'
                        f'<UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
                        '<errorCode>701</errorCode>'
                        '<errorDescription>Transition not available</errorDescription>'
                        '</UPnPError></detail></s:Fault></s:Body></s:Envelope>'
                    ).encode('utf-8')
                    self.send_response(500)
                    self.send_header('Content-Type', 'text/xml; charset="utf-8"')
                    self.send_header('Content-Length', str(len(fault)))
                    self.end_headers()
                    self.wfile.write(fault)
                    return
                payload = stub._response(action)
                data = (
                    '<?xml version="1.0"?>'
                    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
                    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
                    f'<u:{action}Response xmlns:u="{AVT}">{payload}</u:{action}Response>'
                    '</s:Body></s:Envelope>'
                ).encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'text/xml; charset="utf-8"')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self._server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.port = self._server.server_address[1]
        self.url = f'http://127.0.0.1:{self.port}/upnp/control/AVTransport1'
        self.rendering_url = f'http://127.0.0.1:{self.port}/upnp/control/RenderingControl1'
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    def _response(self, action: str) -> str:
        if action == 'GetTransportInfo':
            return f'<CurrentTransportState>{self.state}</CurrentTransportState>'
        if action == 'GetPositionInfo':
            return f'<RelTime>{self.position}</RelTime><TrackDuration>{self.duration}</TrackDuration>'
        if action == 'GetMediaInfo':
            return '<CurrentURI>stub</CurrentURI>'
        if action == 'GetVolume':
            return f'<CurrentVolume>{self.volume}</CurrentVolume>'
        return ''

    def actions(self) -> list[str]:
        with self._lock:
            return [action for action, _ in self.calls]

    def args_for(self, action: str) -> dict:
        with self._lock:
            for seen, args in self.calls:
                if seen == action:
                    return args
        return {}

    def wait_for(self, action: str, timeout: float = 6.0) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if action in self.actions():
                return True
            time.sleep(0.05)
        return False

    def close(self) -> None:
        self._server.shutdown()
        self._server.server_close()


@pytest.fixture
def stub_renderer():
    renderer = StubRenderer()
    yield renderer
    renderer.close()


@pytest.fixture
def registry_with_stub(stub_renderer, tmp_path, monkeypatch):
    """A registry whose only device is the stub (never scanned, so it cannot be clobbered)."""
    monkeypatch.setattr(config, 'MEDIA_ROOT', tmp_path)
    video = tmp_path / 'Some Movie 2026.mp4'
    video.write_bytes(b'\x00' * 32)

    registry = cs.CastRegistry()
    registry._devices = {
        'dlna:stub': {
            'id': 'dlna:stub',
            'name': 'Stub TV',
            'kind': 'dlna',
            'model': 'stub',
            'host': '127.0.0.1',
            'control_url': stub_renderer.url,
            'rendering_control_url': stub_renderer.rendering_url,
        }
    }
    return registry, video.name


def test_play_hands_the_url_and_metadata_to_the_renderer(registry_with_stub, stub_renderer):
    registry, filename = registry_with_stub

    result = registry.play('dlna:stub', filename, position=90)

    assert result['ok'] is True, result
    assert stub_renderer.wait_for('Play'), stub_renderer.actions()
    # The hand-over runs off-thread, so the Seek lands after Play is recorded - wait for
    # it before ordering, otherwise this asserts on a half-finished hand-over.
    assert stub_renderer.wait_for('Seek'), stub_renderer.actions()
    # Play must come before Seek: a stopped renderer answers 701 to a premature seek
    # (observed on the real TV), which used to abort the whole hand-over.
    actions = stub_renderer.actions()
    assert actions[0] == 'SetAVTransportURI', actions
    assert actions.index('Play') < actions.index('Seek'), actions

    uri = stub_renderer.args_for('SetAVTransportURI')
    assert 'Some' in uri['CurrentURI'] and uri['CurrentURI'].startswith('http://')
    assert filename.split()[0] in uri['CurrentURI'].replace('%20', ' ')
    # the renderer needs a DIDL-Lite document, not a bare URL
    assert 'DIDL-Lite' in uri['CurrentURIMetaData'] and 'Some Movie 2026.mp4' in uri['CurrentURIMetaData']
    # ...and it enables its FF/prev buttons from the DLNA operations in the fourth
    # protocolInfo field, using size/duration to place the scrub bar.
    assert cs.DLNA_CONTENT_FEATURES in uri['CurrentURIMetaData']
    assert 'size="32"' in uri['CurrentURIMetaData']
    # resume point: 90 s in HH:MM:SS
    assert stub_renderer.args_for('Seek')['Target'] == '00:01:30'


def test_a_seek_before_play_is_never_sent_because_renderers_refuse_it(registry_with_stub, stub_renderer):
    """Regression: the TV answered UPnP 701 to a Seek sent between SetAVTransportURI
    and Play, and the load aborted - so casting with a resume point never started.
    The stub refuses exactly like the TV does."""
    registry, filename = registry_with_stub

    result = registry.play('dlna:stub', filename, position=300)
    assert result['ok'] is True, result
    assert stub_renderer.wait_for('Seek'), stub_renderer.actions()

    # No error surfaced: the seek only happened once playback was up.
    assert registry.status('dlna:stub').get('last_error') in (None, '')
    assert stub_renderer.args_for('Seek')['Target'] == '00:05:00'


def test_status_reports_the_renderer_transport_state_and_position(registry_with_stub, stub_renderer):
    registry, _ = registry_with_stub

    payload = registry.status('dlna:stub')

    assert payload['ok'] is True
    assert payload['state'] == 'playing'
    assert payload['position'] == 42.0
    assert payload['duration'] == 4560.0
    assert payload['device'] == 'Stub TV'

    stub_renderer.state = 'PAUSED_PLAYBACK'
    assert registry.status('dlna:stub')['state'] == 'paused'


def test_control_drives_pause_seek_volume_and_stop(registry_with_stub, stub_renderer):
    registry, _ = registry_with_stub

    registry.control('dlna:stub', 'pause')
    assert stub_renderer.wait_for('Pause')

    registry.control('dlna:stub', 'seek', 12)
    assert stub_renderer.args_for('Seek')['Target'] == '00:00:12'

    registry.control('dlna:stub', 'volume', 60)
    assert stub_renderer.args_for('SetVolume')['DesiredVolume'] == '60'

    registry.control('dlna:stub', 'stop')
    assert stub_renderer.wait_for('Stop')
    assert 'Stop' in stub_renderer.actions()


def test_a_refusing_renderer_is_reported_instead_of_silently_stalling(registry_with_stub, monkeypatch):
    registry, filename = registry_with_stub

    def explode(*args, **kwargs):
        raise RuntimeError('renderer said no')

    monkeypatch.setattr(cs, 'dlna_load', explode)
    assert registry.play('dlna:stub', filename)['ok'] is True  # handed over off-thread

    payload = {}
    deadline = time.time() + 5
    while time.time() < deadline:
        payload = registry.status('dlna:stub')
        if payload.get('last_error'):
            break
        time.sleep(0.05)
    assert 'renderer said no' in payload.get('last_error', '')


def test_an_unknown_device_and_a_bad_file_are_refused(registry_with_stub, tmp_path):
    registry, _ = registry_with_stub

    assert registry.play('dlna:nope', 'anything.mp4')['ok'] is False
    assert registry.play('dlna:stub', '../../etc/passwd')['ok'] is False
    assert registry.play('dlna:stub', 'not-here.mp4')['ok'] is False
    assert registry.control('dlna:nope', 'pause')['ok'] is False
    assert registry.status('dlna:nope')['ok'] is False