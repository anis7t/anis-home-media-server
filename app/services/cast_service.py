"""Casting to LAN playback devices: DLNA/UPnP renderers and Google Cast devices.

Why the server drives casting
-----------------------------
* One implementation serves every client - the web player and the Flutter app both
  only call ``/api/cast/*``.
* A browser cannot send SSDP or mDNS, and Google's Cast *web* sender SDK refuses to
  load on plain-HTTP origins - the LAN origin is HTTP.
* The URL handed to a TV is built here from a filename that went through
  ``safe_path()``, so a client can never aim a device at an arbitrary URL.

Devices are identified as ``dlna:<udn>`` or ``cast:<uuid>``. An id is only ever
resolved against the discovery cache; it is never a client-supplied address.

Media choice
------------
DLNA renderers (Samsung TVs and friends) decode the file themselves, so they get the
direct ``/media/<file>`` URL. Cast receivers cannot play Matroska/HEVC, so they get
the direct URL for web-friendly containers and otherwise the HLS playlist produced by
the transcoder.
"""
from __future__ import annotations

import html
import logging
import re
import socket
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET
from pathlib import Path

import requests

from app import config
from app.services.media_service import probe_media
from app.utils.filesystem import get_rel_path, is_video, mimetype, safe_path

log = logging.getLogger(__name__)

SSDP_ADDR = '239.255.255.250'
SSDP_PORT = 1900
MEDIA_RENDERER_ST = 'urn:schemas-upnp-org:device:MediaRenderer:1'
AVTRANSPORT_ST = 'urn:schemas-upnp-org:service:AVTransport:1'

# UPnP AVTransport faults worth explaining rather than echoing as "HTTP 500".
UPNP_FAULTS = {
    '701': 'The device refused that in its current state - nothing loaded, or it cannot do that.',
    '702': 'The device refused to play that in its current state.',
    '710': 'The device is busy - try again in a moment.',
    '711': 'The device rejected that position.',
    '716': 'The device is not playing yet - start playback first.',
}
RENDERING_ST = 'urn:schemas-upnp-org:service:RenderingControl:1'
DISCOVERY_TTL_SECONDS = 45.0
DEFAULT_PORT = 8000

# Containers a Cast receiver can play straight from the file.
CAST_DIRECT_EXTENSIONS = {'.mp4', '.m4v', '.webm', '.mov', '.mp3', '.m4a', '.aac'}

# DLNA parameters: the fourth field of ``res protocolInfo`` and the body of the
# ``contentFeatures.dlna.org`` header. A renderer reads them before it enables its own
# transport buttons - DLNA.ORG_OP=01 advertises byte-range seek, and the flags mark the
# stream as time-based and seekable. What we sent before was ``*``, which means "no DLNA
# operations": that is why the Samsung DU7000 greyed out FF/prev. Same string minidlna
# advertises (DLNA.ORG_CI=0: the stream is sent as-is, not converted).
DLNA_CONTENT_FEATURES = 'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000'

try:  # optional: casting to Chromecast needs it, DLNA does not
    import pychromecast

    CAST_SDK_AVAILABLE = True
    CAST_IMPORT_ERROR = ''
except Exception as exc:  # noqa: BLE001
    pychromecast = None
    CAST_SDK_AVAILABLE = False
    # str(), not _error_text(): that helper is defined further down, so the import guard
    # would raise NameError instead of reporting the real reason.
    CAST_IMPORT_ERROR = str(exc)


# --------------------------------------------------------------------------- helpers
def _strip_ns(tag: str) -> str:
    return tag.rsplit('}', 1)[-1]


def _find_text(node, name: str):
    """First text of a descendant element called *name*, ignoring namespaces."""
    for child in node.iter():
        if _strip_ns(child.tag) == name:
            return (child.text or '').strip()
    return None


def _hhmmss(seconds: float) -> str:
    total = max(0, int(seconds))
    return f'{total // 3600:02d}:{(total % 3600) // 60:02d}:{total % 60:02d}'


def _parse_hhmmss(value) -> float:
    if not value:
        return 0.0
    try:
        parts = [p for p in str(value).split(':')]
        parts = [float(p) for p in parts]
    except (TypeError, ValueError):
        return 0.0
    while len(parts) < 3:
        parts.insert(0, 0.0)
    return parts[0] * 3600 + parts[1] * 60 + parts[2]


