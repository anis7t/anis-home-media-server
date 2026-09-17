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
from app.services.transcode_service import (
    _is_hls_truly_complete,
    get_active_transcodes,
    hls_cache_dir,
    transcode_cache_path,
    transcode_progress_path,
)
from app.services.system_service import get_system_telemetry
from app.utils.filesystem import get_rel_path, is_video, safe_path

api_bp = Blueprint('api', __name__)


def check_which(cmd):
    """Resolve binary path with support for test patches on app.which."""
    if 'app' in sys.modules and hasattr(sys.modules['app'], 'which'):
        app_which = sys.modules['app'].which
        if app_which != shutil_which:
            return app_which(cmd)
    return shutil_which(cmd)


@api_bp.route('/api/scan', methods=['GET', 'POST'])
def api_scan():
    """Trigger library filesystem scan and TMDB metadata refresh, reporting scanner state."""
    started = trigger_library_scan(refresh_metadata=True, force_refresh=True)
    return jsonify(
        status="scanning" if started or config.SCANNER_LOCK.locked() else "idle",
        busy=config.SCANNER_LOCK.locked()
    )


@api_bp.route('/api/media-info/<path:filename>')
def media_info(filename):
    """Inspect technical media details, codecs, dimensions, and capability report."""
    path = safe_path(filename)
    if not is_video(path):
        abort(404)
    probe_data = probe_media(path)
    format_data = probe_data.get('format', {})
    try:
        duration = float(format_data.get('duration') or 0)
    except (TypeError, ValueError):
        duration = 0
    video_stream = next((s for s in probe_data.get('streams', []) if s.get('codec_type') == 'video'), {})
    probe = check_which('ffprobe')
    return jsonify(
        container=path.suffix[1:].lower(),
        duration=duration,
        video_codec=video_stream.get('codec_name', ''),
        width=video_stream.get('width'),
        height=video_stream.get('height'),
        direct_play=path.suffix.lower() in {'.mp4', '.m4v', '.webm'},
        ffprobe_available=bool(probe),
        transcoding_available=bool(check_which('ffmpeg')),
        reason=(
            'Codec inspection unavailable: install ffprobe for a precise compatibility report.'
            if not probe
            else 'Direct play is preferred; codec inspection can be extended without changing media files.'
        )
    )


@api_bp.route('/api/transcode-status/<path:filename>')
def transcode_status(filename):
    """Query conversion progress, percentage, ETA, and speed for requested movie."""
    path = safe_path(filename)
    if not is_video(path):
        abort(404)
    req_mode = request.args.get('mode')
    if not req_mode:
        req_mode = 'compat' if request.args.get('compat') == '1' else 'direct'
    proc = config.HLS_PROCESSES.get(filename)
    if proc is not None and getattr(proc, 'hls_dir', None) is not None:
        hls_dir = proc.hls_dir
    else:
        hls_dir = hls_cache_dir(path)
    hls_progress = hls_dir / 'hls.progress'
    hls_playlist_file = hls_dir / 'playlist.m3u8'
    hls_running = proc is not None and proc.poll() is None
    hls_complete = _is_hls_truly_complete(hls_playlist_file, path)

    is_hls = (req_mode == 'hls') or (req_mode != 'compat' and (hls_running or hls_complete or hls_progress.is_file()))
    if is_hls:
        if hls_complete:
            bytes_val = sum(p.stat().st_size for p in hls_dir.glob('segment_*.*')) if hls_dir.is_dir() else 0
            try:
                dur_val = float(probe_media(path).get('format', {}).get('duration') or 0)
            except (TypeError, ValueError):
                dur_val = 0
            return jsonify(status='ready', bytes=bytes_val, percent=100, remaining=0, encoded=dur_val, duration=dur_val, speed=0)
        prog_file = hls_progress
    else:
        cached = transcode_cache_path(path, req_mode)
        part = cached.with_name(cached.stem + '.part.mp4')
        if cached.is_file() and cached.stat().st_size:
            try:
                dur_val = float(probe_media(path).get('format', {}).get('duration') or 0)
            except (TypeError, ValueError):
                dur_val = 0
            return jsonify(status='ready', bytes=cached.stat().st_size, percent=100, remaining=0, encoded=dur_val, duration=dur_val, speed=0)
        prog_file = transcode_progress_path(path, req_mode)

    values = {}
    if prog_file and prog_file.is_file():
        for line in prog_file.read_text(errors='replace').splitlines():
            if '=' in line:
                key, value_text = line.split('=', 1)
                values[key] = value_text.strip()
    try:
        duration = float(probe_media(path).get('format', {}).get('duration') or 0)
    except (TypeError, ValueError):
        duration = 0
    try:
        encoded = float(values.get('out_time_ms', 0)) / 1_000_000
    except (TypeError, ValueError):
        encoded = 0
    if is_hls and hls_playlist_file.is_file():
        try:
            pl_text = hls_playlist_file.read_text(errors='replace')
            pl_dur = sum(float(m.group(1)) for m in re.finditer(r'^#EXTINF:([\d.]+)', pl_text, re.MULTILINE))
            if pl_dur > encoded:
                encoded = pl_dur
        except Exception:
            pass
    try:
        speed = float(values.get('speed', '0x').rstrip('x'))
    except (TypeError, ValueError):
        speed = 0
    percent = min(99, round(encoded / duration * 100, 1)) if duration else 0
    remaining = max(0, (duration - encoded) / speed) if speed else None

    if is_hls:
        bytes_val = sum(p.stat().st_size for p in hls_dir.glob('segment_*.*')) if hls_dir.is_dir() else 0
        status = (
            'building'
            if (hls_running or (hls_progress.is_file() and not hls_complete))
            else ('ready' if hls_complete else 'idle')
        )
    else:
        bytes_val = part.stat().st_size if part.is_file() else 0
        status = 'building' if (prog_file and prog_file.is_file()) else ('partial' if part.is_file() else 'idle')
    return jsonify(
        status=status,
        bytes=bytes_val,
        percent=percent,
        remaining=remaining,
        encoded=encoded,
        duration=duration,
        speed=speed
    )


