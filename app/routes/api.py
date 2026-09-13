"""JSON API endpoints and image asset routes."""
import json
import logging
import os
import re
import sys
import shutil
import threading
import time
from pathlib import Path
from shutil import which as shutil_which
from flask import Blueprint, abort, jsonify, request, send_file

from app import config
from app.db import get_db, value

logger = logging.getLogger(__name__)
from app.services.media_service import probe_media
from app.services.scanner_service import trigger_library_scan
from app.services.tmdb_service import download_poster
from app.services.preview_service import ensure_preview
from app.services.transcode_service import (_is_hls_truly_complete, get_active_transcodes, hls_cache_dir, transcode_cache_path, transcode_progress_path)
from app.services.system_service import get_system_telemetry
from app.utils.filesystem import is_video, safe_path

api_bp = Blueprint('api', __name__)


def check_which(cmd):
    if 'app' in sys.modules and hasattr(sys.modules['app'], 'which'):
        app_which = sys.modules['app'].which
        if app_which != shutil_which: return app_which(cmd)
    return shutil_which(cmd)


@api_bp.route('/api/scan', methods=['GET', 'POST'])
def api_scan():
    started = trigger_library_scan(); return jsonify(status="scanning" if started or config.SCANNER_LOCK.locked() else "idle", busy=config.SCANNER_LOCK.locked())


@api_bp.route('/api/media-info/<path:filename>')
def media_info(filename):
    path = safe_path(filename)
    if not is_video(path): abort(404)
    probe_data = probe_media(path); format_data = probe_data.get('format', {})
    try: duration = float(format_data.get('duration') or 0)
    except (TypeError, ValueError): duration = 0
    video_stream = next((s for s in probe_data.get('streams', []) if s.get('codec_type') == 'video'), {}); probe = check_which('ffprobe')
    return jsonify(container=path.suffix[1:].lower(), duration=duration, video_codec=video_stream.get('codec_name', ''), width=video_stream.get('width'), height=video_stream.get('height'), direct_play=path.suffix.lower() in {'.mp4', '.m4v', '.webm'}, ffprobe_available=bool(probe), transcoding_available=bool(check_which('ffmpeg')), reason=('Codec inspection unavailable: install ffprobe for a precise compatibility report.' if not probe else 'Direct play is preferred; codec inspection can be extended without changing media files.'))