def _map_state(raw) -> str:
    state = (raw or '').upper()
    if state in ('PLAYING', 'PLAY'):
        return 'playing'
    if state in ('PAUSED_PLAYBACK', 'PAUSED', 'PAUSE'):
        return 'paused'
    if state in ('TRANSITIONING', 'BUFFERING'):
        return 'buffering'
    if state in ('STOPPED', 'NO_MEDIA_PRESENT', 'IDLE'):
        return 'stopped'
    return state.lower() or 'unknown'


def _soap_envelope(service_type: str, action: str, args: dict) -> str:
    inner = ''.join(
        f'<{key}>{html.escape(str(value))}</{key}>' for key, value in args.items()
    )
    return (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        f'<s:Body><u:{action} xmlns:u="{service_type}">{inner}</u:{action}></s:Body>'
        '</s:Envelope>'
    )


def _soap_call(control_url: str, service_type: str, action: str, args: dict, timeout: float = 8.0) -> str:
    headers = {
        'Content-Type': 'text/xml; charset="utf-8"',
        'SOAPAction': f'"{service_type}#{action}"',
    }
    response = requests.post(
        control_url,
        data=_soap_envelope(service_type, action, args).encode('utf-8'),
        headers=headers,
        timeout=timeout,
    )
    if response.status_code >= 400:
        code = re.search(r'<errorCode>(\d+)</errorCode>', response.text)
        description = re.search(r'<errorDescription>(.*?)</errorDescription>', response.text)
        explained = UPNP_FAULTS.get(code.group(1)) if code else None
        detail = explained or (description.group(1) if description else f'HTTP {response.status_code}')
        raise requests.HTTPError(
            f'{detail} (UPnP {code.group(1)})' if code else detail,
            response=response,
        )
    return response.text


def lan_ip() -> str:
    """The address other devices on the LAN can reach this server on."""
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            # No packet is sent; this only asks the routing table which local address wins.
            probe.connect(('8.8.8.8', 80))
            return probe.getsockname()[0]
        finally:
            probe.close()
    except OSError:
        return '127.0.0.1'


def server_port() -> int:
    for name in ('PORT', 'MEDIA_SERVER_PORT', 'SERVER_PORT'):
        value = getattr(config, name, None)
        if isinstance(value, int) and value > 0:
            return value
    return DEFAULT_PORT


def _is_private_host(host: str) -> bool:
    parts = host.split('.')
    if len(parts) != 4:
        return False
    try:
        octets = [int(p) for p in parts]
    except ValueError:
        return False
    if octets[0] == 10:
        return True
    if octets[0] == 192 and octets[1] == 168:
        return True
    if octets[0] == 172 and 16 <= octets[1] <= 31:
        return True
    return octets[0] == 127


def _error_text(exc: Exception) -> str:
    """Text for a failure: our own cast messages already read as sentences.

    Upstream faults are translated in UPNP_FAULTS, so prefixing them with the class
    name only produced noise like "HTTPError: This TV does not allow seeking ...".
    """
    text = str(exc) or exc.__class__.__name__
    if isinstance(exc, requests.HTTPError):
        return text
    return f'{type(exc).__name__}: {text}'


def _is_loopback_host(host: str) -> bool:
    """127.0.0.0/8, localhost and IPv6 loopback: reachable only from this machine.

    Fine as an SSRF guard, useless as a cast target - a device told to fetch from
    127.0.0.1 fetches from itself, which is how a live cast died with UPnP 716.
    """
    cleaned = (host or '').strip().lower().strip('[]')
    if cleaned in ('localhost', '::1', '0.0.0.0'):
        return True
    return cleaned.startswith('127.')


def validate_origin(origin: str) -> str | None:
    """Accept an explicit cast origin only when it cannot be used as an SSRF pivot.

    The URL we hand a TV is always ``<origin>/media/<file>`` with the file validated
    locally, so the only freedom a client gets is which host the *TV* fetches. Keep
    that to private LAN addresses, loopback and the configured public hostname.
    """
    if not origin:
        return None
    try:
        parsed = urllib.parse.urlparse(origin.strip())
    except ValueError:
        return None
    if parsed.scheme not in ('http', 'https') or not parsed.hostname:
        return None
    if parsed.path not in ('', '/') or parsed.query or parsed.fragment:
        return None
    host = parsed.hostname
    allowed = _is_private_host(host)
    if not allowed:
        for name in ('PUBLIC_HOST', 'PUBLIC_HOSTNAME', 'MEDIA_SERVER_PUBLIC_HOST'):
            configured = getattr(config, name, None)
            if configured and str(configured).lower() == host.lower():
                allowed = True
    if not allowed:
        return None
    port = f':{parsed.port}' if parsed.port else ''
    return f'{parsed.scheme}://{host}{port}'