@api_bp.route('/api/progress', methods=['GET', 'POST'])
def progress():
    """Retrieve or persist playback watch progress for a movie."""
    if request.method == 'GET':
        filename = request.args.get('filename', '')
        path = safe_path(filename)
        if not is_video(path):
            abort(404)
        db = get_db()
        row = db.execute('SELECT position,duration FROM progress WHERE filename=?', (filename,)).fetchone()
        db.close()
        return jsonify(position=value(row, 'position', 0), duration=value(row, 'duration', 0))

    data = request.get_json(silent=True) or {}
    filename = data.get('filename', '')
    path = safe_path(filename)
    if not is_video(path):
        abort(404)
    try:
        position = max(0, float(data.get('position', 0)))
        duration = max(0, float(data.get('duration', 0)))
    except (TypeError, ValueError):
        return jsonify(error='Invalid progress'), 400
    if duration:
        position = min(position, duration)
    db = get_db()
    db.execute(
        'INSERT INTO progress(filename,position,duration) VALUES(?,?,?) '
        'ON CONFLICT(filename) DO UPDATE SET position=excluded.position,duration=excluded.duration,updated_at=CURRENT_TIMESTAMP',
        (filename, position, duration)
    )
    db.commit()
    db.close()

    try:
        from app.services.device_service import register_device_request, record_device_watch
        dev_id, _ = register_device_request(request)
        record_device_watch(dev_id, filename, position, duration)
    except Exception:
        pass

    return jsonify(success=True)


@api_bp.route('/api/transcodes')
def api_transcodes():
    """Return JSON array of all currently active background transcodes."""
    return jsonify(transcodes=get_active_transcodes())


@api_bp.route('/api/system-status')
def api_system_status():
    """Return real-time hardware telemetry and load statistics."""
    return jsonify(get_system_telemetry())


@api_bp.route('/poster/<path:filename>')
def poster(filename):
    """Serve locally stored poster image from MEDIA_ROOT."""
    path = safe_path(filename)
    if not path.is_file() or path.suffix.lower() not in config.POSTER_EXTENSIONS:
        abort(404)
    return send_file(path, conditional=True, max_age=86400)


def _send_cached_image(path):
    if not path.is_file():
        abort(404)
    return send_file(path, conditional=True, max_age=86400)


@api_bp.route('/tmdb-poster/<int:tmdb_id>')
def tmdb_poster(tmdb_id):
    """Serve cached TMDB poster, downloading on-demand if missing."""
    target = config.POSTER_CACHE / f'{tmdb_id}.jpg'
    if not target.is_file():
        db = get_db()
        row = db.execute('SELECT poster_path FROM movies WHERE tmdb_id=?', (tmdb_id,)).fetchone()
        db.close()
        if row and value(row, 'poster_path'):
            try:
                import posters
                posters.download_poster(tmdb_id, row['poster_path'])
            except Exception:
                pass
    return _send_cached_image(target)


