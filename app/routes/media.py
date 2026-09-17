"""Media streaming, byte ranges, direct transcoding, and HLS routes."""
import os
import re
import subprocess
import sys
import threading
import time
from shutil import which as shutil_which
from flask import Blueprint, Response, abort, jsonify, request, send_file

from app import config
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


def check_which(cmd):
    """Resolve binary path with support for test patches on app.which."""
    if 'app' in sys.modules and hasattr(sys.modules['app'], 'which'):
        app_which = sys.modules['app'].which
        if app_which != shutil_which:
            return app_which(cmd)
    return shutil_which(cmd)


@media_bp.route('/media/<path:filename>')
def media(filename):
    """Stream raw media file with full HTTP Range byte range support."""
    path = safe_path(filename)
    if not is_video(path):
        abort(404)
    return send_file(path, mimetype=mimetype(path), conditional=True, etag=True, max_age=3600)


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