def resolve_origin(origin: str | None, request_base: str | None = None) -> str | None:
    """The origin a device should fetch media from, or None for the server's LAN address.

    None is the common, correct answer: a TV on the same network should always fetch
    from the LAN address. An explicit origin is honoured only when it is a private
    address or exactly the address the client used to reach us, so a request can never
    aim a TV at a third-party host.
    """
    candidate = validate_origin(origin or '')
    if candidate:
        host = urllib.parse.urlparse(candidate).hostname or ''
        if _is_loopback_host(host):
            log.debug('Ignoring loopback origin %r for a cast; using the LAN address', candidate)
            return None
        return candidate
    if request_base:
        try:
            parsed = urllib.parse.urlparse(request_base)
        except ValueError:
            return None
        if parsed.hostname and _is_loopback_host(parsed.hostname):
            # The client reached us over loopback (a browser or script on this machine);
            # the device cannot follow it there, so fall back to the LAN address.
            log.debug('Request base %r is loopback; devices use the LAN address', request_base)
            return None
        if parsed.hostname and _is_private_host(parsed.hostname):
            port = f':{parsed.port}' if parsed.port else ''
            return f'{parsed.scheme or "http"}://{parsed.hostname}{port}'
    return None


def build_media_url(path, origin: str | None = None, hls: bool = False) -> str:
    """URL for a device to fetch: the LAN address by default, HLS when asked."""
    rel = get_rel_path(path)
    base = validate_origin(origin or '') or f'http://{lan_ip()}:{server_port()}'
    if hls:
        return f'{base}/hls/{urllib.parse.quote(rel)}/playlist.m3u8'
    return f'{base}/media/{urllib.parse.quote(rel)}'


def _dlna_duration(seconds) -> str:
    """DLNA duration format ``H:MM:SS.mmm`` - the form renderers print and parse."""
    total = max(0.0, float(seconds or 0.0))
    hours, remainder = divmod(total, 3600.0)
    minutes, secs = divmod(remainder, 60.0)
    return f'{int(hours)}:{int(minutes):02d}:{secs:06.3f}'


def _didl_metadata(title: str, url: str, content_type: str, size=None, duration=None) -> str:
    """DIDL-Lite payload; Samsung and other renderers show this title on screen.

    ``size`` and ``duration`` are what a renderer reads to draw its scrub bar and to
    decide the item is seekable, and the fourth ``protocolInfo`` field carries the DLNA
    operations (see DLNA_CONTENT_FEATURES) without which it greys out FF/prev.
    """
    attributes = ''
    if size:
        attributes += f' size="{int(size)}"'
    if duration:
        attributes += f' duration="{_dlna_duration(duration)}"'
    return (
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="-1" restricted="1">'
        f'<dc:title>{html.escape(title)}</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        f'<res protocolInfo="http-get:*:{content_type}:{DLNA_CONTENT_FEATURES}"{attributes}>'
        f'{html.escape(url)}</res>'
        '</item></DIDL-Lite>'
    )


# ----------------------------------------------------------------------------- DLNA
def _dlna_description(location: str) -> dict | None:
    """Read a device description and keep only real AVTransport renderers."""
    try:
        body = requests.get(location, timeout=4).text
        root = ET.fromstring(body)
    except (requests.RequestException, ET.ParseError) as exc:
        log.debug('DLNA description failed for %s: %s', location, exc)
        return None

    av_control = rendering_control = None
    for service in root.iter():
        if _strip_ns(service.tag) != 'service':
            continue
        service_type = _find_text(service, 'serviceType') or ''
        control = _find_text(service, 'controlURL')
        if not control:
            continue
        if service_type.startswith(AVTRANSPORT_ST):
            av_control = urllib.parse.urljoin(location, control)
        elif service_type.startswith(RENDERING_ST):
            rendering_control = urllib.parse.urljoin(location, control)
    if not av_control:
        return None

    parsed = urllib.parse.urlparse(location)
    udn = _find_text(root, 'UDN') or parsed.hostname or location
    return {
        'id': f'dlna:{udn}',
        'kind': 'dlna',
        'name': _find_text(root, 'friendlyName') or 'DLNA device',
        'model': _find_text(root, 'modelName') or '',
        'host': parsed.hostname or '',
        'control_url': av_control,
        'rendering_control_url': rendering_control,
        'location': location,
    }