@api_bp.route('/tmdb-backdrop/<int:tmdb_id>')
def tmdb_backdrop(tmdb_id):
    """Serve cached TMDB backdrop image, downloading on-demand if missing."""
    target = config.BACKDROP_CACHE / f'{tmdb_id}.jpg'
    if not target.is_file():
        db = get_db()
        row = db.execute('SELECT backdrop_path FROM movies WHERE tmdb_id=?', (tmdb_id,)).fetchone()
        db.close()
        if row and value(row, 'backdrop_path'):
            try:
                import posters
                posters.download_poster(tmdb_id, row['backdrop_path'], backdrop=True)
            except Exception:
                pass
    return _send_cached_image(target)


@api_bp.route('/api/upload', methods=['POST'])
def upload():
    """Upload media file, save to MEDIA_ROOT, and run all new-media tasks."""
    if 'file' not in request.files:
        return jsonify(error="No file uploaded. Please select a video file."), 400

    file = request.files['file']
    if not file or not file.filename:
        return jsonify(error="No file selected for upload."), 400

    # Sanitize filename while preserving characters needed for title parsing
    raw_name = Path(file.filename).name
    clean_name = re.sub(r'[/\\:\x00]', '', raw_name).strip()
    if not clean_name or clean_name in {'.', '..'}:
        return jsonify(error="Invalid filename provided."), 400

    suffix = Path(clean_name).suffix.lower()
    if suffix not in config.VIDEO_EXTENSIONS:
        allowed = ", ".join(sorted(config.VIDEO_EXTENSIONS))
        return jsonify(error=f"Unsupported video format '{suffix}'. Allowed formats: {allowed}"), 400

    # Custom title override (e.g. from mobile devices uploading numeric IDs like 1000403712.mkv)
    custom_title = request.form.get('title', '').strip()
    if custom_title:
        safe_title = re.sub(r'[/\\:\x00*?"<>|]', ' ', custom_title).strip()
        safe_title = re.sub(r'\s+', ' ', safe_title)
        if safe_title:
            clean_name = f"{safe_title}{suffix}"

    overwrite = request.form.get('overwrite', '').lower() in {'1', 'true', 'yes'}
    config.MEDIA_ROOT.mkdir(parents=True, exist_ok=True)
    target_path = (config.MEDIA_ROOT / clean_name).resolve()

    if not str(target_path).startswith(str(config.MEDIA_ROOT.resolve())):
        return jsonify(error="Illegal destination path."), 400

    if target_path.exists() and not overwrite:
        stem = Path(clean_name).stem
        counter = 1
        while target_path.exists():
            candidate_name = f"{stem} ({counter}){suffix}"
            target_path = (config.MEDIA_ROOT / candidate_name).resolve()
            counter += 1
        clean_name = target_path.name

    # Atomic write: stream to hidden .upload_<target_name>.part file first to protect memory
    # and prevent background transcode loop or scanner from accessing partially written media
    part_path = target_path.with_name(f".upload_{target_path.name}.part")
    try:
        with open(part_path, 'wb') as out_f:
            shutil.copyfileobj(file.stream, out_f, length=64 * 1024)
            out_f.flush()
            os.fsync(out_f.fileno())
        part_path.replace(target_path)
    except Exception as e:
        part_path.unlink(missing_ok=True)
        return jsonify(error=f"Failed to write uploaded media to disk: {e}"), 500

    # 1. Invalidate paths cache so video_paths() immediately reflects the new media
    import app.services.media_service as media_service
    media_service._paths = (0, [])
    if 'app' in sys.modules and hasattr(sys.modules['app'], '_paths'):
        sys.modules['app']._paths = (0, [])

    # 2. Run TMDB metadata scanning and enrichment
    import scanner
    scanned_details = None
    try:
        scanned_details = scanner.scan_single_file(target_path)
    except Exception as e:
        logger.warning(f"Scan single file during upload error: {e}")
        scanned_details = None

    rel_filename = get_rel_path(target_path)
    parsed_title, parsed_year = scanner.parse_filename(target_path)

    # 3. Fallback database registration in SQLite if TMDB had no match or was offline
    if not scanned_details:
        try:
            db = get_db()
            db.execute(
                "INSERT OR IGNORE INTO movies (filename, title, year, updated_at) VALUES (?, ?, ?, ?)",
                (rel_filename, parsed_title, parsed_year, int(time.time()))
            )
            db.commit()
            db.close()
        except Exception:
            pass

    # 4. Trigger library scan sync
    trigger_library_scan()

    # 5. Check if transcode is required (MKV / HEVC / non-web containers)
    from app.services.transcode_service import needs_transcode, ensure_hls_transcode
    transcode_started = False
    if needs_transcode(target_path):
        try:
            ensure_hls_transcode(rel_filename)
            transcode_started = True
        except Exception:
            pass

    # 6. Automatic subtitle detection and online pre-fetching
    from app.services.subtitles_service import tracks
    try:
        threading.Thread(
            target=tracks,
            args=(target_path, scanned_details),
            name="sub-prefetch",
            daemon=True
        ).start()
    except Exception:
        pass

    display_title = (scanned_details.get("title") if scanned_details else None) or parsed_title
    raw_year = (scanned_details.get("release_date", "")[:4] if (scanned_details and scanned_details.get("release_date")) else None) or parsed_year
    try:
        display_year = int(raw_year) if raw_year else None
    except (ValueError, TypeError):
        display_year = raw_year

    return jsonify(
        success=True,
        filename=rel_filename,
        title=display_title,
        year=display_year,
        needs_transcode=transcode_started,
        details_url=f"/movie/{rel_filename}"
    )


