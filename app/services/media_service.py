"""Media inspection, technical specifications, and library metadata service."""
import json
import logging
import os
import subprocess
import sys
import time
from pathlib import Path
from shutil import which

logger = logging.getLogger(__name__)

from app import config
from app.db import get_db, value
from app.utils.filesystem import get_rel_path, is_video, safe_path
from app.utils.formatting import clean_title, format_bytes_display, format_db_timestamp

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
        encoding='utf-8',
        errors='replace',
        check=False,
    )
    try:
        return json.loads(result.stdout)
    except (json.JSONDecodeError, TypeError):
        return {}


def media_root_health() -> list:
    """Report configured media roots that are missing, empty, or on an unexpected volume.

    Purely diagnostic - never raises and never mutates. The deployed service ran for
    an unknown period with MEDIA_SERVER_MEDIA_ROOT pointing at an empty C:\\Flicks
    while .env and the docs said D:\\Flicks, and nothing said so: the library still
    resolved, because get_media_roots() falls back to UPLOAD_TARGET_DIR, which
    hardcodes D: when the drive exists. A misconfiguration that still appears to
    work is the dangerous kind, so it is checked for explicitly at startup.

    Returns a list of human-readable problem strings; empty means healthy.
    """
    problems = []
    try:
        roots = list(config.get_media_roots()) if hasattr(config, "get_media_roots") \
            else [config.MEDIA_ROOT]
    except Exception as exc:
        return [f"media roots unreadable: {exc}"]

    if not roots:
        return ["no media roots configured"]

    for root in roots:
        try:
            if not root.exists():
                problems.append(f"configured media root does not exist: {root}")
                continue
            if not root.is_dir():
                problems.append(f"configured media root is not a directory: {root}")
                continue
            # A root that exists but holds no media is legal (an empty library is
            # legal) but is almost always a wrong path, so say so loudly.
            try:
                entries = list(root.iterdir())
            except PermissionError as exc:
                problems.append(f"configured media root is not readable: {root} ({exc})")
                continue
            if not entries:
                problems.append(
                    f"configured media root is EMPTY: {root} - the library will resolve "
                    f"only via a fallback root, which hides this misconfiguration"
                )
        except OSError as exc:
            problems.append(f"media root {root} could not be inspected: {exc}")

    if problems:
        problems.append(
            "configured MEDIA_ROOT resolves to: "
            f"{getattr(config, 'MEDIA_ROOT', '<unset>')}"
        )
    return problems



def _walk_media(root, errors):
    """Yield every file under *root*, recording directories that cannot be read.

    pathlib's rglob() swallows PermissionError. When a root exists and is a
    directory but a subdirectory below it cannot be read, rglob returns a short
    list and raises nothing at all - which is exactly the shape that made an
    incomplete enumeration indistinguishable from a complete library, and is how
    a live cache directory came to be classified as orphaned.

    This walks with os.scandir explicitly so the failure is recorded instead of
    being lost. Symlinked directories are not followed, matching rglob.
    """
    stack = [Path(root)]
    while stack:
        current = stack.pop()
        try:
            with os.scandir(current) as entries:
                for entry in entries:
                    try:
                        is_dir = entry.is_dir(follow_symlinks=False)
                    except OSError as exc:
                        errors.append((str(current), f"{type(exc).__name__}: {exc}"))
                        continue
                    if is_dir:
                        stack.append(Path(entry.path))
                    else:
                        yield Path(entry.path)
        except OSError as exc:
            errors.append((str(current), f"{type(exc).__name__}: {exc}"))