def _multicast_interfaces() -> list[str]:
    """Usable IPv4 addresses to send SSDP from.

    An unbound multicast socket follows the OS default route, which on a dual-homed
    host can be the wrong adapter entirely - the search then never reaches the
    device even though the device is on the network. One socket per interface is
    cheap and removes the guesswork.
    """
    addresses: list[str] = []
    try:
        import psutil

        for _name, snics in psutil.net_if_addrs().items():
            for entry in snics:
                if entry.family == socket.AF_INET and entry.address:
                    if not entry.address.startswith(('127.', '169.254.')):
                        addresses.append(entry.address)
    except Exception as exc:  # noqa: BLE001 - psutil is only a convenience here
        log.debug('Interface enumeration failed (%s); falling back to the LAN address', exc)
    if not addresses:
        addresses.append(lan_ip())
    return sorted(set(addresses))


def discover_dlna(timeout: float = 3.0) -> list[dict]:
    """SSDP M-SEARCH for MediaRenderers from every interface, then read descriptions."""
    message = (
        'M-SEARCH * HTTP/1.1\r\n'
        f'HOST: {SSDP_ADDR}:{SSDP_PORT}\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: {st}\r\n\r\n'
    )
    locations: dict[str, str] = {}
    sockets: list[socket.socket] = []
    try:
        for interface in _multicast_interfaces():
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(interface))
                sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
                sock.bind((interface, 0))
                sock.settimeout(0.5)
            except OSError as exc:
                log.debug('SSDP interface %s unusable: %s', interface, exc)
                continue
            sockets.append(sock)
        if not sockets:
            log.warning('No usable interface for SSDP discovery')
        # Two search targets and two passes per interface: SSDP is lossy, and some
        # renderers only answer the service type rather than the device type.
        for sock in sockets:
            for service_type in (MEDIA_RENDERER_ST, AVTRANSPORT_ST):
                for _ in range(2):
                    try:
                        sock.sendto(
                            message.format(st=service_type).encode('utf-8'),
                            (SSDP_ADDR, SSDP_PORT),
                        )
                    except OSError as exc:
                        log.debug('SSDP send failed: %s', exc)
        deadline = time.time() + timeout
        while time.time() < deadline:
            for sock in sockets:
                try:
                    data, addr = sock.recvfrom(4096)
                except socket.timeout:
                    continue
                except OSError:
                    continue
                text = data.decode('utf-8', 'replace')
                for line in text.splitlines():
                    if line.lower().startswith('location:'):
                        locations.setdefault(addr[0], line.split(':', 1)[1].strip())
    finally:
        for sock in sockets:
            sock.close()

    devices = []
    for location in locations.values():
        device = _dlna_description(location)
        if device:
            devices.append(device)
    return devices


def _wait_for_transport(device: dict, want: str = 'playing', timeout: float = 8.0) -> str:
    """Poll GetTransportInfo until the renderer leaves the stopped state."""
    deadline = time.time() + timeout
    state = 'unknown'
    while time.time() < deadline:
        try:
            info = _soap_call(device['control_url'], AVTRANSPORT_ST, 'GetTransportInfo', {'InstanceID': 0})
            state = _map_state(_find_text(ET.fromstring(info), 'CurrentTransportState'))
        except Exception as exc:  # noqa: BLE001 - the state is best-effort here
            log.debug('Transport state read failed on %s: %s', device.get('id'), exc)
            return state
        if state == want or (want == 'playing' and state == 'paused'):
            return state
        time.sleep(0.4)
    return state