@api_bp.route('/api/media/<path:filename>', methods=['DELETE'])
@api_bp.route('/api/media/delete/<path:filename>', methods=['POST'])
def api_delete_media(filename):
    """Permanently delete a media item and purge all associated metadata, caches, and streams."""
    from app.services.media_service import purge_media
    try:
        res = purge_media(filename)
        return jsonify(res), 200
    except Exception as e:
        return jsonify(success=False, error=str(e)), 500


@api_bp.route('/api/devices')
def api_devices():
    """Return JSON list of all tracked devices, network metadata, and watch history."""
    from app.services.device_service import get_all_devices, register_device_request
    current_dev_id, _ = register_device_request(request)
    devices, stats = get_all_devices(current_device_id=current_dev_id)
    return jsonify(devices=devices, stats=stats, current_device_id=current_dev_id)


@api_bp.route('/api/devices/rename', methods=['POST'])
def api_devices_rename():
    """Rename a device with a custom friendly label."""
    data = request.get_json(silent=True) or {}
    device_id = data.get('device_id', '').strip()
    name = data.get('name', '').strip()
    if not device_id:
        return jsonify(error="device_id is required"), 400
    from app.services.device_service import rename_device
    rename_device(device_id, name)
    return jsonify(success=True)


@api_bp.route('/api/devices/delete', methods=['POST'])
def api_devices_delete():
    """Remove a device and its recorded watch history."""
    data = request.get_json(silent=True) or {}
    device_id = data.get('device_id', '').strip()
    if not device_id:
        return jsonify(error="device_id is required"), 400
    from app.services.device_service import delete_device
    delete_device(device_id)
    res = jsonify(success=True)
    if request.cookies.get('ms_device_id') == device_id:
        res.delete_cookie('ms_device_id', path='/')
    return res


@api_bp.route('/api/devices/heartbeat', methods=['POST', 'GET'])
def api_devices_heartbeat():
    """Receive lightweight client keepalive ping and update device last_seen."""
    from app.services.device_service import record_device_heartbeat
    dev_id = record_device_heartbeat(request)
    return jsonify(success=True, device_id=dev_id)


@api_bp.route('/api/devices/client-hints', methods=['POST'])
def api_devices_client_hints():
    """Receive client-side high-entropy userAgentData (model, platform, platformVersion)."""
    data = request.get_json(silent=True) or {}
    model = data.get('model')
    platform = data.get('platform')
    platform_version = data.get('platformVersion')

    from app.services.device_service import get_or_create_device_id, update_device_client_hints
    device_id, _ = get_or_create_device_id(request)
    updated = update_device_client_hints(device_id, model=model, platform=platform, platform_version=platform_version)
    return jsonify(success=True, updated=updated, device_id=device_id)


_ALLOWED_SUBTITLE_EXTS = {'.srt', '.vtt'}