def _discover_media(roots):
    """Walk every configured root and report what the walk actually proved.

    Returns ``(sorted_paths, status)``.

    ``status['complete']`` is True only when every configured root was walked to
    the end without an error and no distinct file was lost to basename
    deduplication. It asserts nothing about how much media exists - there is no
    coverage threshold in this function. It only says "the walk succeeded", so
    that a caller which deletes data can tell the difference between "there is
    nothing to purge" and "I could not see the library".
    """
    discovered = []
    seen = set()
    deduped = []
    skipped_uploads = 0
    root_status = []
    walk_errors = []

    for root in roots:
        errors = []
        found = 0
        try:
            missing = not root.exists() or not root.is_dir()
        except OSError as exc:
            missing = True
            errors.append((str(root), f"{type(exc).__name__}: {exc}"))

        if not missing:
            for p in _walk_media(root, errors):
                if any(part.startswith('.uploads') for part in p.parts):
                    skipped_uploads += 1
                    continue
                try:
                    if not is_video(p):
                        continue
                except OSError as exc:
                    # A file that vanished between listing and stat must not
                    # abort the walk, but it does mean the walk is not clean.
                    errors.append((str(p), f"{type(exc).__name__}: {exc}"))
                    continue
                found += 1
                rel_key = p.name.lower()
                if rel_key in seen:
                    # Two distinct files collapse to a single entry here, so the
                    # loser's cache directory would look orphaned. Fail closed.
                    deduped.append(str(p))
                    continue
                seen.add(rel_key)
                discovered.append(p)

        root_status.append({
            'path': str(root),
            'ok': not missing and not errors,
            'missing': missing,
            'errors': [f"{where}: {what}" for where, what in errors],
            'count': found,
        })
        walk_errors.extend(f"{where}: {what}" for where, what in errors)

    current = sorted(discovered, key=lambda p: str(getattr(p, 'name', p)).lower())
    status = {
        'complete': all(r['ok'] for r in root_status) and not walk_errors and not deduped,
        'roots': root_status,
        'walk_errors': walk_errors,
        'deduped': deduped,
        'skipped_uploads': skipped_uploads,
    }
    return current, status


def enumerate_media_with_status():
    """Return ``(paths, status)`` for one media enumeration.

    video_paths() delegates here, so every existing caller keeps its signature
    and the 30-second change-detection behaviour, while a caller that must not
    act on an unproven enumeration can read ``status['complete']`` for the very
    walk that produced those paths.
    """

    global _paths

    if 'app' in sys.modules and hasattr(sys.modules['app'], '_paths'):
        app_paths = sys.modules['app']._paths
        if app_paths != _paths:
            _paths = app_paths

    roots = config.get_media_roots() if hasattr(config, "get_media_roots") else [config.MEDIA_ROOT]
    current, status = _discover_media(roots)

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

    return _paths[1], status


def video_paths():
    """Discover all video files across configured MEDIA_ROOTS with a 30-second in-memory cache and immediate change detection."""
    return enumerate_media_with_status()[0]


def poster_for(path, row):
    """Find local poster image file for a given video path or row."""
    db_poster = value(row, 'poster_path')
    if db_poster and not str(db_poster).startswith('tmdb:'):
        p = Path(db_poster)
        if p.exists():
            return f"local:{get_rel_path(p)}"
        return None
    for ext in config.POSTER_EXTENSIONS:
        p = path.with_suffix(ext)
        if p.is_file():
            return f"local:{get_rel_path(p)}"
    return None


def movie(path, db, device_id=None):
    """Build movie metadata dictionary for a video path combining database and filesystem data.

    Watch progress is per device: with a `device_id`, the position comes from that
    device's own history, so two devices watching the same title never inherit each
    other's resume point. Callers outside a request (scripts, tools) still see the
    shared `progress` row.
    """
    name = get_rel_path(path)

    meta = db.execute("SELECT * FROM movies WHERE filename=?", (name,)).fetchone()
    if not meta and path.name != name:
        meta = db.execute("SELECT * FROM movies WHERE filename=?", (path.name,)).fetchone()

    progress = None
    if device_id:
        # Clients may key the history by the relative path or by the basename.
        for key in (name, path.name):
            progress = db.execute(
                "SELECT position,duration,last_watched AS updated_at "
                "FROM device_watch_history WHERE device_id=? AND filename=?",
                (device_id, key),
            ).fetchone()
            if progress:
                break
    else:
        progress = db.execute("SELECT * FROM progress WHERE filename=?", (name,)).fetchone()
        if not progress and path.name != name:
            progress = db.execute("SELECT * FROM progress WHERE filename=?", (path.name,)).fetchone()

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
        updated_at=format_db_timestamp(value(progress, 'updated_at', '')),
        backdrop_path=value(meta, 'backdrop_path', ''),
        details_json=value(meta, 'details_json', ''),
        last_metadata_refresh=value(meta, 'last_metadata_refresh')
    )


def get_movies(device_id=None):
    """Retrieve metadata dictionaries for all discovered video files in the library.

    `device_id` scopes the merged watch progress (and therefore the
    "continue watching" ordering) to a single device.
    """
    db = get_db()
    try:
        return [movie(p, db, device_id) for p in video_paths()]
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