def dlna_load(
    device: dict,
    url: str,
    title: str,
    content_type: str,
    position: float | None = None,
    size: int | None = None,
    duration: float | None = None,
) -> None:
    _soap_call(
        device['control_url'], AVTRANSPORT_ST, 'SetAVTransportURI',
        {
            'InstanceID': 0,
            'CurrentURI': url,
            'CurrentURIMetaData': _didl_metadata(
                title, url, content_type, size=size, duration=duration,
            ),
        },
    )
    _soap_call(device['control_url'], AVTRANSPORT_ST, 'Play', {'InstanceID': 0, 'Speed': 1})
    if position:
        # Seek only after the renderer has the media loaded: a stopped Samsung answers
        # HTTP 500 to a premature Seek, which used to abort the entire load.
        _wait_for_transport(device)
        _soap_call(
            device['control_url'], AVTRANSPORT_ST, 'Seek',
            {'InstanceID': 0, 'Unit': 'REL_TIME', 'Target': _hhmmss(position)},
        )


def dlna_command(device: dict, action: str, value=None) -> None:
    url = device['control_url']
    if action == 'play':
        _soap_call(url, AVTRANSPORT_ST, 'Play', {'InstanceID': 0, 'Speed': 1})
    elif action == 'pause':
        _soap_call(url, AVTRANSPORT_ST, 'Pause', {'InstanceID': 0})
    elif action == 'stop':
        _soap_call(url, AVTRANSPORT_ST, 'Stop', {'InstanceID': 0})
    elif action == 'seek':
        # A paused renderer ignores a seek and a stopped one errors, so start playback
        # first when needed - seeking is a request to watch from there.
        try:
            info = _soap_call(url, AVTRANSPORT_ST, 'GetTransportInfo', {'InstanceID': 0})
            state = _map_state(_find_text(ET.fromstring(info), 'CurrentTransportState'))
        except Exception:  # noqa: BLE001
            state = 'unknown'
        if state != 'playing':
            _soap_call(url, AVTRANSPORT_ST, 'Play', {'InstanceID': 0, 'Speed': 1})
            _wait_for_transport(device)
        try:
            _soap_call(
                url, AVTRANSPORT_ST, 'Seek',
                {'InstanceID': 0, 'Unit': 'REL_TIME', 'Target': _hhmmss(float(value or 0))},
            )
        except requests.HTTPError as exc:
            # Verified on the Samsung DU7000: 701 for every seek form (REL_TIME,
            # ABS_TIME, REL_COUNT) and 402 for SeekMode, so a remote cannot jump it.
            if '701' in str(exc):
                raise requests.HTTPError(
                    'This device does not allow seeking from another app - use its own '
                    'remote to jump ahead. (UPnP 701)',
                    response=getattr(exc, 'response', None),
                ) from exc
            raise
    elif action == 'volume':
        control = device.get('rendering_control_url')
        if not control:
            raise RuntimeError('device has no RenderingControl service')
        _soap_call(
            control, RENDERING_ST, 'SetVolume',
            {'InstanceID': 0, 'Channel': 'Master', 'DesiredVolume': int(float(value or 0))},
        )
    else:
        raise ValueError(f'unsupported action: {action}')


def dlna_status(device: dict) -> dict:
    info = _soap_call(device['control_url'], AVTRANSPORT_ST, 'GetTransportInfo', {'InstanceID': 0})
    state = _map_state(_find_text(ET.fromstring(info), 'CurrentTransportState'))
    position = duration = 0.0
    try:
        position_info = _soap_call(device['control_url'], AVTRANSPORT_ST, 'GetPositionInfo', {'InstanceID': 0})
        root = ET.fromstring(position_info)
        position = _parse_hhmmss(_find_text(root, 'RelTime'))
        duration = _parse_hhmmss(_find_text(root, 'TrackDuration'))
    except (requests.RequestException, ET.ParseError) as exc:
        log.debug('DLNA position read failed for %s: %s', device['id'], exc)
    return {'state': state, 'position': position, 'duration': duration}


def _dlna_size_and_duration(path) -> tuple[int, float]:
    """File size and duration for the DIDL metadata, both best-effort.

    A renderer needs them to draw a scrub bar; a missing value only costs the attribute
    (and a 0 duration is omitted from the metadata), never the cast itself.
    """
    try:
        size = Path(path).stat().st_size
    except OSError as exc:
        log.debug('Size lookup failed for %s: %s', path, exc)
        size = 0
    duration = 0.0
    try:
        duration = float((probe_media(path).get('format') or {}).get('duration') or 0.0)
    except Exception as exc:  # noqa: BLE001 - probing a TV's behalf is a nicety, not a gate
        log.debug('Duration probe failed for %s: %s', path, exc)
    return size, duration