@api_bp.route('/api/seek-preview-meta/<path:filename>')
def seek_preview_meta(filename):
    path = safe_path(filename)
    if not is_video(path): abort(404)
    try:
        duration = float(probe_media(path).get('format', {}).get('duration') or 0)
    except (TypeError, ValueError):
        duration = 0
    if duration <= 0:
        return jsonify(error='Unable to determine media duration.'), 404
    interval = 10.0 if duration < 3600 else 15.0
    count = int(duration // interval) + 1
    if ensure_preview(path) is None:
        return jsonify(error='Preview generation unavailable.'), 503
    return jsonify(interval=interval, count=count, duration=duration, base_url=f'/seek-preview/{filename}')


@api_bp.route('/api/transcode-status/<path:filename>')
def transcode_status(filename):
    path = safe_path(filename)
    if not is_video(path): abort(404)
    req_mode = request.args.get('mode') or ('compat' if request.args.get('compat') == '1' else 'direct')
    proc = config.HLS_PROCESSES.get(filename); hls_dir = proc.hls_dir if proc is not None and getattr(proc, 'hls_dir', None) is not None else hls_cache_dir(path)
    hls_progress = hls_dir / 'hls.progress'; hls_playlist_file = hls_dir / 'playlist.m3u8'; hls_running = proc is not None and proc.poll() is None; hls_complete = _is_hls_truly_complete(hls_playlist_file, path)
    is_hls = req_mode == 'hls' or (req_mode != 'compat' and (hls_running or hls_complete or hls_progress.is_file()))
    if is_hls:
        if hls_complete:
            bytes_val = sum(p.stat().st_size for p in hls_dir.glob('segment_*.*')) if hls_dir.is_dir() else 0
            try: dur_val = float(probe_media(path).get('format', {}).get('duration') or 0)
            except (TypeError, ValueError): dur_val = 0
            return jsonify(status='ready', bytes=bytes_val, percent=100, remaining=0, encoded=dur_val, duration=dur_val, speed=0)
        prog_file = hls_progress
    else:
        cached = transcode_cache_path(path, req_mode); part = cached.with_name(cached.stem + '.part.mp4')
        if cached.is_file() and cached.stat().st_size:
            try: dur_val = float(probe_media(path).get('format', {}).get('duration') or 0)
            except (TypeError, ValueError): dur_val = 0
            return jsonify(status='ready', bytes=cached.stat().st_size, percent=100, remaining=0, encoded=dur_val, duration=dur_val, speed=0)
        prog_file = transcode_progress_path(path, req_mode)
    values = {}
    if prog_file and prog_file.is_file():
        for line in prog_file.read_text(errors='replace').splitlines():
            if '=' in line: key, value_text = line.split('=', 1); values[key] = value_text.strip()
    try: duration = float(probe_media(path).get('format', {}).get('duration') or 0)
    except (TypeError, ValueError): duration = 0
    try: encoded = float(values.get('out_time_ms', 0)) / 1_000_000
    except (TypeError, ValueError): encoded = 0
    if is_hls and hls_playlist_file.is_file():
        try:
            pl_dur = sum(float(m.group(1)) for m in re.finditer(r'^#EXTINF:([\d.]+)', hls_playlist_file.read_text(errors='replace'), re.MULTILINE)); encoded = max(encoded, pl_dur)
        except Exception: pass
    try: speed = float(values.get('speed', '0x').rstrip('x'))
    except (TypeError, ValueError): speed = 0
    percent = min(99, round(encoded / duration * 100, 1)) if duration else 0; remaining = max(0, (duration - encoded) / speed) if speed else None
    if is_hls:
        bytes_val = sum(p.stat().st_size for p in hls_dir.glob('segment_*.*')) if hls_dir.is_dir() else 0; status = 'building' if (hls_running or (hls_progress.is_file() and not hls_complete)) else ('ready' if hls_complete else 'idle')
    else:
        bytes_val = part.stat().st_size if part.is_file() else 0; status = 'building' if (prog_file and prog_file.is_file()) else ('partial' if part.is_file() else 'idle')
    return jsonify(status=status, bytes=bytes_val, percent=percent, remaining=remaining, encoded=encoded, duration=duration, speed=speed)


@api_bp.route('/api/progress', methods=['GET', 'POST'])
def progress():
    from app.services.device_service import get_or_create_device_id, register_device_request, record_device_watch
    device_id, _ = get_or_create_device_id(request)
    if request.method == 'GET':
        filename = request.args.get('filename', ''); path = safe_path(filename)
        if not is_video(path): abort(404)
        db = get_db(); row = db.execute('SELECT position,duration FROM device_progress WHERE device_id=? AND filename=?', (device_id, filename)).fetchone()
        if row is None: row = db.execute('SELECT position,duration FROM progress WHERE filename=?', (filename,)).fetchone()
        db.close(); return jsonify(position=value(row, 'position', 0), duration=value(row, 'duration', 0), device_id=device_id)
    data = request.get_json(silent=True) or {}; filename = data.get('filename', ''); path = safe_path(filename)
    if not is_video(path): abort(404)
    try: position = max(0, float(data.get('position', 0))); duration = max(0, float(data.get('duration', 0)))
    except (TypeError, ValueError): return jsonify(error='Invalid progress'), 400
    if duration: position = min(position, duration)
    db = get_db(); db.execute('INSERT INTO device_progress(device_id,filename,position,duration) VALUES(?,?,?,?) ON CONFLICT(device_id,filename) DO UPDATE SET position=excluded.position,duration=excluded.duration,updated_at=CURRENT_TIMESTAMP', (device_id, filename, position, duration)); db.commit(); db.close()
    try: register_device_request(request); record_device_watch(device_id, filename, position, duration)
    except Exception: pass
    return jsonify(success=True, device_id=device_id)


@api_bp.route('/api/transcodes')
def api_transcodes():
    return jsonify(transcodes=get_active_transcodes())


@api_bp.route('/api/system-status')
def api_system_status():
    return jsonify(get_system_telemetry())


@api_bp.route('/poster/<path:filename>')
def poster(filename):
    path = safe_path(filename)
    if not path.is_file() or path.suffix.lower() not in config.POSTER_EXTENSIONS: abort(404)
    return send_file(path, conditional=True, max_age=86400)


def _send_cached_image(path):
    if not path.is_file(): abort(404)
    return send_file(path, conditional=True, max_age=86400)


@api_bp.route('/tmdb-poster/<int:tmdb_id>')
def tmdb_poster(tmdb_id):
    target = config.POSTER_CACHE / f'{tmdb_id}.jpg'
    if not target.is_file():
        db = get_db(); row = db.execute('SELECT poster_path FROM movies WHERE tmdb_id=?', (tmdb_id,)).fetchone(); db.close()
        if row and value(row, 'poster_path'):
            try: import posters; posters.download_poster(tmdb_id, row['poster_path'])
            except Exception: pass
    return _send_cached_image(target)


@api_bp.route('/tmdb-backdrop/<int:tmdb_id>')
def tmdb_backdrop(tmdb_id):
    target = config.BACKDROP_CACHE / f'{tmdb_id}.jpg'
    if not target.is_file():
        db = get_db(); row = db.execute('SELECT backdrop_path FROM movies WHERE tmdb_id=?', (tmdb_id,)).fetchone(); db.close()
        if row and value(row, 'backdrop_path'):
            try: import posters; posters.download_poster(tmdb_id, row['backdrop_path'], backdrop=True)
            except Exception: pass
    return _send_cached_image(target)
