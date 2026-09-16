"""Media inspection, technical specifications, and library metadata service."""
import json
import subprocess
import sys
import time
from pathlib import Path
from shutil import which

from app import config
from app.db import get_db, value
from app.utils.filesystem import is_video, safe_path
from app.utils.formatting import clean_title, format_bytes_display

# Cached video paths (timestamp, list_of_paths)
_paths = (0, [])


def probe_media(path):
    """Run ffprobe on path and return parsed json metadata."""
    # Test patch dynamic delegation
    if 'app' in sys.modules and hasattr(sys.modules['app'], 'probe_media'):
        app_mod = sys.modules['app']
        if app_mod.probe_media != probe_media:
            return app_mod.probe_media(path)

    probe = which('ffprobe')
    if not probe:
        return {}
    result = subprocess.run(
        [probe, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    try:
        return json.loads(result.stdout)
    except (json.JSONDecodeError, TypeError):
        return {}


def video_paths():
    """Discover all video files in MEDIA_ROOT with a 30-second in-memory cache and immediate change detection."""
    global _paths
    if 'app' in sys.modules and hasattr(sys.modules['app'], '_paths'):
        app_paths = sys.modules['app']._paths
        if app_paths != _paths:
            _paths = app_paths

    current = (
        sorted((p for p in config.MEDIA_ROOT.rglob('*') if is_video(p)), key=lambda p: str(getattr(p, 'name', p)).lower())
        if config.MEDIA_ROOT.exists()
        else []
    )
    if (
        time.monotonic() - _paths[0] > 30
        or len(current) != len(_paths[1])
        or {p.resolve() for p in current} != {p.resolve() for p in _paths[1]}
    ):
        if len(current) != len(_paths[1]) or {p.resolve() for p in current} != {p.resolve() for p in _paths[1]}:
            from app.services.scanner_service import trigger_library_scan
            trigger_library_scan()
        _paths = (time.monotonic(), current)
        if 'app' in sys.modules:
            sys.modules['app']._paths = _paths
    return _paths[1]


def poster_for(path, row):
    """Find local poster image file for a given video path or row."""
    db_poster = value(row, 'poster_path')
    if db_poster and not str(db_poster).startswith('tmdb:'):
        p = Path(db_poster)
        if p.exists():
            return f"local:{p.relative_to(config.MEDIA_ROOT).as_posix()}"
        return None
    for ext in config.POSTER_EXTENSIONS:
        p = path.with_suffix(ext)
        if p.is_file():
            return f"local:{p.relative_to(config.MEDIA_ROOT).as_posix()}"
    return None


def movie(path, db):
    """Build movie metadata dictionary for a video path combining database and filesystem data."""
    name = path.relative_to(config.MEDIA_ROOT).as_posix()
    meta = db.execute("SELECT * FROM movies WHERE filename=?", (name,)).fetchone()
    progress = db.execute("SELECT * FROM progress WHERE filename=?", (name,)).fetchone()
    pos = value(progress, 'position', 0)
    dur = value(progress, 'duration', 0)
    p = poster_for(path, meta) or (
        f"tmdb:{meta['tmdb_id']}"
        if meta and meta['tmdb_id'] and (config.POSTER_CACHE / f"{meta['tmdb_id']}.jpg").exists()
        else None
    )
    return dict(
        filename=name,
        path=path,
        title=value(meta, 'title', clean_title(path.name)),
        year=value(meta, 'year', ''),
        tmdb_id=value(meta, 'tmdb_id'),
        overview=value(meta, 'overview', ''),
        rating=value(meta, 'vote_average'),
        runtime=value(meta, 'runtime'),
        genres=value(meta, 'genres', ''),
        release_date=value(meta, 'release_date', ''),
        poster=p,
        position=pos,
        duration=dur,
        percent=min(100, pos / dur * 100) if dur else 0,
        updated_at=value(progress, 'updated_at', ''),
        backdrop_path=value(meta, 'backdrop_path', ''),
        details_json=value(meta, 'details_json', ''),
        last_metadata_refresh=value(meta, 'last_metadata_refresh')
    )


def get_movies():
    """Retrieve metadata dictionaries for all discovered video files in the library."""
    db = get_db()
    try:
        return [movie(p, db) for p in video_paths()]
    finally:
        db.close()


def extract_media_technical_specs(path, movie_meta=None):
    """Extract resolution, codecs, container, bitrate, and audio specs from media file."""
    from app.services.subtitles_service import tracks

    specs = {
        'resolution': '',
        'resolution_badge': '',
        'video_codec': '',
        'video_profile': '',
        'audio_codec': '',
        'audio_channels': '',
        'container': path.suffix[1:].upper() if path.suffix else '',
        'file_size': format_bytes_display(path.stat().st_size) if path.exists() else '',
        'bitrate': '',
        'subtitles': [],
        'aspect_ratio': ''
    }
    probe = probe_media(path)
    if not probe:
        return specs

    streams = probe.get('streams', [])
    fmt = probe.get('format', {})

    bit_rate = fmt.get('bit_rate')
    if bit_rate:
        try:
            br_num = int(bit_rate)
            if br_num >= 1_000_000:
                specs['bitrate'] = f"{br_num / 1_000_000:.1f} Mbps"
            else:
                specs['bitrate'] = f"{br_num // 1000} kbps"
        except (ValueError, TypeError):
            pass

    for s in streams:
        if s.get('codec_type') == 'video':
            codec = (s.get('codec_name') or '').lower()
            w = int(s.get('width') or 0)
            h = int(s.get('height') or 0)

            if w >= 3800 or h >= 2100:
                specs['resolution'] = '4K 2160p'
                specs['resolution_badge'] = '4K'
            elif w >= 1900 or h >= 1000:
                specs['resolution'] = '1080p'
                specs['resolution_badge'] = '1080p'
            elif w >= 1200 or h >= 700:
                specs['resolution'] = '720p'
                specs['resolution_badge'] = '720p'
            elif h >= 480:
                specs['resolution'] = '480p'
                specs['resolution_badge'] = 'SD'
            elif w and h:
                specs['resolution'] = f"{w}x{h}"
                specs['resolution_badge'] = 'SD'

            codec_map = {
                'hevc': 'HEVC (H.265)',
                'h264': 'H.264 (AVC)',
                'vp9': 'VP9',
                'av01': 'AV1',
                'av1': 'AV1',
                'mpeg4': 'MPEG-4',
                'vc1': 'VC-1'
            }
            specs['video_codec'] = codec_map.get(codec, codec.upper() if codec else 'Video')
            specs['aspect_ratio'] = s.get('display_aspect_ratio') or ''
            break

    for s in streams:
        if s.get('codec_type') == 'audio':
            acodec = (s.get('codec_name') or '').lower()
            channels = s.get('channels') or 0
            audio_map = {
                'eac3': 'Dolby Digital Plus',
                'ac3': 'Dolby Digital',
                'truehd': 'Dolby TrueHD',
                'dts': 'DTS',
                'dts-hd': 'DTS-HD',
                'aac': 'AAC',
                'flac': 'FLAC',
                'mp3': 'MP3',
                'opus': 'Opus',
                'vorbis': 'Vorbis'
            }
            specs['audio_codec'] = audio_map.get(acodec, acodec.upper() if acodec else 'Audio')
            chan_map = {1: '1.0 Mono', 2: '2.0 Stereo', 6: '5.1 Surround', 8: '7.1 Surround'}
            specs['audio_channels'] = chan_map.get(channels, f"{channels} ch" if channels else '')
            break

    try:
        sub_trks = tracks(path, movie_meta)
        specs['subtitles'] = [t['label'] for t in sub_trks]
    except Exception:
        specs['subtitles'] = []

    return specs


def purge_media(filename):
    """Permanently delete media file, transcode caches, subtitles, TMDb metadata, posters, and playback progress."""
    try:
        path = safe_path(filename)
    except Exception:
        path = config.MEDIA_ROOT / filename

    try:
        rel_filename = path.relative_to(config.MEDIA_ROOT).as_posix()
    except ValueError:
        rel_filename = str(filename)

    db = get_db()
    movie_row = db.execute("SELECT * FROM movies WHERE filename=?", (rel_filename,)).fetchone()
    progress_row = db.execute("SELECT * FROM progress WHERE filename=?", (rel_filename,)).fetchone()
    tmdb_id = value(movie_row, 'tmdb_id')
    poster_path = value(movie_row, 'poster_path')

    # 1. Stop active transcodes and capture HLS directory
    from app.services.transcode_service import (
        stop_transcodes_for_media,
        purge_transcode_caches_for_media,
        find_ffmpeg_info_for_path,
        hls_cache_dir,
    )
    known_hls_dir = None
    proc = config.HLS_PROCESSES.get(rel_filename)
    if proc and getattr(proc, 'hls_dir', None):
        known_hls_dir = proc.hls_dir
    if not known_hls_dir and path.exists():
        _, ext_hls_dir = find_ffmpeg_info_for_path(path)
        if ext_hls_dir:
            known_hls_dir = ext_hls_dir
    if not known_hls_dir and path.exists():
        try:
            known_hls_dir = hls_cache_dir(path)
        except Exception:
            pass

    stopped_pids = stop_transcodes_for_media(rel_filename, path)

    # 2. Purge transcode caches and HLS directory
    transcode_purge_info = purge_transcode_caches_for_media(path, known_hls_dir=known_hls_dir)

    # 3. Purge subtitle caches
    from app.services.subtitles_service import purge_subtitles_for_media
    purged_subs = purge_subtitles_for_media(path)

    # 3b. Purge seek preview thumbnail cache
    try:
        from app.services.preview_service import preview_dir
        import shutil
        p_dir = preview_dir(path)
        if p_dir.exists():
            shutil.rmtree(p_dir, ignore_errors=True)
    except Exception:
        pass

    # 4. Purge TMDb posters and backdrops if not referenced by other items
    purged_posters = []
    if tmdb_id:
        other = db.execute("SELECT 1 FROM movies WHERE tmdb_id=? AND filename != ?", (tmdb_id, rel_filename)).fetchone()
        if not other:
            cached_p = config.POSTER_CACHE / f"{tmdb_id}.jpg"
            if cached_p.is_file():
                cached_p.unlink(missing_ok=True)
                purged_posters.append(str(cached_p))
            cached_b = config.BACKDROP_CACHE / f"{tmdb_id}.jpg"
            if cached_b.is_file():
                cached_b.unlink(missing_ok=True)
                purged_posters.append(str(cached_b))

    if poster_path and str(poster_path).startswith('local:'):
        try:
            local_poster = config.MEDIA_ROOT / poster_path[6:]
            if local_poster.is_file():
                local_poster.unlink(missing_ok=True)
                purged_posters.append(str(local_poster))
        except Exception:
            pass

    if path.parent.is_dir():
        for ext in config.POSTER_EXTENSIONS:
            local_ext = path.with_suffix(ext)
            if local_ext.is_file():
                local_ext.unlink(missing_ok=True)
                purged_posters.append(str(local_ext))

    # 5. Purge database records
    db.execute("DELETE FROM movies WHERE filename=?", (rel_filename,))
    db.execute("DELETE FROM progress WHERE filename=?", (rel_filename,))
    db.commit()
    db.close()

    # 6. Delete media file on disk and any upload part files
    file_deleted = False
    if path.is_file():
        path.unlink(missing_ok=True)
        file_deleted = True

    part_a = path.with_name(f".upload_{path.name}.part")
    part_a.unlink(missing_ok=True)
    part_b = path.with_name(f"{path.name}.part")
    part_b.unlink(missing_ok=True)

    # If in subfolder, clean up if empty
    try:
        parent = path.parent
        if parent.resolve() != config.MEDIA_ROOT.resolve() and str(parent.resolve()).startswith(str(config.MEDIA_ROOT.resolve())):
            if not any(parent.iterdir()):
                parent.rmdir()
    except Exception:
        pass

    # 7. Invalidate paths cache
    global _paths
    _paths = (0, [])
    if 'app' in sys.modules and hasattr(sys.modules['app'], '_paths'):
        sys.modules['app']._paths = (0, [])

    from app.services.scanner_service import trigger_library_scan
    trigger_library_scan()

    return {
        'success': True,
        'filename': rel_filename,
        'file_deleted': file_deleted,
        'stopped_pids': stopped_pids,
        'purged_transcodes': transcode_purge_info,
        'purged_subtitles': purged_subs,
        'purged_posters': purged_posters,
        'tmdb_purged': bool(tmdb_id),
        'db_rows_purged': bool(movie_row or progress_row)
    }


def get_managed_media_items():
    """Retrieve media items with file sizes, stream modes, and technical specifications for management."""
    from flask import url_for
    from app.services.transcode_service import needs_transcode, get_active_transcodes, hls_cache_dir, _is_hls_truly_complete

    active_map = {t['filename']: t for t in get_active_transcodes()}
    all_movies = get_movies()
    items = []

    for m in all_movies:
        p = m['path']
        rel_fn = m['filename']
        file_exists = p.is_file() if isinstance(p, Path) else Path(p).is_file()
        st = p.stat() if file_exists else None
        size_bytes = st.st_size if st else 0
        size_str = format_bytes_display(size_bytes) if size_bytes else "—"
        suffix = Path(rel_fn).suffix.upper().lstrip('.')
        is_mkv = needs_transcode(p)

        # Transcode status
        active_t = active_map.get(rel_fn)
        hls_cached = False
        if is_mkv and file_exists:
            hls_dir = hls_cache_dir(p)
            pl = hls_dir / 'playlist.m3u8'
            hls_cached = _is_hls_truly_complete(pl, p)

        if active_t:
            stream_status = {
                'badge': 'Transcoding',
                'badge_class': 'status-transcoding',
                'percent': active_t.get('percent', 0),
                'eta': active_t.get('eta_str', ''),
                'speed': active_t.get('speed', '')
            }
        elif hls_cached:
            stream_status = {
                'badge': 'HLS Cached',
                'badge_class': 'status-cached'
            }
        elif not is_mkv:
            stream_status = {
                'badge': 'Direct Stream',
                'badge_class': 'status-direct'
            }
        else:
            stream_status = {
                'badge': 'On-Demand HLS',
                'badge_class': 'status-ondemand'
            }

        poster_url = None
        if m.get('poster'):
            try:
                poster_url = (
                    url_for('tmdb_poster', tmdb_id=m['tmdb_id'])
                    if m['poster'].startswith('tmdb:')
                    else url_for('poster', filename=m['poster'][6:])
                )
            except Exception:
                try:
                    poster_url = (
                        url_for('api.tmdb_poster', tmdb_id=m['tmdb_id'])
                        if m['poster'].startswith('tmdb:')
                        else url_for('api.poster', filename=m['poster'][6:])
                    )
                except Exception:
                    poster_url = None

        items.append({
            'filename': rel_fn,
            'title': m['title'],
            'year': m['year'],
            'tmdb_id': m.get('tmdb_id'),
            'poster_url': poster_url,
            'size_bytes': size_bytes,
            'size_str': size_str,
            'container': suffix,
            'is_mkv': is_mkv,
            'hls_cached': hls_cached,
            'stream_status': stream_status,
            'progress_percent': m.get('percent', 0),
            'mtime': st.st_mtime if st else 0
        })

    return items