# ---------------------------------------------------------------------- Google Cast
def _cast_module():
    """pychromecast, or a clear error when the optional dependency is missing."""
    if not CAST_SDK_AVAILABLE or pychromecast is None:
        raise RuntimeError(f'pychromecast unavailable: {CAST_IMPORT_ERROR}')
    return pychromecast


# --- Cast receivers need to be told two things pychromecast does not default to ---
#
# 1. A start position belongs in the LOAD message. A receiver has no media session for
#    seconds after a load, and a Seek sent in that window is rejected ("Failed to execute
#    seek 180.0" was observed on the Samsung DU7000) - which is how a resume cast
#    silently started from the beginning.
# 2. The artifact is BUFFERED, not LIVE (pychromecast's default). A receiver told the
#    stream is live treats it as unseekable, so both our own Seek commands and a scrub
#    from the phone did nothing.
CAST_STREAM_TYPE = 'BUFFERED'
# How long a control command may wait for a media session to appear before it is sent
# anyway (a cast that is still opening its stream should not turn a scrub into an error).
CAST_SESSION_WAIT_SECONDS = 4.0


def discover_cast(timeout: float = 5.0) -> list[dict]:
    """mDNS discovery via CastBrowser (``discover_chromecasts`` is deprecated).

    Returns CastInfo-derived dicts without connecting to each device - connecting is
    deferred until something actually needs to be cast.
    """
    _cast_module()
    import zeroconf
    from pychromecast.discovery import CastBrowser, SimpleCastListener

    zconf = zeroconf.Zeroconf()
    browser = CastBrowser(SimpleCastListener(), zconf)
    browser.start_discovery()
    try:
        deadline = time.time() + timeout
        while time.time() < deadline:
            time.sleep(0.25)
        devices = []
        for info in list(browser.devices.values()):
            devices.append({
                'id': f'cast:{info.uuid}',
                'kind': 'cast',
                'name': info.friendly_name or 'Cast device',
                'model': info.model_name or '',
                'host': info.host or '',
                'uuid': str(info.uuid),
            })
        return devices
    finally:
        for stop in (browser.stop_discovery, zconf.close):
            try:
                stop()
            except Exception:  # noqa: BLE001
                pass


def _cast_connect(device: dict, timeout: float = 12.0):
    """Connect to one Cast device, reusing a live connection when possible."""
    cached = _REGISTRY.cast_connection(device['id'])
    if cached is not None:
        return cached
    casts, browser = _cast_module().get_listed_chromecasts(
        friendly_names=[device['name']], timeout=timeout, discovery_timeout=timeout,
    )
    if not casts:
        raise RuntimeError(f'Cast device "{device["name"]}" did not answer')
    cast = casts[0]
    cast.wait(timeout=timeout)
    _REGISTRY.remember_cast_connection(device['id'], cast, browser)
    return cast


def cast_load(device: dict, url: str, title: str, content_type: str, position: float | None = None) -> None:
    """Hand the media to a Cast receiver, starting at *position* when it is given."""
    cast = _cast_connect(device)
    controller = cast.media_controller
    controller.play_media(
        url,
        content_type,
        title=title,
        stream_type=CAST_STREAM_TYPE,
        current_time=float(position) if position else None,
        autoplay=True,
    )


def _wait_for_cast_session(controller) -> None:
    """Give the receiver time to create its media session before a control command.

    Commands sent into the gap between LOAD and the session being active are rejected by
    the receiver; the wait is bounded so a device that never starts still answers.
    """
    try:
        controller.block_until_active(timeout=CAST_SESSION_WAIT_SECONDS)
    except Exception as exc:  # noqa: BLE001 - the command itself reports the real failure
        log.debug('Cast session wait failed: %s', exc)


def cast_command(device: dict, action: str, value=None) -> None:
    controller = _cast_connect(device).media_controller
    if action == 'play':
        _wait_for_cast_session(controller)
        controller.play()
    elif action == 'pause':
        _wait_for_cast_session(controller)
        controller.pause()
    elif action == 'stop':
        controller.stop()
    elif action == 'seek':
        _wait_for_cast_session(controller)
        controller.seek(float(value or 0))
    elif action == 'volume':
        _cast_connect(device).set_volume(float(value or 0) / 100.0)
    else:
        raise ValueError(f'unsupported action: {action}')


