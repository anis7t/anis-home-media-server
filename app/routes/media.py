"""Media streaming, byte ranges, direct transcoding, and HLS routes."""
import json
import os
import re
import subprocess
import sys
import threading
import time
from functools import lru_cache
from shutil import which as shutil_which
from flask import Blueprint, Response, abort, jsonify, request, send_file
from werkzeug.utils import send_file as send_file_for_environ

from app import config
from app.services.cast_service import DLNA_CONTENT_FEATURES
from app.services.media_service import probe_media
from app.services.preview_service import ensure_preview_thumbnail, preview_meta
from app.services.chunk_transcode_service import reconcile_hls_playlist_discontinuities
from app.services.transcode_service import (
    compat_transcode_args,
    ensure_hls_transcode,
    hls_cache_dir,
    transcode_cache_path,
    transcode_progress_path,
)
from app.utils.filesystem import is_video, mimetype, parse_range, safe_path

media_bp = Blueprint('media', __name__)

# DLNA renderers ask for a *time* range (`TimeSeekRange.dlna.org: npt=…`) and read the
# feature string (`contentFeatures.dlna.org`) before enabling their own transport
# buttons. Both are answered additively: browsers and the app keep using plain bytes.
DLNA_TIME_SEEK_HEADER = 'TimeSeekRange.dlna.org'
DLNA_TRANSFER_MODE_HEADER = 'transferMode.dlna.org'
DLNA_CONTENT_FEATURES_HEADER = 'contentFeatures.dlna.org'

# ``npt=300-``, ``npt=300.5-600``, ``npt=0:05:00-``; the end of the range is optional and
# is not honoured (we always stream to the end of the file and say so in the response).
_NPT_PATTERN = re.compile(r'npt=([+-]?[0-9:.]+)')


def check_which(cmd):
    """Resolve binary path with support for test patches on app.which."""
    if 'app' in sys.modules and hasattr(sys.modules['app'], 'which'):
        app_which = sys.modules['app'].which
        if app_which != shutil_which:
            return app_which(cmd)
    return shutil_which(cmd)


def _parse_npt_start(value) -> float | None:
    """Seconds from a DLNA ``TimeSeekRange: npt=<time>[-<time>]`` header.

    Normal-play-time, not bytes: plain seconds (``300``, ``300.5``) or the colon form
    (``0:05:00``). Returns None for anything unreadable - the caller then streams the
    file normally rather than failing a request it does not understand - and clamps
    negative values to 0, so a time seek can never point behind the start of the file.
    """
    if not value:
        return None
    match = _NPT_PATTERN.search(str(value))
    if not match:
        return None
    raw = match.group(1)
    try:
        if ':' in raw:
            parts = [float(part) for part in raw.split(':')]
            while len(parts) < 3:
                parts.insert(0, 0.0)
            seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
        else:
            seconds = float(raw)
    except ValueError:
        return None
    return max(0.0, seconds)


@lru_cache(maxsize=256)
def _probe_container_duration(filename: str, mtime_ns: int) -> float:
    """Container duration in seconds via FFprobe, 0.0 when it cannot be read."""
    try:
        info = probe_media(filename) or {}
        return float((info.get('format') or {}).get('duration') or 0.0)
    except (OSError, TypeError, ValueError):
        return 0.0


def _container_duration(path) -> float:
    try:
        mtime_ns = os.stat(path).st_mtime_ns
    except OSError:
        return 0.0
    return _probe_container_duration(str(path), mtime_ns)


@lru_cache(maxsize=256)
def _probe_seek_point(filename: str, mtime_ns: int, seconds: float):
    """Keyframe byte offset, actual start time and duration, or None.

    ``-read_intervals <t>%+#1`` asks FFprobe for the single packet at or before *t* -
    the keyframe a decoder can start from - and ``packet=pos`` gives its offset in the
    file. One call costs ~0.3 s, so results are memoised per (file, mtime, time): a
    renderer scrubbing back and forth must not spawn an FFprobe per request.
    """
    probe = check_which('ffprobe')
    if not probe:
        return None
    try:
        result = subprocess.run(
            [
                probe, '-v', 'error', '-select_streams', 'v:0',
                '-read_intervals', f'{seconds:g}%+#1',
                '-show_entries', 'packet=pos,pts_time:format=duration',
                '-of', 'json', filename,
            ],
            capture_output=True, text=True, check=False, timeout=30,
        )
        payload = json.loads(result.stdout or '{}')
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    packets = payload.get('packets') or []
    if not packets:
        return None
    try:
        offset = max(0, int(packets[0]['pos']))
        start = max(0.0, float(packets[0].get('pts_time') or 0.0))
    except (KeyError, TypeError, ValueError):
        return None
    try:
        duration = float((payload.get('format') or {}).get('duration') or 0.0)
    except (TypeError, ValueError):
        duration = 0.0
    return offset, start, duration