@api_bp.route('/api/upload-subtitle/<path:filename>', methods=['POST'])
def api_upload_subtitle(filename):
    """Accept a subtitle file upload, auto-detect its language, and save it next to the media.

    Saved filename format: ``<short_movie_name>_<lang>_<n><ext>``
    e.g. ``moana_en_1.srt``, ``the_odyssey_fr_2.vtt``.
    """
    from app.utils.subtitles import detect_subtitle_language, get_short_movie_name

    # --- Validate target media exists ---
    media_path = safe_path(filename)
    if not media_path or not media_path.is_file():
        return jsonify(success=False, error='Media file not found.'), 404

    # --- Validate uploaded file ---
    sub_file = request.files.get('subtitle')
    if not sub_file or not sub_file.filename:
        return jsonify(success=False, error='No subtitle file provided.'), 400

    upload_ext = Path(sub_file.filename).suffix.lower()
    if upload_ext not in _ALLOWED_SUBTITLE_EXTS:
        return jsonify(
            success=False,
            error=f'Unsupported format "{upload_ext}". Only .srt and .vtt are accepted.'
        ), 415

    # --- Read content & detect language ---
    try:
        raw_bytes = sub_file.read()
        text = raw_bytes.decode('utf-8', errors='replace')
    except Exception as exc:
        logger.exception('Failed to read subtitle upload: %s', exc)
        return jsonify(success=False, error='Could not read the uploaded file.'), 500

    lang = detect_subtitle_language(text)

    # --- Determine save path with incremental counter ---
    short_name = get_short_movie_name(media_path)
    dest_dir = media_path.parent
    counter = 1
    while True:
        dest_name = f'{short_name}_{lang}_{counter}{upload_ext}'
        dest_path = dest_dir / dest_name
        if not dest_path.exists():
            break
        counter += 1

    try:
        dest_path.write_bytes(raw_bytes)
    except OSError as exc:
        logger.exception('Failed to write subtitle file %s: %s', dest_path, exc)
        return jsonify(success=False, error='Could not save the subtitle file on the server.'), 500

    logger.info('Subtitle uploaded: %s  lang=%s', dest_path, lang)
    return jsonify(
        success=True,
        filename=dest_name,
        language=lang,
        path=str(dest_path),
    )


# ---------------------------------------------------------------------------
# Storage Retention & Cache Purge Endpoints
# ---------------------------------------------------------------------------

@api_bp.route('/api/storage/audit', methods=['GET'])
def storage_audit():
    """Audit HLS and preview cache directories for active vs orphaned status."""
    from app.services.transcode_service import audit_orphaned_caches
    from app.services.system_service import get_system_telemetry

    audit_data = audit_orphaned_caches()
    telemetry = get_system_telemetry()
    storage = telemetry.get('storage', {})

    return jsonify({
        'storage': storage,
        'audit': audit_data,
    })


@api_bp.route('/api/storage/purge-orphans', methods=['POST'])
def storage_purge_orphans():
    """Purge all safely verified orphaned transcode caches."""
    from app.services.transcode_service import purge_orphaned_caches

    dry_run = (
        request.args.get('dry_run') in ('1', 'true', 'yes')
        or (request.is_json and request.get_json(silent=True) and request.get_json().get('dry_run') is True)
    )
    res = purge_orphaned_caches(dry_run=dry_run)
    return jsonify({
        'success': True,
        'result': res,
    })


@api_bp.route('/api/storage/settings', methods=['GET', 'POST'])
def storage_settings():
    """Get or update post-transcode storage retention settings."""
    from app.db import get_setting, set_setting

    if request.method == 'POST':
        data = request.get_json(silent=True) or request.form or {}
        policy = data.get('retention_policy')
        if not policy or policy not in config.ALLOWED_RETENTION_POLICIES:
            return jsonify({
                'success': False,
                'error': f'Invalid retention policy. Allowed: {sorted(list(config.ALLOWED_RETENTION_POLICIES))}',
            }), 400

        set_setting('retention_policy', policy)
        return jsonify({
            'success': True,
            'retention_policy': policy,
        })

    current_policy = get_setting('retention_policy', config.DEFAULT_RETENTION_POLICY)
    return jsonify({
        'retention_policy': current_policy,
        'allowed_policies': sorted(list(config.ALLOWED_RETENTION_POLICIES)),
        'archive_dir': str(config.ARCHIVE_DIR),
    })


@api_bp.route('/api/storage/archive/<path:filename>', methods=['POST'])
def storage_archive_media(filename):
    """Manually move an original media source to ARCHIVE_DIR if its HLS transcode is complete."""
    from app.services.transcode_service import apply_post_transcode_policy

    media_path = safe_path(filename)
    if not media_path or not media_path.is_file():
        return jsonify({'success': False, 'error': 'Media file not found.'}), 404

    res = apply_post_transcode_policy(media_path, policy='archive')
    if res.get('status') == 'archived':
        return jsonify({'success': True, 'result': res})
    else:
        return jsonify({'success': False, 'result': res}), 400