def _refresh_cast_status(controller, timeout: float = 2.0) -> None:
    """Ask the receiver for its current media status before reading the cached one.

    A Cast receiver pushes MEDIA_STATUS on transitions only - measured minutes apart while
    playing - so a cached read freezes the phone's cast bar and can make a position from
    minutes ago look like a command that never landed. The request is fire-and-forget, so
    bound the wait for its answer; whatever arrives lands in ``controller.status``.
    """
    answered = threading.Event()
    try:
        controller.update_status(callback_function=lambda _ok, _response: answered.set())
    except Exception as exc:  # noqa: BLE001 - the cached status is still usable
        log.debug('Cast status request failed: %s', exc)
        return
    answered.wait(timeout)


def cast_status(device: dict) -> dict:
    controller = _cast_connect(device).media_controller
    _refresh_cast_status(controller)
    status = controller.status
    if status is None:
        return {'state': 'unknown', 'position': 0.0, 'duration': 0.0}
    raw = (status.player_state or '').upper()
    state = {'PLAYING': 'playing', 'PAUSED': 'paused', 'BUFFERING': 'buffering', 'IDLE': 'stopped'}.get(raw, raw.lower())
    return {
        'state': state,
        'position': float(status.current_time or 0.0),
        'duration': float(status.duration or 0.0),
    }