def _seek_point_for_time(path, seconds):
    """``(byte offset, actual start, duration)`` to start streaming at *seconds*.

    A seek to the very beginning starts at byte 0 rather than at the first video packet:
    a plain MP4 keeps its ``moov`` box in front of the media data, so skipping the
    container header would hand the renderer a stream it cannot initialise. None when
    the offset cannot be established; the caller then falls back to a linear estimate.
    """
    seconds = max(0.0, float(seconds))
    if seconds == 0.0:
        return 0, 0.0, _container_duration(path)
    try:
        mtime_ns = os.stat(path).st_mtime_ns
    except OSError:
        return None
    return _probe_seek_point(str(path), mtime_ns, seconds)


def _linear_seek_point(path, seconds):
    """Byte offset for *seconds* when FFprobe cannot answer: ``size x t / duration``.

    Only a fallback - the estimate can land between keyframes, which is why the keyframe
    scan is tried first - and None when even the duration is unknown.
    """
    try:
        size = os.stat(path).st_size
    except OSError:
        return None
    duration = _container_duration(path)
    if not duration or size <= 0:
        return None
    seconds = max(0.0, float(seconds))
    offset = max(0, min(int(size * seconds / duration), size - 1))
    return offset, seconds, duration


def _time_seek_response(path):
    """A 206 answer to a DLNA ``TimeSeekRange`` request, or None to stream normally.

    A request that also carries ``Range`` is left alone: that is the byte-range path
    every other client uses. The response header reports the range actually served
    (always to the end of the file), which is how the renderer learns where it landed.
    """
    if request.headers.get('Range') or not request.headers.get(DLNA_TIME_SEEK_HEADER):
        return None
    seconds = _parse_npt_start(request.headers.get(DLNA_TIME_SEEK_HEADER))
    if seconds is None:
        return None
    point = _seek_point_for_time(path, seconds) or _linear_seek_point(path, seconds)
    if point is None:
        return None
    offset, start, duration = point
    if not duration:
        # Without a duration the response cannot declare the range it serves, and a
        # renderer that is told nothing is better off with the plain stream.
        return None

    environ = dict(request.environ)
    environ['HTTP_RANGE'] = f'bytes={offset}-'
    # A time seek is not a conditional request: an If-Range/If-None-Match the renderer
    # aimed at the whole file must not turn this slice into a 200 or a 304.
    for header in ('HTTP_IF_RANGE', 'HTTP_IF_NONE_MATCH', 'HTTP_IF_MODIFIED_SINCE'):
        environ.pop(header, None)
    response = send_file_for_environ(
        path, environ, mimetype=mimetype(path), conditional=True, etag=True, max_age=3600,
    )
    response.headers[DLNA_TIME_SEEK_HEADER] = f'npt={start:.3f}-{duration:.3f}/{duration:.3f}'
    return response


@media_bp.route('/media/<path:filename>')
def media(filename):
    """Stream raw media file with full HTTP Range byte range support.

    DLNA renderers additionally read ``contentFeatures.dlna.org`` before they enable
    their transport buttons and ask for positions in play time instead of bytes; both
    are handled here without changing anything for a browser or the app.
    """
    path = safe_path(filename)
    if not is_video(path):
        abort(404)
    response = _time_seek_response(path)
    if response is None:
        response = send_file(path, mimetype=mimetype(path), conditional=True, etag=True, max_age=3600)
    response.headers[DLNA_CONTENT_FEATURES_HEADER] = DLNA_CONTENT_FEATURES
    response.headers[DLNA_TRANSFER_MODE_HEADER] = 'Streaming'
    return response