def _is_within_media_roots(candidate):
    """True only when *candidate* resolves inside one of the configured media roots.

    Deletion paths must never rely on the caller having passed a safe name: this is the last
    line of defence before an unlink.
    """
    try:
        resolved = Path(candidate).resolve()
    except Exception:
        return False
    roots = config.get_media_roots() if hasattr(config, "get_media_roots") else [config.MEDIA_ROOT]
    for root in roots:
        try:
            root_resolved = Path(root).resolve()
        except Exception:
            continue
        if resolved == root_resolved or root_resolved in resolved.parents:
            return True
    return False


def purge_media(filename):
    """Permanently delete media file, transcode caches, subtitles, TMDb metadata, posters, and playback progress."""
    try:
        path = safe_path(filename)
    except Exception:
        # safe_path() aborts on traversal attempts and unknown names. A bare join here let
        # POST /api/media/delete delete any file the service account could write (verified on
        # this host: it removed C:\Windows\System32\drivers\etc\hosts). Accept the fallback
        # only while the joined path stays inside a configured media root.
        candidate = config.MEDIA_ROOT / filename
        if _is_within_media_roots(candidate):
            path = candidate
        else:
            logger.warning("Refusing to purge media: unsafe or unknown path %r", filename)
            return {
                'success': False,
                'error': 'Unsafe or unknown media path',
                'filename': filename,
            }

    rel_filename = get_rel_path(path)

    db = get_db()
    try:
        movie_row = db.execute("SELECT * FROM movies WHERE filename=?", (rel_filename,)).fetchone()
        progress_row = db.execute("SELECT * FROM progress WHERE filename=?", (rel_filename,)).fetchone()
    finally:
        db.close()
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
    #
    # Phase 3.8D: this deletes cache data, so it must pass the same cache-root
    # boundary as the orphan purge. It previously ran under a bare
    # `except Exception: pass`, which made a refusal indistinguishable from success.
    purged_cache_dirs = []
    refused_cache_deletes = []
    try:
        from app.services.preview_service import preview_dir
        import shutil
        p_dir = config.require_within_cache_root(
            preview_dir(path), 'purge_media(preview)')
        if p_dir.exists():
            shutil.rmtree(p_dir, ignore_errors=True)
            purged_cache_dirs.append(str(p_dir))
    except config.CacheRootUnsafe as exc:
        logger.error("REFUSING to purge preview cache for %s: %s", path, exc)
        refused_cache_deletes.append({'path': str(path), 'reason': str(exc)})
    except Exception as exc:
        logger.warning("Preview cache purge failed for %s: %s", path, exc)

    # 4. Purge TMDb posters and backdrops if not referenced by other items
    purged_posters = []
    db = get_db()
    try:
        if tmdb_id:
            other = db.execute("SELECT 1 FROM movies WHERE tmdb_id=? AND filename != ?", (tmdb_id, rel_filename)).fetchone()
            if not other:
                # Poster/backdrop caches are deletions too: validate the actual file
                # before unlinking, and surface a refusal instead of swallowing it.
                for attr, label in (('POSTER_CACHE', 'poster'), ('BACKDROP_CACHE', 'backdrop')):
                    try:
                        cached = config.require_within_cache_root(
                            getattr(config, attr) / f"{tmdb_id}.jpg",
                            f'purge_media({label})')
                        if cached.is_file():
                            cached.unlink(missing_ok=True)
                            purged_posters.append(str(cached))
                    except config.CacheRootUnsafe as exc:
                        logger.error("REFUSING to purge %s cache for %s: %s", label, rel_filename, exc)
                        refused_cache_deletes.append({'path': f'{label}:{tmdb_id}', 'reason': str(exc)})
                    except OSError as exc:
                        logger.warning("Could not purge %s cache %s: %s", label, tmdb_id, exc)

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

        # 5. Purge database records (per-device rows key on the same filename, and a
        #    client may have stored the basename rather than the relative path)
        db.execute("DELETE FROM movies WHERE filename=?", (rel_filename,))
        db.execute("DELETE FROM progress WHERE filename=?", (rel_filename,))
        db.executemany(
            "DELETE FROM device_watch_history WHERE filename=?",
            [(k,) for k in {rel_filename, path.name}],
        )
        db.commit()
    finally:
        db.close()

    # 6. Delete media file on disk and any upload part files
    file_deleted = False
    if path.is_file() and _is_within_media_roots(path):
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
        'purged_cache_dirs': purged_cache_dirs,
        'refused_cache_deletes': refused_cache_deletes,
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
        size_str = format_bytes_display(size_bytes) if size_bytes else "â€”"
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