# ------------------------------------------------------------------------- registry
class CastRegistry:
    """Discovery cache plus the single entry point the routes use.

    Discovery is slow (SSDP waits, mDNS waits), so it runs on a worker thread and
    callers read the cache. ``play`` returns as soon as the device has been handed the
    media, so the HTTP request never blocks on a TV.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._devices: dict[str, dict] = {}
        self._errors: dict[str, str] = {}
        self._scanned_at = 0.0
        self._scanning = False
        self._cast_connections: dict[str, tuple] = {}
        self._active: dict[str, dict] = {}

    # -- discovery
    def devices(self, force: bool = False) -> dict:
        with self._lock:
            fresh = (time.time() - self._scanned_at) < DISCOVERY_TTL_SECONDS
            if (force or not fresh) and not self._scanning:
                self._scanning = True
                threading.Thread(target=self._scan, name='cast-discovery', daemon=True).start()
            return {
                # `ok` is part of the shape every other cast endpoint answers with, and the
                # web player's picker requires it - without it a scan that found the TV was
                # reported as "Could not list cast devices" (the app tolerated the omission).
                'ok': True,
                'devices': sorted(self._devices.values(), key=lambda d: (d['kind'], d['name'].lower())),
                'scanning': self._scanning,
                'errors': dict(self._errors),
                'scanned_at': self._scanned_at,
            }

    def _scan(self) -> None:
        found: dict[str, dict] = {}
        errors: dict[str, str] = {}
        try:
            for device in discover_dlna():
                found[device['id']] = device
        except Exception as exc:  # noqa: BLE001
            errors['dlna'] = _error_text(exc)
            log.warning('DLNA discovery failed: %s', exc)
        try:
            for device in discover_cast():
                found[device['id']] = device
        except Exception as exc:  # noqa: BLE001
            errors['cast'] = _error_text(exc)
            log.warning('Cast discovery failed: %s', exc)
        with self._lock:
            self._devices = found
            self._errors = errors
            self._scanned_at = time.time()
            self._scanning = False

    def get_device(self, device_id: str) -> dict | None:
        with self._lock:
            return self._devices.get(device_id)

    def resolve_device(self, device_id: str) -> dict | None:
        """The discovered device, or a stand-in for a Cast device we are still connected to.

        A scan **replaces** the discovery map, and an mDNS browse window misses the TV now
        and then (measured: one scan of three). While the phone was visibly casting, that
        made every control and status call answer "Unknown device - rescan and try again."
        - remote buttons that appear to do nothing. A live connection proves the device is
        still there, so keep serving it until the socket drops.
        """
        device = self.get_device(device_id)
        if device is not None:
            return device
        cast = self.cast_connection(device_id)
        if cast is None:
            return None
        info = getattr(cast, 'device', None)
        name = getattr(info, 'friendly_name', None) or getattr(cast, 'name', None) or 'Cast device'
        return {'id': device_id, 'name': name, 'kind': 'cast', 'model': getattr(info, 'model_name', '')}

    # -- cast connections (shared with the module-level helpers)
    def cast_connection(self, device_id: str):
        with self._lock:
            entry = self._cast_connections.get(device_id)
        return entry[0] if entry else None

    def remember_cast_connection(self, device_id: str, cast, browser) -> None:
        with self._lock:
            self._cast_connections[device_id] = (cast, browser)

    # -- actions
    def play(self, device_id: str, filename: str, position: float | None = None, origin: str | None = None) -> dict:
        device = self.resolve_device(device_id)
        if device is None:
            return {'ok': False, 'error': 'Unknown device - rescan and try again.'}

        try:
            path = safe_path(filename)
        except Exception:  # noqa: BLE001 - safe_path aborts on traversal/unknown names
            return {'ok': False, 'error': 'Unknown media file.'}
        if not is_video(path):
            return {'ok': False, 'error': 'Not a playable video file.'}

        title = Path(path).name
        content_type = mimetype(path)
        use_hls = False
        if device['kind'] == 'cast' and Path(path).suffix.lower() not in CAST_DIRECT_EXTENSIONS:
            playlist = _hls_playlist(path)
            if playlist is None:
                return {
                    'ok': False,
                    'error': (
                        f'Chromecast cannot play {Path(path).suffix or "this file"} directly. '
                        'Open it once in the player to build an HLS version, then cast.'
                    ),
                }
            use_hls = True
            content_type = 'application/x-mpegURL'
            title = f'{title} (transcoded)'

        url = build_media_url(path, origin=origin, hls=use_hls)
        with self._lock:
            self._active[device_id] = {'filename': filename, 'url': url, 'title': title}

        def _run():
            try:
                if device['kind'] == 'dlna':
                    size, duration = _dlna_size_and_duration(path)
                    dlna_load(
                        device, url, title, content_type, position,
                        size=size, duration=duration,
                    )
                else:
                    cast_load(device, url, title, content_type, position)
                with self._lock:
                    self._errors.pop(f'play:{device_id}', None)
            except Exception as exc:  # noqa: BLE001
                log.warning('Cast load failed on %s: %s', device_id, exc)
                with self._lock:
                    self._errors[f'play:{device_id}'] = _error_text(exc)

        threading.Thread(target=_run, name='cast-load', daemon=True).start()
        return {'ok': True, 'device': device['name'], 'url': url, 'kind': device['kind']}

    def control(self, device_id: str, action: str, value=None) -> dict:
        device = self.resolve_device(device_id)
        if device is None:
            return {'ok': False, 'error': 'Unknown device - rescan and try again.'}
        try:
            if device['kind'] == 'dlna':
                dlna_command(device, action, value)
            else:
                cast_command(device, action, value)
        except Exception as exc:  # noqa: BLE001
            return {'ok': False, 'error': _error_text(exc)}
        if action == 'stop':
            with self._lock:
                self._active.pop(device_id, None)
        return {'ok': True}

    def status(self, device_id: str) -> dict:
        device = self.resolve_device(device_id)
        if device is None:
            return {'ok': False, 'error': 'Unknown device - rescan and try again.'}
        try:
            payload = dlna_status(device) if device['kind'] == 'dlna' else cast_status(device)
        except Exception as exc:  # noqa: BLE001
            return {'ok': False, 'error': _error_text(exc)}
        with self._lock:
            active = dict(self._active.get(device_id) or {})
            last_error = self._errors.get(f'play:{device_id}')
        payload.update({'ok': True, 'device': device['name'], 'kind': device['kind']})
        payload.update({k: v for k, v in active.items() if k != 'url'})
        if last_error:
            # The load runs off-thread, so this is how a refusal (codec, network)
            # reaches the remote instead of leaving it stuck on "starting".
            payload['last_error'] = last_error
        return payload


def _hls_playlist(path) -> Path | None:
    """The transcoded playlist for *path*, when a cache already exists."""
    try:
        from app.services.transcode_service import hls_cache_dir

        playlist = Path(hls_cache_dir(path)) / 'playlist.m3u8'
        return playlist if playlist.is_file() else None
    except Exception as exc:  # noqa: BLE001
        log.debug('HLS lookup failed for %s: %s', path, exc)
        return None


_REGISTRY = CastRegistry()


def registry() -> CastRegistry:
    return _REGISTRY