@media_bp.route('/transcode/<path:filename>')
def transcode(filename):
    """Create and serve a browser-safe MP4 with byte range support."""
    path = safe_path(filename)
    if not is_video(path):
        abort(404)
    if not check_which('ffmpeg'):
        return jsonify(error='FFmpeg is not installed; this file cannot be converted.'), 503

    mode = 'compat' if request.args.get('compat') == '1' else 'direct'
    cached = transcode_cache_path(path, mode)
    progress_path = transcode_progress_path(path, mode)
    if cached.is_file() and cached.stat().st_size:
        return send_file(cached, mimetype='video/mp4', conditional=True, max_age=3600)

    lock_key = f'{filename}:{mode}'
    lock = config.TRANSCODE_LOCKS.setdefault(lock_key, threading.Lock())
    lock.acquire()
    temporary = cached.with_name(cached.stem + '.part.mp4')
    config.ACTIVE_DIRECT_TRANSCODES[lock_key] = {
        'filename': filename,
        'mode': mode,
        'started_at': time.time(),
        'path': path,
        'progress_path': progress_path,
    }
    try:
        cached.parent.mkdir(parents=True, exist_ok=True)
        streams = probe_media(path).get('streams', [])
        video = next((s for s in streams if s.get('codec_type') == 'video'), {})
        audio = next((s for s in streams if s.get('codec_type') == 'audio'), {})
        input_args = []
        amf = config.is_amf_enabled()
        vaapi = config.is_vaapi_enabled()
        if mode == 'compat':
            if amf:
                adapter = os.environ.get("MEDIA_SERVER_AMF_ADAPTER", "1")
                input_args = [
                    '-init_hw_device', f'd3d11va=dx11:{adapter}',
                    '-init_hw_device', 'amf=amf@dx11',
                    '-filter_hw_device', 'amf',
                    '-hwaccel', 'd3d11va',
                    '-hwaccel_device', str(adapter)
                ]
                video_args = compat_transcode_args(amf_available=True)
            elif vaapi:
                dev = os.environ.get("MEDIA_SERVER_VAAPI_DEVICE", "/dev/dri/renderD128")
                input_args = ['-vaapi_device', dev, '-hwaccel', 'vaapi', '-hwaccel_device', dev]
                video_args = compat_transcode_args(vaapi_available=True)
            else:
                input_args = []
                video_args = compat_transcode_args()
        elif video.get('codec_name') in {'h264', 'hevc'}:
            video_args = ['-c:v', 'copy']
            if video.get('codec_name') == 'hevc':
                video_args += ['-tag:v', 'hvc1']
        else:
            video_args = compat_transcode_args()
        audio_args = ['-c:a', 'copy'] if audio.get('codec_name') == 'aac' else ['-c:a', 'aac']
        subprocess.run(
            ['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error']
            + input_args
            + ['-i', str(path), '-map', '0:v:0', '-map', '0:a?']
            + video_args
            + audio_args
            + [
                '-movflags', '+frag_keyframe+empty_moov+default_base_moof',
                '-progress', str(progress_path),
                '-nostats', str(temporary)
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
        )
        temporary.replace(cached)
    except (OSError, subprocess.CalledProcessError):
        progress_path.unlink(missing_ok=True)
        return jsonify(error='The media conversion failed.'), 500
    finally:
        config.ACTIVE_DIRECT_TRANSCODES.pop(lock_key, None)
        lock.release()
        progress_path.unlink(missing_ok=True)
    return send_file(cached, mimetype='video/mp4', conditional=True, max_age=3600)


@media_bp.route('/hls/<path:filename>/playlist.m3u8')
def hls_playlist(filename):
    """Serve HLS master playlist for the requested video, initiating transcode if needed."""
    path = safe_path(filename)
    if not is_video(path):
        abort(404)
    directory = hls_cache_dir(path)
    playlist = directory / 'playlist.m3u8'
    proc = ensure_hls_transcode(filename)
    deadline = time.time() + 2.0
    while time.time() < deadline:
        if playlist.is_file() and 'segment_' in playlist.read_text(errors='replace'):
            break
        if proc is not None and proc.poll() is not None:
            break
        time.sleep(0.05)
    if not playlist.is_file():
        return Response('#EXTM3U\n#EXT-X-VERSION:3\n', mimetype='application/vnd.apple.mpegurl')
    try:
        reconcile_hls_playlist_discontinuities(directory, path)
    except Exception:
        pass
    return send_file(playlist, mimetype='application/vnd.apple.mpegurl', max_age=0)


@media_bp.route('/hls/<path:filename>/<segment>')
def hls_segment(filename, segment):
    """Serve individual HLS transport stream (.ts) or initialization segment."""
    path = safe_path(filename)
    if not is_video(path) or not re.fullmatch(r'(?:init\.mp4|segment_\d{6}\.(?:m4s|ts))', segment):
        abort(404)
    target = hls_cache_dir(path) / segment
    if not target.is_file():
        abort(404)
    seg_mimetype = 'video/mp2t' if segment.endswith('.ts') else 'video/mp4'
    return send_file(target, mimetype=seg_mimetype, max_age=3600)


@media_bp.route('/api/seek-preview-meta/<path:filename>')
def seek_preview_meta(filename):
    """Return seek-preview sampling metadata without generating all thumbnails."""
    path = safe_path(filename)
    if not is_video(path):
        abort(404)
    meta = preview_meta(path)
    if not meta:
        return jsonify(error='Unable to determine media duration.'), 404
    return jsonify(
        duration=meta['duration'],
        interval=meta['interval'],
        count=meta['count'],
        base_url=f'/seek-preview/{filename}',
    )


@media_bp.route('/seek-preview/<path:filename>/<thumb>')
def seek_preview_thumbnail(filename, thumb):
    """Generate and serve one seek-bar preview thumbnail on demand."""
    path = safe_path(filename)
    match = re.fullmatch(r'thumb_(\d{5})\.jpg', thumb)
    if not is_video(path) or not match:
        abort(404)
    target = ensure_preview_thumbnail(path, int(match.group(1)))
    if target is None:
        abort(404)
    return send_file(target, mimetype='image/jpeg', max_age=86400, conditional=True, etag=True)

