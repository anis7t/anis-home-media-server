"""Transcoding service for HLS segmenting, MP4 transcoding, and resume cache management."""
import glob
import hashlib
import logging
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from flask import current_app, url_for

from app import config
from app.db import get_db
from app.services.media_service import probe_media, video_paths
from app.utils.filesystem import get_rel_path, is_video, safe_path

logger = logging.getLogger(__name__)


def is_pid_alive(pid):
    """Safely check if a process is still running without sending signals."""
    if not pid or pid <= 0:
        return False
    if sys.platform == 'win32':
        import ctypes
        SYNCHRONIZE = 0x00100000
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        handle = ctypes.windll.kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, False, int(pid))
        if not handle:
            return False
        exit_code = ctypes.c_ulong()
        ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code))
        ctypes.windll.kernel32.CloseHandle(handle)
        return exit_code.value == 259  # STILL_ACTIVE = 259
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


class ProcessProxy:
    """Lightweight proxy around an active external process PID."""
    def __init__(self, pid, hls_dir=None):
        self.pid = pid
        self.hls_dir = hls_dir

    def poll(self):
        if is_pid_alive(self.pid):
            return None
        return 0

    def wait(self, timeout=None):
        deadline = time.time() + (timeout if timeout is not None else 86400)
        while time.time() < deadline:
            if self.poll() is not None:
                return 0
            time.sleep(1)
        return None


# A cache directory whose playlist/progress file was written this recently belongs to a live
# transcode: deleting it makes FFmpeg's segment renames fail and destroys work in progress.
RECENT_CACHE_GRACE_SECONDS = 600


def _looks_like_live_transcode(directory, now=None) -> bool:
    """True when *directory* holds transcode artifacts written within the grace window.

    Also matches `chunk_*.m3u8*`: during the first chunk of a fresh job the master playlist and
    hls.progress do not exist yet (the master playlist is only written once segments are on
    disk), so FFmpeg's per-chunk playlist — including its `.tmp` form — is the only evidence
    that work is in flight.
    """
    now = time.time() if now is None else now
    for pattern in ('hls.progress', 'playlist.m3u8', 'chunk_*.m3u8*'):
        for f in Path(directory).glob(pattern):
            try:
                if f.is_file() and (now - f.stat().st_mtime) < RECENT_CACHE_GRACE_SECONDS:
                    return True
            except OSError:
                continue
    return False


def get_cache_dir():
    """Retrieve CACHE_DIR, respecting test overrides in app module."""
    if 'app' in sys.modules and hasattr(sys.modules['app'], 'CACHE_DIR'):
        return sys.modules['app'].CACHE_DIR
    return config.CACHE_DIR


def transcode_cache_path(path, mode='direct'):
    """Generate deterministic cache file path for transcoded MP4."""
    path = Path(path)
    stamp = f'{path}:{path.stat().st_size}:{path.stat().st_mtime_ns}'.encode()
    key = stamp if mode == 'direct' else (mode + ':').encode() + stamp
    return get_cache_dir() / 'transcodes' / f'{hashlib.sha256(key).hexdigest()}.mp4'


def transcode_progress_path(path, mode='direct'):
    """Generate progress file path alongside transcoded MP4."""
    return transcode_cache_path(path, mode).with_suffix('.progress')


def get_hls_candidates(path):
    """Return all valid candidate HLS cache directory names for a given video path across drive roots."""
    path = Path(path)
    candidates = set()
    try:
        st = path.stat()
        candidates.add(hashlib.sha256(f'hls:{path}:{st.st_size}:{st.st_mtime_ns}'.encode()).hexdigest())
    except OSError:
        st = None

    roots = config.get_media_roots() if hasattr(config, 'get_media_roots') else [config.MEDIA_ROOT]
    sorted_roots = sorted(roots, key=lambda r: len(str(r)), reverse=True)
    rel = None
    for r in sorted_roots:
        try:
            rel = path.relative_to(r)
            break
        except ValueError:
            pass

    rel_clean = None
    if rel:
        clean_parts = [p for p in rel.parts if p != '.archive']
        if clean_parts:
            rel_clean = Path(*clean_parts)

    if st is not None:
        for root in roots:
            candidates.add(hashlib.sha256(f'hls:{root / path.name}:{st.st_size}:{st.st_mtime_ns}'.encode()).hexdigest())
            if rel:
                candidates.add(hashlib.sha256(f'hls:{root / rel}:{st.st_size}:{st.st_mtime_ns}'.encode()).hexdigest())
            if rel_clean:
                candidates.add(hashlib.sha256(f'hls:{root / rel_clean}:{st.st_size}:{st.st_mtime_ns}'.encode()).hexdigest())
                candidates.add(hashlib.sha256(f'hls:{root / ".archive" / rel_clean}:{st.st_size}:{st.st_mtime_ns}'.encode()).hexdigest())

    size = st.st_size if st else 0
    candidates.add(hashlib.sha256(f'hls:{path.name}:{size}'.encode()).hexdigest())
    return candidates


def hls_cache_dir(path):
    """Generate deterministic directory path for HLS chunks and playlist across drive roots.

    If multiple candidate directories exist, prioritizes:
    1. Fully completed playlist containing #EXT-X-ENDLIST.
    2. In-progress directory with the highest segment/chunk progress to resume.
    3. Primary directory for the direct file path.
    """
    path = Path(path)
    cache_base = get_cache_dir() / 'hls'

    try:
        st = path.stat()
        primary_key = hashlib.sha256(f'hls:{path}:{st.st_size}:{st.st_mtime_ns}'.encode()).hexdigest()
    except OSError:
        st = None
        primary_key = hashlib.sha256(f'hls:{path.name}:0'.encode()).hexdigest()
    primary_dir = cache_base / primary_key

    candidates = get_hls_candidates(path)
    existing_dirs = [cache_base / cand for cand in candidates if (cache_base / cand).is_dir()]

    if not existing_dirs:
        return primary_dir

    # 1. Prefer fully completed playlist
    for d in existing_dirs:
        pl = d / 'playlist.m3u8'
        if pl.is_file():
            try:
                txt = pl.read_text(errors='replace')
                if '#EXT-X-ENDLIST' in txt:
                    return d
            except OSError:
                pass

    # 2. Prefer directory with most progress (segments / chunks)
    best_dir = None
    max_progress = -1
    for d in existing_dirs:
        seg_count = len(list(d.glob('*.ts')))
        chunk_count = len(list(d.glob('chunk_*.m3u8')))
        prog = seg_count + (chunk_count * 15)
        if prog > max_progress:
            max_progress = prog
            best_dir = d

    if best_dir and max_progress > 0:
        return best_dir

    if primary_dir in existing_dirs:
        return primary_dir
    return existing_dirs[0]


def needs_transcode(path):
    """Determine if a file container or format requires transcoding for web playback."""
    return Path(path).suffix.lower() not in {'.mp4', '.m4v', '.webm'}


def compat_transcode_args(vaapi_available=False, amf_available=False):
    """Return FFmpeg video filter and encoder arguments for compatibility transcode."""
    preset = os.environ.get("MEDIA_SERVER_TRANSCODE_PRESET", "superfast")
    crf = os.environ.get("MEDIA_SERVER_TRANSCODE_CRF", "23")
    if amf_available:
        return ['-vf', "scale=-2:'min(1080,ih)':flags=bicubic,format=nv12", '-c:v', 'h264_amf', '-quality', 'speed', '-rc', 'cqp', '-qp_i', '22', '-qp_p', '24']
    if vaapi_available:
        return ['-vf', 'format=nv12,hwupload,scale_vaapi=w=1920:h=-2', '-c:v', 'h264_vaapi', '-qp', '24', '-pix_fmt', 'nv12']
    return ['-vf', 'scale=-2:1080,format=yuv420p', '-c:v', 'libx264', '-preset', preset, '-crf', crf, '-pix_fmt', 'yuv420p']


def hls_transcode_args(vaapi_available=False, amf_available=False):
    """Return FFmpeg video filter and encoder arguments for HLS transcoding."""
    preset = os.environ.get("MEDIA_SERVER_TRANSCODE_PRESET", "superfast")
    crf = os.environ.get("MEDIA_SERVER_TRANSCODE_CRF", "23")
    if amf_available:
        return ['-vf', "scale=-2:'min(1080,ih)':flags=bicubic,format=nv12", '-c:v', 'h264_amf', '-quality', 'speed', '-rc', 'cqp', '-qp_i', '22', '-qp_p', '24']
    if vaapi_available:
        return ['-vf', 'format=nv12,hwupload,scale_vaapi=w=1920:h=-2', '-c:v', 'h264_vaapi', '-qp', '24', '-pix_fmt', 'nv12']
    return ['-vf', 'scale=-2:1080,format=yuv420p', '-c:v', 'libx264', '-preset', preset, '-crf', crf, '-pix_fmt', 'yuv420p', '-profile:v', 'high', '-level', '4.1']


def cleanup_cache():
    """Remove orphaned .part.mp4 files and enforce size cap on transcode cache."""
    cache_dir = get_cache_dir()
    transcode_dir = cache_dir / 'transcodes'
    if not transcode_dir.is_dir():
        return
    part_files = list(transcode_dir.glob('*.part.mp4'))
    total = sum(p.stat().st_size for p in transcode_dir.iterdir() if p.is_file())
    for p in part_files:
        final = p.with_name(p.name[:-len('.part.mp4')] + '.mp4')
        age = time.time() - p.stat().st_mtime
        if age > 3600 or not final.is_file():
            p.unlink(missing_ok=True)
            continue
    for prg in transcode_dir.glob('*.progress'):
        final = prg.with_suffix('.mp4')
        part = prg.with_name(prg.stem + '.part.mp4')
        if not final.is_file() and not part.is_file():
            prg.unlink(missing_ok=True)
    mp4_files = sorted(
        [p for p in transcode_dir.glob('*.mp4') if p.is_file()],
        key=lambda p: p.stat().st_mtime
    )
    while total > config.CACHE_MAX_BYTES and mp4_files:
        oldest = mp4_files.pop(0)
        total -= oldest.stat().st_size
        oldest.unlink()


def cleanup_cache_on_startup():
    """Clean orphaned part files and enforce the cache size cap on server start.

    Deliberately does NOT purge orphaned HLS/preview directories by default: the audit is only
    as trustworthy as media enumeration, and a purge at startup can wipe every transcode on the
    host when the roots or database are not readable yet. Opt in with
    MEDIA_SERVER_PURGE_ON_STARTUP=1; the periodic maintenance worker still audits automatically.
    """
    cleanup_cache()
    if os.environ.get('MEDIA_SERVER_PURGE_ON_STARTUP', '0') == '1':
        try:
            res = purge_orphaned_caches()
            logger.info("Startup orphaned cache purge: %s", res)
        except Exception as e:
            logger.warning("Startup orphaned cache purge error: %s", e)
    else:
        logger.info("Startup orphaned cache purge skipped (set MEDIA_SERVER_PURGE_ON_STARTUP=1 to enable)")


def audit_orphaned_caches():
    """Audit HLS, preview, and transcode caches against active database/filesystem media.

    Returns a comprehensive audit report detailing:
    - orphaned_hls: list of dicts for unreferenced HLS directories
    - orphaned_previews: list of dicts for unreferenced preview directories
    - active_hls: list of dicts for active HLS directories
    - active_previews: list of dicts for active preview directories
    - total_orphaned_bytes: sum of orphaned bytes
    - total_orphaned_dirs: count of orphaned directories
    - total_active_bytes: sum of active cache bytes
    """
    from app.services.preview_service import preview_dir

    cache_dir = get_cache_dir()
    hls_base = cache_dir / 'hls'
    previews_base = cache_dir / 'previews'

    # Gather active cache directories from currently known video files.
    # Fail CLOSED: if enumeration or cache-key computation fails we must never conclude that
    # every directory on disk is orphaned. A transient DB lock or unavailable media root used
    # to empty `active_videos`, which marked the entire cache orphaned and let the automatic
    # purge delete every transcode on the host.
    degraded_reasons = []
    try:
        active_videos = video_paths()
    except Exception as exc:
        active_videos = []
        degraded_reasons.append(f"media enumeration failed: {exc}")

    active_hls_map = {}       # dir_name -> source Path
    active_preview_map = {}   # dir_name -> source Path

    for p in active_videos:
        try:
            p_obj = Path(p)
            if p_obj.is_file():
                hd = hls_cache_dir(p_obj)
                active_hls_map[hd.name] = p_obj
                pd = preview_dir(p_obj)
                active_preview_map[pd.name] = p_obj
        except Exception as exc:
            degraded_reasons.append(f"cache key failed for {p}: {exc}")
            continue

    if not active_videos and not degraded_reasons:
        # An empty library is legitimate, but an empty enumeration while cache directories are
        # populated almost always means the roots or database were unreadable at this instant.
        for base in (hls_base, previews_base):
            try:
                if base.is_dir() and next(base.iterdir(), None) is not None:
                    degraded_reasons.append(
                        f"media enumeration returned no videos while {base} still holds cache directories"
                    )
                    break
            except OSError as exc:
                degraded_reasons.append(f"cache scan failed for {base}: {exc}")

    # Check if any in-flight transcode job has an active hls_dir
    active_job_hls_names = set()
    for job in list(config.HLS_PROCESSES.values()):
        hd = getattr(job, 'hls_dir', None)
        if hd:
            active_job_hls_names.add(Path(hd).name)

    # 1. Audit HLS cache directories
    orphaned_hls = []
    active_hls = []
    if hls_base.is_dir():
        for d in hls_base.iterdir():
            if not d.is_dir():
                continue
            dir_name = d.name
            size = 0
            count = 0
            mtime = 0
            try:
                st = d.stat()
                mtime = st.st_mtime
                for f in d.iterdir():
                    if f.is_file():
                        size += f.stat().st_size
                        count += 1
            except OSError:
                pass

            is_active = (dir_name in active_hls_map) or (dir_name in active_job_hls_names)
            item = {
                'name': dir_name,
                'path': str(d),
                'size_bytes': size,
                'file_count': count,
                'mtime': mtime,
                'source_file': str(active_hls_map[dir_name].name) if dir_name in active_hls_map else None,
            }

            if is_active:
                active_hls.append(item)
            else:
                orphaned_hls.append(item)

    # 2. Audit Previews cache directories
    orphaned_previews = []
    active_previews = []
    if previews_base.is_dir():
        for d in previews_base.iterdir():
            if not d.is_dir():
                continue
            dir_name = d.name
            size = 0
            count = 0
            mtime = 0
            try:
                st = d.stat()
                mtime = st.st_mtime
                for f in d.iterdir():
                    if f.is_file():
                        size += f.stat().st_size
                        count += 1
            except OSError:
                pass

            is_active = dir_name in active_preview_map
            item = {
                'name': dir_name,
                'path': str(d),
                'size_bytes': size,
                'file_count': count,
                'mtime': mtime,
                'source_file': str(active_preview_map[dir_name].name) if dir_name in active_preview_map else None,
            }

            if is_active:
                active_previews.append(item)
            else:
                orphaned_previews.append(item)

    degraded = bool(degraded_reasons)
    if degraded:
        logger.error(
            "Cache audit DEGRADED (%s) — refusing to classify any directory as orphaned",
            "; ".join(degraded_reasons),
        )
        orphaned_hls = []
        orphaned_previews = []

    total_orphaned_bytes = sum(i['size_bytes'] for i in orphaned_hls) + sum(i['size_bytes'] for i in orphaned_previews)
    total_active_bytes = sum(i['size_bytes'] for i in active_hls) + sum(i['size_bytes'] for i in active_previews)

    return {
        'orphaned_hls': orphaned_hls,
        'orphaned_previews': orphaned_previews,
        'active_hls': active_hls,
        'active_previews': active_previews,
        'total_orphaned_bytes': total_orphaned_bytes,
        'total_orphaned_dirs': len(orphaned_hls) + len(orphaned_previews),
        'total_active_bytes': total_active_bytes,
        'total_active_dirs': len(active_hls) + len(active_previews),
        'degraded': degraded,
        'degraded_reasons': degraded_reasons,
    }


def purge_orphaned_caches(dry_run=False):
    """Purge all verified orphaned HLS and preview cache directories.

    Uses _remove_path_with_retries to ensure Windows file locks are handled safely.
    Returns dict with freed_bytes, purged_dirs, failed_dirs, dry_run.
    """
    audit = audit_orphaned_caches()
    if audit.get('degraded'):
        reason = '; '.join(audit.get('degraded_reasons') or []) or 'cache audit degraded'
        logger.error("REFUSING to purge caches: %s", reason)
        return {
            'freed_bytes': 0,
            'purged_count': 0,
            'purged_dirs': [],
            'failed_count': 0,
            'failed_dirs': [],
            'dry_run': dry_run,
            'refused': True,
            'reason': reason,
        }

    orphans = audit['orphaned_hls'] + audit['orphaned_previews']

    freed_bytes = 0
    purged_dirs = []
    failed_dirs = []
    skipped_live = []
    now = time.time()

    for item in orphans:
        target = Path(item['path'])
        if not dry_run and _looks_like_live_transcode(target, now):
            # Never delete a directory an in-flight FFmpeg is still writing into.
            skipped_live.append(item['path'])
            logger.warning("Skipping cache directory in active use: %s", target)
            continue
        if dry_run:
            purged_dirs.append(item['path'])
            freed_bytes += item['size_bytes']
            continue

        success, remaining = _remove_path_with_retries(target)
        if success:
            purged_dirs.append(item['path'])
            freed_bytes += item['size_bytes']
            logger.info("Purged orphaned cache directory: %s (%d bytes)", target, item['size_bytes'])
        else:
            failed_dirs.append({'path': item['path'], 'remaining': remaining})
            logger.warning("Failed to purge orphaned directory: %s", target)

    return {
        'freed_bytes': freed_bytes,
        'purged_count': len(purged_dirs),
        'purged_dirs': purged_dirs,
        'failed_count': len(failed_dirs),
        'failed_dirs': failed_dirs,
        'skipped_live_count': len(skipped_live),
        'skipped_live': skipped_live,
        'dry_run': dry_run,
        'refused': False,
    }


def apply_post_transcode_policy(path, policy=None):
    """Apply post-transcode retention policy to a media file whose transcode is verified 100% complete.

    Supported policies:
    - 'keep' (default): Retain original source file and HLS cache.
    - 'archive': Move original source file to ARCHIVE_DIR preserving relative subdirectories.
    - 'purge_cache': Purge HLS cache to save SSD space, keeping original source.
    """
    path = Path(path)
    if not path.is_file():
        return {'status': 'error', 'message': f'Source file {path} not found'}

    hls_dir = hls_cache_dir(path)
    pl_file = hls_dir / 'playlist.m3u8'
    if not _is_hls_truly_complete(pl_file, path):
        return {'status': 'incomplete', 'message': 'Transcode is not yet 100% complete'}

    from app.db import get_setting
    if not policy:
        policy = get_setting('retention_policy', config.DEFAULT_RETENTION_POLICY)
    policy = (policy or 'keep').lower()

    if policy == 'archive':
        archive_base = config.ARCHIVE_DIR
        archive_base.mkdir(parents=True, exist_ok=True)

        # Do not re-archive files already residing within the archive tree
        try:
            if archive_base.resolve() in path.resolve().parents or path.resolve() == archive_base.resolve():
                logger.info("File %s is already in archive directory; skipping redundant archive move", path)
                return {
                    'status': 'archived',
                    'policy': 'archive',
                    'source': str(path),
                    'archived_to': str(path),
                }
        except Exception:
            pass

        rel = Path(get_rel_path(path))
        clean_parts = [p for p in rel.parts if p != '.archive']
        rel = Path(*clean_parts) if clean_parts else Path(path.name)
        target_path = archive_base / rel
        target_path.parent.mkdir(parents=True, exist_ok=True)

        try:
            if path.resolve() != target_path.resolve():
                target_path.unlink(missing_ok=True)
                shutil.move(str(path), str(target_path))
                logger.info("Post-transcode policy 'archive': Moved %s -> %s", path, target_path)

            import app.services.media_service as media_service
            media_service._paths = (0, [])
            if 'app' in sys.modules and hasattr(sys.modules['app'], '_paths'):
                sys.modules['app']._paths = (0, [])

            return {
                'status': 'archived',
                'policy': 'archive',
                'source': str(path),
                'archived_to': str(target_path),
            }
        except Exception as e:
            logger.error("Failed to archive source %s: %s", path, e)
            return {'status': 'error', 'message': str(e)}

    elif policy in ('delete_source', 'delete_raw', 'delete_original'):
        try:
            # Move to .deleted staging area instead of truncating
            deleted_base = config.DELETED_DIR
            deleted_base.mkdir(parents=True, exist_ok=True)

            rel = Path(get_rel_path(path))
            clean_parts = [p for p in rel.parts if p != '.archive']
            rel = Path(*clean_parts) if clean_parts else Path(path.name)
            target_path = deleted_base / rel
            target_path.parent.mkdir(parents=True, exist_ok=True)

            if path.resolve() != target_path.resolve():
                target_path.unlink(missing_ok=True)
                shutil.move(str(path), str(target_path))
                logger.info("Post-transcode policy 'delete_source': Moved %s -> %s", path, target_path)

            # Invalidate paths cache so video_paths() reflects the change immediately
            import app.services.media_service as media_service
            media_service._paths = (0, [])
            if 'app' in sys.modules and hasattr(sys.modules['app'], '_paths'):
                sys.modules['app']._paths = (0, [])

            return {
                'status': 'source_deleted',
                'policy': 'delete_source',
                'source': str(path),
                'moved_to': str(target_path),
            }
        except Exception as e:
            logger.error("Failed to move source to .deleted %s: %s", path, e)
            return {'status': 'error', 'message': str(e)}

    elif policy == 'purge_cache':
        res = purge_transcode_caches_for_media(path)
        logger.info("Post-transcode policy 'purge_cache': Purged HLS cache for %s", path)
        return {
            'status': 'cache_purged',
            'policy': 'purge_cache',
            'source': str(path),
            'purged': res,
        }

    return {
        'status': 'kept',
        'policy': 'keep',
        'source': str(path),
    }


def find_ffmpeg_info_for_path(path):
    """Find any running external FFmpeg process actively converting target media path and extract PID and HLS output dir.

    Works on Windows too. The original implementation only scanned /proc, so on this host it
    returned (None, None) on every call: the duplicate-job guard in ensure_hls_transcode never
    fired, and the auto-transcoder started a second job on a cache another job was already
    rendering (two jobs writing the same segment indices). psutil is already a dependency.
    """
    target = str(path)
    target_name = Path(path).name
    try:
        import psutil
    except ImportError:
        psutil = None
    if psutil is not None:
        for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
            try:
                name = (proc.info.get('name') or '').lower()
                if 'ffmpeg' not in name:
                    continue
                content = ' '.join(proc.info.get('cmdline') or [])
                if not content:
                    continue
                if target not in content and target_name not in content:
                    continue
                hls_dir = None
                m = re.search(r'-hls_segment_filename\s+([^\s]+)[\\/]segment_%06d\.ts', content)
                if m:
                    hls_dir = Path(m.group(1))
                elif 'chunk_' in content:
                    m = re.search(r'-hls_segment_filename\s+([^\s]+)[\\/]', content)
                    if m:
                        hls_dir = Path(m.group(1))
                return proc.info['pid'], hls_dir
            except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess, OSError):
                continue
        return None, None
    for cmd_file in glob.glob('/proc/[0-9]*/cmdline'):
        try:
            with open(cmd_file, 'rb') as f:
                content = f.read().decode('utf-8', errors='ignore').replace('\x00', ' ')
                if 'ffmpeg' in content and (target in content or target_name in content):
                    pid = int(cmd_file.split('/')[2])
                    hls_dir = None
                    m = re.search(r'-hls_segment_filename\s+([^\s]+)/segment_%06d\.ts', content)
                    if m:
                        hls_dir = Path(m.group(1))
                    return pid, hls_dir
        except Exception:
            pass
    return None, None


def find_ffmpeg_for_path(path):
    """Find any running external FFmpeg process actively converting the target media path."""
    pid, _ = find_ffmpeg_info_for_path(path)
    return pid


def _hls_resume_point(directory, playlist_path, label=None, source_path=None):
    """Parse an existing HLS playlist or segment cache to find the resume point.

    Returns (resume_time_seconds, count_of_segments) or (0.0, 0) if
    no usable cache exists. Keeps existing valid .ts files intact so FFmpeg
    can continue from where it left off. *label* (the media name) is included in
    the log line: a bare cache hash cannot be traced back to a media file.
    """
    text = ""
    if playlist_path.is_file() and playlist_path.stat().st_size > 0:
        try:
            text = playlist_path.read_text(errors='replace')
        except OSError:
            text = ""

    bak_path = directory / 'playlist.m3u8.bak'
    if (not text or '#EXTINF:' not in text) and bak_path.is_file() and bak_path.stat().st_size > 0:
        try:
            text = bak_path.read_text(errors='replace')
            logger.info("HLS resume: restored playlist from backup %s", bak_path)
        except OSError:
            text = ""

    pattern = re.compile(r'#EXTINF:([\d.]+)[^\n]*\n([^\n#]+\.ts)', re.MULTILINE)
    matches = pattern.findall(text) if text else []

    valid_segments = []
    cumulative = 0.0
    for dur_str, seg_name in matches:
        seg_file = directory / seg_name.strip()
        if not seg_file.is_file() or seg_file.stat().st_size == 0:
            break
        valid_segments.append((float(dur_str), seg_name.strip()))
        cumulative += float(dur_str)

    if not valid_segments:
        # No playlist: rebuild from the segment files themselves. Glob rather than walking indices
        # densely - indices are strided per chunk, so a dense walk stops at the first inter-chunk
        # gap and would resume as if every later chunk were missing.
        disk_segs = [p for p in sorted(directory.glob('segment_*.ts')) if p.stat().st_size > 0]
        if disk_segs:
            logger.info("HLS resume: reconstructed playlist from %d segment files on disk", len(disk_segs))
            for i in range(len(disk_segs) - 1):
                valid_segments.append((4.0, disk_segs[i].name))
                cumulative += 4.0
            last_file = disk_segs[-1]
            last_dur = measure_segment_duration(last_file) or 4.0
            valid_segments.append((last_dur, last_file.name))
            cumulative += last_dur

    if not valid_segments:
        logger.info('HLS resume check: 0 valid segments found for %s (%s)',
                    directory, label or directory.name)
        return 0.0, 0

    # Resume at the content the existing segments actually hold. The labels are honest (verified
    # against frame counts), so their sum is the right position; container durations must NOT be
    # used here - they include audio pre-roll and would resume past content that is still
    # missing, which is how 279s of frames disappeared from one cache.
    resume_time = cumulative

    first_extinf = text.find('#EXTINF:') if text else -1
    header = text[:first_extinf] if first_extinf != -1 else "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-INDEPENDENT-SEGMENTS\n"
    header = header.replace('#EXT-X-ENDLIST', '')
    body = "".join(f"#EXTINF:{d:.6f},\n{name}\n" for d, name in valid_segments)
    clean_pl = header + body
    write_text_atomic(playlist_path, clean_pl)
    try:
        write_text_atomic(bak_path, clean_pl)
    except OSError:
        pass

    next_seg = len(valid_segments)
    logger.info('HLS resume: found %d valid segments, resuming from %.1fs (label sum %.1fs, segment %d)',
                len(valid_segments), resume_time, cumulative, next_seg)
    return resume_time, next_seg


def _is_hls_truly_complete(playlist_path, source_path):
    """Check if an HLS playlist is truly complete (has ENDLIST tag)."""
    playlist_path = Path(playlist_path)
    source_path = Path(source_path)
    if not playlist_path.is_file():
        return False
    try:
        text = playlist_path.read_text(errors='replace')
    except OSError:
        return False
    # ENDLIST is the authoritative marker of completion - if present, trust it
    if '#EXT-X-ENDLIST' in text:
        return True

    # For in-progress playlists (no ENDLIST) require the same validated coverage the
    # transcode pipeline itself uses before ENDLIST is written. A laxer threshold here
    # (e.g. 0.90) silently accepted abandoned partial caches as "complete": they were then
    # never resumed, could contain gaps, and the UI reported them ready at 100 %.
    extinf_re = re.compile(r'^#EXTINF:([\d.]+)', re.MULTILINE)
    cumulative = sum(float(m.group(1)) for m in extinf_re.finditer(text))
    try:
        container_duration = float(probe_media(source_path).get('format', {}).get('duration') or 0)
    except (TypeError, ValueError):
        container_duration = 0.0
    # The denominator must be the *video stream's* end, exactly like the chunk pipeline's own
    # coverage gate. A WEB-DL/WEBRip container can run minutes past the last video frame, and
    # dividing by it scored a fully rendered cache as incomplete forever (re-render loop).
    source_duration = source_video_duration(source_path, fallback=container_duration) or container_duration
    if source_duration <= 0:
        return False
    ratio = cumulative / source_duration
    if ratio >= float(getattr(config, 'MIN_COVERAGE_RATIO', 0.98)):
        return True
    logger.info('HLS completeness check: playlist has %.1fs (%.1f%%) of %.1fs source — treating as INCOMPLETE',
                cumulative, ratio * 100, source_duration)
    return False


def _ffprobe_bin():
    """Resolve the ffprobe binary path (module-level for test patching)."""
    return getattr(config, 'FFPROBE_BIN', None) or shutil.which('ffprobe')


# ---------------------------------------------------------------------------
# Segment measurement: the single source of truth for "how long is this piece
# really". #EXTINF labels written by the hardware (AMF) chunk encoders cannot
# be trusted at chunk boundaries or tails, so every playlist writer and every
# completeness decision measures instead of believing ffmpeg.
# ---------------------------------------------------------------------------

_SEGMENT_PROBE_CACHE: Dict = {}
_SEGMENT_PROBE_LOCK = threading.Lock()
_SEGMENT_PROBE_FRESH_SECONDS = 3.0
_SEGMENT_PROBE_MAX_ENTRIES = 40000

# Mirrors chunk_transcode_service.SEGMENT_TARGET_DURATION: the fallback label for a segment
# that has no #EXTINF of its own. Imported lazily there to avoid a circular import.
_DEFAULT_SEGMENT_DURATION = 4.0


def _segment_cache_key(path):
    """Cache key for a segment file, or None when it must not be measured yet."""
    try:
        st = path.stat()
    except OSError:
        return None
    if st.st_size == 0:
        return None
    if (time.time() - st.st_mtime) < _SEGMENT_PROBE_FRESH_SECONDS:
        return None  # still being written by ffmpeg: a probe would be meaningless
    return (str(path), st.st_size, st.st_mtime_ns)


def _probe_cache_get(key, kind):
    with _SEGMENT_PROBE_LOCK:
        return _SEGMENT_PROBE_CACHE.get((key, kind))


def _probe_cache_put(key, kind, value) -> None:
    with _SEGMENT_PROBE_LOCK:
        if len(_SEGMENT_PROBE_CACHE) > _SEGMENT_PROBE_MAX_ENTRIES:
            _SEGMENT_PROBE_CACHE.clear()
        _SEGMENT_PROBE_CACHE[(key, kind)] = value


def clear_segment_probe_cache() -> None:
    """Drop memoised segment measurements (tests, and after a cache is rewritten)."""
    with _SEGMENT_PROBE_LOCK:
        _SEGMENT_PROBE_CACHE.clear()


def measure_segment_duration(path) -> float:
    """Measured container duration of one HLS segment, memoised by (path, size, mtime).

    The memoisation is not an optimisation detail: the progress updater rebuilds the master
    playlist once per second, and re-probing every chunk boundary there spawned ~1 ffprobe per
    boundary per second for the whole run.
    """
    path = Path(path)
    key = _segment_cache_key(path)
    if key is None:
        return 0.0
    hit = _probe_cache_get(key, 'dur')
    if hit is not None:
        return float(hit)
    ffprobe = _ffprobe_bin()
    if not ffprobe:
        return 0.0
    try:
        out = subprocess.run(
            [ffprobe, '-v', 'error', '-show_entries', 'format=duration',
             '-of', 'default=nw=1:nk=1', str(path)],
            capture_output=True, text=True, timeout=30)
        value = 0.0
        for line in out.stdout.splitlines():
            line = line.strip()
            if line and line != 'N/A':
                try:
                    value = float(line)
                    break
                except ValueError:
                    continue
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0.0
    if value <= 0:
        return 0.0
    _probe_cache_put(key, 'dur', value)
    return value


def measure_segment_video_span(path):
    """(first_pts, last_pts) of a segment's video packets, in absolute output time.

    Durations cannot prove continuity: a segment can report 4.3s of content while starting 8s
    after the previous segment ended. Only the packets' positions reveal that hole.
    """
    path = Path(path)
    key = _segment_cache_key(path)
    if key is None:
        return None
    hit = _probe_cache_get(key, 'span')
    if hit is not None:
        return hit if hit != 'EMPTY' else None
    ffprobe = _ffprobe_bin()
    if not ffprobe:
        return None
    pts = []
    try:
        out = subprocess.run(
            [ffprobe, '-v', 'error', '-select_streams', 'v:0',
             '-show_entries', 'packet=pts_time', '-of', 'csv=p=0', str(path)],
            capture_output=True, text=True, timeout=60)
        for line in out.stdout.splitlines():
            line = line.strip().rstrip(',')
            if line and line != 'N/A':
                try:
                    pts.append(float(line))
                except ValueError:
                    pass
    except (OSError, subprocess.SubprocessError):
        return None
    span = (min(pts), max(pts)) if pts else None
    _probe_cache_put(key, 'span', span if span else 'EMPTY')
    return span


def write_text_atomic(path, text: str) -> bool:
    """Write a playlist through a temp file + os.replace so readers never see a torn file."""
    path = Path(path)
    tmp = path.with_name(path.name + '.tmp')
    try:
        tmp.write_text(text, encoding='utf-8')
        os.replace(tmp, path)
        return True
    except OSError:
        try:
            if tmp.exists():
                tmp.unlink()
        except OSError:
            pass
        try:
            path.write_text(text, encoding='utf-8')  # reader may hold the target open
            return True
        except OSError:
            return False


def parse_playlist_labels(text: str) -> Dict[str, float]:
    """Map segment name -> #EXTINF label for a playlist's text."""
    labels: Dict[str, float] = {}
    pending = None
    for line in (text or '').splitlines():
        if line.startswith('#EXTINF:'):
            try:
                pending = float(line.split(':', 1)[1].rstrip(',').split(',')[0])
            except (ValueError, IndexError):
                pending = None
        elif line.endswith('.ts') and not line.startswith('#'):
            if pending is not None:
                labels[line.strip()] = pending
            pending = None
    return labels


def measure_segment_frame_count(path) -> int:
    """Video frame count of one HLS segment, memoised by (path, size, mtime).

    Frame accounting is the only measure of missing content that is independent of both the
    #EXTINF labels (which the hardware encoders mislabel) and the packet positions (which jump
    at every chunk boundary by design, because the playlist declares #EXT-X-DISCONTINUITY).

    Returns -1 for "unknown" (unreadable file, no ffprobe, segment still being written) and 0
    only for a file that was successfully read and genuinely holds no video packets: treating an
    unreadable file as empty would mark every chunk deficient and re-encode the cache forever.
    """
    path = Path(path)
    key = _segment_cache_key(path)
    if key is None:
        return 0
    hit = _probe_cache_get(key, 'frames')
    if hit is not None:
        return int(hit)
    ffprobe = _ffprobe_bin()
    if not ffprobe:
        return 0
    try:
        out = subprocess.run(
            [ffprobe, '-v', 'error', '-select_streams', 'v:0', '-count_packets',
             '-show_entries', 'stream=nb_read_packets', '-of', 'default=nw=1:nk=1', str(path)],
            capture_output=True, text=True, timeout=120)
        if out.returncode != 0:
            return -1                      # unreadable file: unknown, not "empty"
        frames = -1
        for line in out.stdout.splitlines():
            line = line.strip()
            if line and line != 'N/A':
                try:
                    frames = int(float(line))
                except ValueError:
                    continue
                break                      # one video stream, printed once per TS program
        if frames < 0:
            return -1                      # nothing parseable: unknown, not "empty"
    except (OSError, ValueError, subprocess.SubprocessError):
        return -1
    if frames < 0:
        return -1
    _probe_cache_put(key, 'frames', frames)
    return frames


def source_frame_rate(source_path) -> float:
    """Frame rate of the source's video stream (falls back to 24 fps)."""
    try:
        info = probe_media(source_path)
        streams = info.get('streams') or []
        video = next((s for s in streams if s.get('codec_type') == 'video'), {})
        for key in ('avg_frame_rate', 'r_frame_rate'):
            value = str(video.get(key) or '')
            if '/' in value:
                num, den = value.split('/')
                if float(den) > 0:
                    return float(num) / float(den)
            elif value:
                return float(value)
    except Exception:
        pass
    return 24.0


def _dense_cache_content_deficits(hls_dir, total_duration: float, fps: float):
    """Whole-cache frame accounting for a cache still on the legacy dense segment grid.

    Returns a single aggregate entry (chunk_id -1) when the cache holds materially fewer frames
    than the source's video track, and [] when it is complete or cannot be measured. A
    non-strided cache cannot be measured per chunk, but the total is exactly what decides whether
    ENDLIST may stand: a dense cache that lost content at chunk boundaries (Spider-Man: 85
    overflowing chunks, 6900 frames gone) is short here, while a dense cache whose chunks emitted
    the planned 15 segments is complete and must be left alone.
    """
    try:
        counts = [measure_segment_frame_count(seg) for seg in sorted(Path(hls_dir).glob('segment_*.ts'))]
    except OSError:
        return []
    if not counts or any(c < 0 for c in counts):
        return []            # unknown: never strip ENDLIST or re-render on a guess
    frames = sum(counts)
    expected = total_duration * fps
    missing = (expected - frames) / fps
    # The whole-cache total is exact (a verified re-render matched the source frame for frame),
    # so this can be far tighter than the per-chunk rule: 1.5% of a 2h movie is two minutes and
    # would let a real 60s hole pass. 0.5% (41s on a 2h movie) still ignores encoder rounding.
    if missing > max(2.0, 0.005 * total_duration):
        return [{'chunk_id': -1, 'start': 0.0, 'expected_frames': int(expected),
                 'frames': int(frames), 'missing_s': round(missing, 2), 'legacy_layout': True}]
    return []


def chunk_content_deficits(hls_dir, total_duration: float, source_path=None, chunk_ids=None):
    """Chunks holding materially fewer video frames than their window requires.

    Returns [{chunk_id, start, expected_frames, frames, missing_s}] for chunks missing more than
    max(0.6s, 1.5% of the chunk). This is what catches content a resume skipped: every segment
    can exist, measure a sane duration and still be missing seconds of frames.

    Per-chunk windows are only meaningful on the strided grid (see chunk_transcode_service's
    layout marker). A cache still on the legacy dense grid is judged as a whole instead, and
    attributed to a single aggregate entry with chunk_id -1.
    """
    deficits = []
    if total_duration <= 0:
        return deficits
    try:
        from app.services.chunk_transcode_service import (
            SEGMENTS_PER_CHUNK_STRIDE, cache_uses_strided_layout, plan_chunks)
        plan = plan_chunks(total_duration)
    except Exception:
        return deficits
    fps = source_frame_rate(source_path) if source_path else 24.0
    if fps <= 0:
        fps = 24.0
    hls_dir = Path(hls_dir)
    if not cache_uses_strided_layout(hls_dir):
        # Legacy dense cache: per-chunk windows are NOT recoverable from indices here. Chunk N's
        # overflow segment (a chunk emits 15, 16 or 17, not the planned 15) sits on chunk N+1's
        # first index, so a strided window would read 32 segments of a neighbour's content for
        # most chunks and a near-empty tail for the last ones - which is how a complete cache got
        # reported as missing 38s of video. Judge the whole cache instead.
        return _dense_cache_content_deficits(hls_dir, total_duration, fps)
    wanted = set(chunk_ids) if chunk_ids is not None else None
    unknown = 0
    for c in plan:
        try:
            cid = int(c['chunk_id'])
            start = int(c['start_seg'])
            count = int(c['expected_segs'])
            duration = float(c['duration'])
        except (KeyError, TypeError, ValueError):
            continue
        if wanted is not None and cid not in wanted:
            continue
        # Measure the chunk's own run of segments, not a fixed count: a 60s chunk legitimately
        # emits 15, 16 or 17 segments (the muxer splits on the encoder's keyframes), and all of
        # them belong to this chunk. The strided layout bounds the run, so it can never bleed into
        # the next chunk. Measuring only `count` segments made a complete chunk look 1.25s short.
        stride_limit = start + SEGMENTS_PER_CHUNK_STRIDE
        segments = []
        for i in range(start, stride_limit):
            seg = hls_dir / f"segment_{i:06d}.ts"
            if not seg.is_file() or seg.stat().st_size == 0:
                if segments:
                    break                      # end of this chunk's run
                continue                       # chunk not started yet
            segments.append(seg)
        if not segments:
            continue
        counts = [measure_segment_frame_count(seg) for seg in segments]
        if any(c < 0 for c in counts):
            unknown += 1                   # cannot judge this chunk: never re-render on a guess
            continue
        frames = sum(counts)
        expected = duration * fps
        missing = (expected - frames) / fps
        if missing > max(0.6, 0.01 * duration):
            deficits.append({'chunk_id': cid, 'start': round(float(c['start_time']), 1),
                             'expected_frames': int(expected), 'frames': int(frames),
                             'missing_s': round(missing, 2)})
    if unknown:
        logger.warning('Frame accounting: %d of %d chunk(s) could not be measured (no ffprobe or '
                       'unreadable segments); they are reported as neither complete nor deficient',
                       unknown, len(plan))
    return deficits


def chunk_content_holes(hls_dir, total_duration: float, chunk_ids=None, tolerance: float = 1.0):
    """DIAGNOSTIC ONLY - never gate on this. Packet positions jump at every chunk boundary by
    design (#EXT-X-DISCONTINUITY), so a "hole" here is usually the declared discontinuity, not
    missing content. Use chunk_content_deficits() for content loss."""
    """Chunk boundaries where video content is genuinely missing.

    A resume that trusted #EXTINF labels re-rendered from a time the labels understated, so the
    boundary content was skipped: every segment still exists and measures a sane duration, but
    the packets' positions jump. Returns [{chunk_id, seg, at, hole}] for holes > *tolerance*.
    """
    holes = []
    if total_duration <= 0:
        return holes
    try:
        from app.services.chunk_transcode_service import plan_chunks
        plan = plan_chunks(total_duration)
    except Exception:
        return holes
    wanted = set(chunk_ids) if chunk_ids is not None else None
    hls_dir = Path(hls_dir)
    # Segment indices are strided (chunk_id * 32), so the segment immediately before a boundary is
    # the highest existing index below it, not idx - 1.
    on_disk = sorted(int(m.group(1)) for p in hls_dir.glob("segment_*.ts")
                     if (m := re.search(r"segment_(\d+)\.ts$", p.name)))
    for c in plan:
        try:
            cid = int(c['chunk_id'])
            idx = int(c['start_seg'])
        except (KeyError, TypeError, ValueError):
            continue
        if idx <= 0 or (wanted is not None and cid not in wanted):
            continue
        before = [i for i in on_disk if i < idx]
        if not before:
            continue
        prev_seg = hls_dir / f"segment_{before[-1]:06d}.ts"
        this_seg = hls_dir / f"segment_{idx:06d}.ts"
        if not prev_seg.is_file() or not this_seg.is_file():
            continue
        prev_span = measure_segment_video_span(prev_seg)
        this_span = measure_segment_video_span(this_seg)
        if not prev_span or not this_span:
            continue
        hole = this_span[0] - prev_span[1]
        if hole > tolerance:
            holes.append({'chunk_id': cid, 'seg': idx,
                          'at': round(prev_span[1], 3), 'hole': round(hole, 3)})
    return holes


def repair_understated_caches(max_caches: int = 50) -> Dict:
    """Strip ENDLIST from caches that claim completion but are missing video frames.

    The only trustworthy measure of content is the frame count: labels are honest but a cache
    can still be missing seconds of video, and ENDLIST is authoritative for every other check
    in the app. Nothing here rewrites labels - a genuinely short cache must be re-rendered, not
    relabelled.
    """
    result = {'inspected': 0, 'repaired': [], 'stripped': [], 'holes_found': [], 'queued': []}
    try:
        from app.services.media_service import video_paths
        medias = list(video_paths())
    except Exception as exc:
        logger.warning('Cache label audit skipped: %s', exc)
        return result
    for media in medias:
        if result['inspected'] >= max_caches:
            break
        try:
            cache = hls_cache_dir(media)
        except Exception:
            continue
        playlist = cache / 'playlist.m3u8'
        if not playlist.is_file():
            continue
        total = source_video_duration(media, fallback=0.0)
        if total <= 0:
            continue
        try:
            text = playlist.read_text(errors='replace')
        except OSError:
            continue
        labels = parse_playlist_labels(text)
        if not labels:
            continue
        threshold = float(getattr(config, 'MIN_COVERAGE_RATIO', 0.98))
        # Count frames FIRST, even when the labels look healthy: a cache can claim 99.9% and
        # still be missing minutes of content (a resume that trusted the mislabelled boundaries
        # skipped it), and no duration-based check can see that.
        deficits = chunk_content_deficits(cache, total, source_path=media)
        if not deficits and sum(labels.values()) / total >= threshold:
            continue
        result['inspected'] += 1
        if deficits:
            missing = round(sum(d['missing_s'] for d in deficits), 1)
            result['holes_found'].append({'media': media.name, 'chunks': len(deficits), 'missing': missing})
            if '#EXT-X-ENDLIST' in text:
                write_text_atomic(playlist, text.replace('#EXT-X-ENDLIST', '').rstrip() + '\n')
                result['stripped'].append({'media': media.name, 'chunks': len(deficits), 'missing': missing})
                logger.error(
                    'Cache for %s claims completion but %d chunk(s) are missing %.1fs of video frames; '
                    'ENDLIST removed so it is re-rendered', media.name, len(deficits), missing)
            else:
                logger.warning('Cache for %s is missing %.1fs of video frames across %d chunk(s); '
                               'leaving it for re-render', media.name, missing, len(deficits))
            # Queue the re-render from here. The auto-transcoder's own gate is label-based
            # (_is_hls_truly_complete), and a frame-deficient cache's labels can still sum to
            # 100% of the source - so stripping ENDLIST on its own stranded the cache: incomplete
            # by frames, "complete" by labels, and therefore never re-rendered by anything.
            try:
                from app.utils.filesystem import get_rel_path
                if ensure_hls_transcode(get_rel_path(media), force=True) is not None:
                    result['queued'].append(media.name)
            except Exception as exc:
                logger.warning('Could not queue a re-render for %s: %s', media.name, exc)
            continue
        logger.warning('Cache for %s scores %.1f%% by label but has no frame deficit: leaving the '
                       'playlist untouched (the labels are ffmpeg\'s and were verified honest)',
                       media.name, sum(labels.values()) / total * 100)
    return result


# Measured video-stream end times, keyed by (path, size, mtime_ns). The measurement costs a
# ~0.3s ffprobe seek, and playback status polls this path once per second per active stream.
_VIDEO_DURATION_CACHE: Dict = {}
_VIDEO_DURATION_LOCK = threading.Lock()


def clear_video_duration_cache() -> None:
    """Drop cached video-duration measurements (used by tests and after source replacement)."""
    with _VIDEO_DURATION_LOCK:
        _VIDEO_DURATION_CACHE.clear()


def source_video_duration(path, fallback=None):
    """Return the true end time of the *video* stream, in seconds.

    Container duration is not a safe denominator for HLS completeness: WEB-DL/WEBRip
    muxes routinely carry audio and subtitle packets minutes past the last video frame
    (e.g. a 9839s container whose picture ends at 8254.6s). Chunk planning and coverage
    validation must use the video end, otherwise a fully rendered movie is scored as
    incomplete and re-encoded forever.

    Falls back to the container/format duration when the video end cannot be measured,
    so callers degrade to the previous behaviour rather than to a hard failure.
    """
    path = Path(path)
    if fallback is None:
        try:
            fallback = float(probe_media(path).get('format', {}).get('duration') or 0) or None
        except (TypeError, ValueError, OSError):
            fallback = None

    probe = _ffprobe_bin()
    if not probe:
        return fallback

    try:
        st = path.stat()
        cache_key = (str(path), st.st_size, st.st_mtime_ns)
        with _VIDEO_DURATION_LOCK:
            cached = _VIDEO_DURATION_CACHE.get(cache_key)
        if cached is not None:
            return cached
    except OSError:
        cache_key = None

    def _scan(read_intervals=None):
        cmd = [probe, '-v', 'error', '-select_streams', 'v:0']
        if read_intervals:
            cmd += ['-read_intervals', read_intervals]
        cmd += ['-show_entries', 'packet=pts_time,duration_time', '-of', 'csv=p=0', str(path)]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=120, check=False)
        except (OSError, subprocess.SubprocessError):
            return None
        last_end = None
        for line in (res.stdout or '').splitlines():
            parts = line.strip().split(',')
            if not parts or not parts[0]:
                continue
            try:
                pts = float(parts[0])
                dur = float(parts[1]) if len(parts) > 1 and parts[1] not in ('', 'N/A') else 0.0
            except (TypeError, ValueError):
                continue
            last_end = pts + dur
        return last_end

    # Fast path: jump to the midpoint via the container index and read to EOF
    # (~0.3s on a 5 GB MKV) instead of scanning every video packet (~9s).
    if fallback and fallback > 0:
        end = _scan(f'{fallback * 0.5:.3f}%+99999')
        if end and end > 0:
            return _remember_video_duration(cache_key, end)

    # Video ended before the midpoint (audio outlasts video by more than half), or the
    # fallback duration is unknown: fall back to a full video packet scan.
    end = _scan()
    if end and end > 0:
        return _remember_video_duration(cache_key, end)
    return fallback


def _remember_video_duration(cache_key, value: float) -> float:
    if cache_key is not None:
        with _VIDEO_DURATION_LOCK:
            _VIDEO_DURATION_CACHE[cache_key] = value
    return value


def ensure_hls_transcode(filename, force: bool = False):
    """Ensure HLS transcode is running for *filename*, returning the process or None.

    `force` skips the completeness gate. It exists for the caches whose frames are short while
    their labels still sum to 100% - `_is_hls_truly_complete()` cannot see those (it is
    label-based), so the maintenance audit, which has measured the frames, must be able to start
    the re-render the ENDLIST strip was meant to trigger. Only pass it for a measured deficit.
    """
    path = safe_path(filename)
    if not is_video(path) or config.SHUTDOWN_EVENT.is_set():
        return None
    if not path.is_file():
        # A deleted/stale media name must never spin the resume-check loop: without this
        # guard every repeated request for a vanished file re-entered the transcode path
        # against a cache directory that can never exist, once per request, forever.
        logger.warning('HLS transcode skipped: media file no longer exists: %s', filename)
        return None
    directory = hls_cache_dir(path)
    playlist = directory / 'playlist.m3u8'
    lock = config.TRANSCODE_LOCKS.setdefault('hls:' + filename, threading.Lock())
    with lock:
        if config.SHUTDOWN_EVENT.is_set():
            return None
        is_complete = False if force else _is_hls_truly_complete(playlist, path)
        proc = config.HLS_PROCESSES.get(filename)
        is_running = proc is not None and proc.poll() is None
        if not is_running and not is_complete:
            existing_pid, existing_hls_dir = find_ffmpeg_info_for_path(path)
            if existing_pid:
                proc = ProcessProxy(existing_pid, hls_dir=existing_hls_dir)
                config.HLS_PROCESSES[filename] = proc
                is_running = True
        if not is_complete and not is_running:
            directory.mkdir(parents=True, exist_ok=True)
            resume_time, start_seg = _hls_resume_point(directory, playlist, label=filename, source_path=path)
            resuming = resume_time > 0.0 and start_seg > 0
            if resuming and playlist.is_file():
                pl_text = playlist.read_text(errors='replace')
                pl_text = pl_text.replace('#EXT-X-ENDLIST', '').rstrip() + '\n'
                write_text_atomic(playlist, pl_text)
                try:
                    write_text_atomic(directory / 'playlist.m3u8.bak', pl_text)
                except OSError:
                    pass
            streams = probe_media(path).get('streams', [])
            video = next((s for s in streams if s.get('codec_type') == 'video'), {})
            amf = config.is_amf_enabled()
            vaapi = config.is_vaapi_enabled()

            # Dynamic Multi-GPU chunked transcoding path
            try:
                from app.services.gpu_service import is_dual_gpu_enabled
                from app.services.chunk_transcode_service import start_dual_gpu_transcode
                if (
                    amf
                    and is_dual_gpu_enabled()
                    and 'pytest' not in sys.modules
                ):
                    job = start_dual_gpu_transcode(filename, path, directory, playlist)
                    config.HLS_PROCESSES[filename] = job
                    return job
            except Exception as e:
                logger.warning(f"Failed to initiate dual-GPU transcode for {filename}: {e}; falling back to single GPU.")

            if amf:
                adapter = os.environ.get("MEDIA_SERVER_AMF_ADAPTER", "1")
                input_args = [
                    '-init_hw_device', f'd3d11va=dx11:{adapter}',
                    '-init_hw_device', 'amf=amf@dx11',
                    '-filter_hw_device', 'amf',
                    '-hwaccel', 'd3d11va',
                    '-hwaccel_device', str(adapter)
                ]
                video_args = hls_transcode_args(amf_available=True)
            elif vaapi:
                dev = os.environ.get("MEDIA_SERVER_VAAPI_DEVICE", "/dev/dri/renderD128")
                input_args = ['-vaapi_device', dev, '-hwaccel', 'vaapi', '-hwaccel_device', dev]
                video_args = hls_transcode_args(vaapi_available=True)
            elif (
                video.get('codec_name') == 'h264'
                and (video.get('height') or 0) <= 1088
                and (video.get('width') or 0) <= 1920
                and video.get('pix_fmt', 'yuv420p') in {'yuv420p', 'yuvj420p'}
            ):
                input_args = []
                video_args = ['-c:v', 'copy']
            else:
                input_args = []
                video_args = hls_transcode_args(False)
            audio = next((s for s in streams if s.get('codec_type') == 'audio'), {})
            audio_args = (
                ['-c:a', 'copy']
                if (audio.get('codec_name') == 'aac' and audio.get('channels', 2) <= 2)
                else ['-c:a', 'aac', '-ac', '2', '-b:a', '192k', '-af', 'aresample=async=1:first_pts=0']
            )
            seek_args = ['-ss', str(resume_time)] if resuming else []
            hls_flags = 'independent_segments+append_list' if resuming else 'independent_segments'
            cmd = (
                ['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error']
                + input_args
                + seek_args
                + ['-i', str(path), '-map', '0:v:0', '-map', '0:a:0?']
                + video_args
                + audio_args
                + [
                    '-avoid_negative_ts', 'make_zero',
                    '-muxdelay', '0',
                    '-force_key_frames', 'expr:gte(t,n_forced*4)',
                    '-f', 'hls',
                    '-hls_time', '4',
                    '-hls_list_size', '0',
                    '-hls_flags', hls_flags,
                    '-start_number', str(start_seg) if resuming else '0',
                    '-hls_segment_filename', str(directory / 'segment_%06d.ts'),
                    '-progress', str(directory / 'hls.progress'),
                    '-nostats', str(playlist)
                ]
            )

            # Test patch dynamic delegation for subprocess.Popen
            popen_func = subprocess.Popen
            if 'app' in sys.modules and hasattr(sys.modules['app'], 'subprocess'):
                app_sub = sys.modules['app'].subprocess
                if hasattr(app_sub, 'Popen'):
                    popen_func = app_sub.Popen

            proc = popen_func(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                proc.hls_dir = directory
            except Exception:
                pass
            config.HLS_PROCESSES[filename] = proc
            # This path hands the master playlist to ffmpeg's own HLS muxer, which writes raw
            # #EXTINF labels and appends #EXT-X-ENDLIST at normal EOF. Verify the labels with
            # measurements once it finishes, otherwise a short boundary segment silently becomes
            # a "complete, ready" cache and can trigger source archive/delete.
            def _verify_labels_when_done(_proc=proc, _directory=directory, _path=path, _filename=filename):
                try:
                    _proc.wait()
                    _total = source_video_duration(_path, fallback=0.0)
                    if _total > 0:
                        _deficits = chunk_content_deficits(_directory, _total, source_path=_path)
                        if _deficits:
                            _pl = _directory / 'playlist.m3u8'
                            if _pl.is_file():
                                _txt = _pl.read_text(errors='replace')
                                if '#EXT-X-ENDLIST' in _txt:
                                    write_text_atomic(_pl, _txt.replace('#EXT-X-ENDLIST', '').rstrip() + '\n')
                                    logger.error(
                                        'Single-GPU HLS for %s is missing %.1fs of video frames across %d '
                                        'chunk(s); ENDLIST removed so it is re-rendered',
                                        _filename, sum(d['missing_s'] for d in _deficits), len(_deficits))
                        else:
                            logger.debug('Single-GPU HLS for %s passed frame accounting', _filename)
                except Exception as _exc:  # never let bookkeeping break a running stream
                    logger.debug('Post-transcode label verification skipped for %s: %s', _filename, _exc)

            threading.Thread(target=_verify_labels_when_done,
                             name=f'hls-label-verify-{filename}', daemon=True).start()
            logger.info(
                'HLS transcode %s: %s from %.1fs (segment %d)',
                'resumed' if resuming else 'started',
                filename,
                resume_time,
                start_seg
            )
    return proc


_active_resolving = set()


def _trigger_active_resolution(path):
    """Asynchronously resolve unidentified or numeric media currently transcoding."""
    path_str = str(path)
    if path_str in _active_resolving:
        return
    _active_resolving.add(path_str)

    def _worker():
        try:
            import scanner
            scanner.scan_single_file(path)
        except Exception as e:
            logger.warning(f"Active resolution error for {path}: {e}")
        finally:
            _active_resolving.discard(path_str)

    threading.Thread(target=_worker, name=f"resolve-{Path(path).name}", daemon=True).start()


def get_active_transcodes():
    """Return status dictionaries for all active and in-progress media transcodes."""
    results = []
    seen = set()
    db = get_db()
    try:
        movie_rows = {
            r['filename']: dict(r)
            for r in db.execute('SELECT filename, title, year, poster_path, tmdb_id, runtime FROM movies')
        }
    except Exception:
        movie_rows = {}
    finally:
        db.close()

    def parse_prog(prog_file, path, playlist_file=None):
        values = {}
        if prog_file and prog_file.is_file():
            try:
                for line in prog_file.read_text(errors='replace').splitlines():
                    if '=' in line:
                        k, v = line.split('=', 1)
                        values[k] = v.strip()
            except Exception:
                pass
        try:
            duration = float(probe_media(path).get('format', {}).get('duration') or 0)
        except (TypeError, ValueError):
            duration = 0
        try:
            encoded = float(values.get('out_time_ms', 0)) / 1_000_000
        except (TypeError, ValueError):
            encoded = 0

        if playlist_file and playlist_file.is_file():
            try:
                pl_text = playlist_file.read_text(errors='replace')
                pl_dur = sum(float(m.group(1)) for m in re.finditer(r'^#EXTINF:([\d.]+)', pl_text, re.MULTILINE))
                if pl_dur > encoded:
                    encoded = pl_dur
            except Exception:
                pass

        try:
            speed = float(values.get('speed', '0x').rstrip('x'))
        except (TypeError, ValueError):
            speed = 0

        if speed <= 0 and encoded > 0 and playlist_file and playlist_file.is_file():
            try:
                first_seg = playlist_file.parent / "segment_000000.ts"
                ref_time = first_seg.stat().st_mtime if first_seg.is_file() else playlist_file.parent.stat().st_ctime
                elapsed = max(1.0, time.time() - ref_time)
                speed = round(encoded / elapsed, 2)
            except Exception:
                pass

        percent = min(99.9, round(encoded / duration * 100, 1)) if duration > 0 else 0
        remaining = max(0, (duration - encoded) / speed) if speed > 0 else None

        encoded_str = f"{int(encoded // 60)}:{int(encoded % 60):02d}"
        duration_str = f"{int(duration // 60)}:{int(duration % 60):02d}" if duration else "--:--"
        speed_str = f"{speed:.1f}x" if speed > 0 else ""
        if remaining is not None:
            rem_m, rem_s = int(remaining // 60), int(remaining % 60)
            eta_str = f"{rem_m}m {rem_s}s" if rem_m > 0 else f"{rem_s}s"
        else:
            eta_str = "Calculating..."

        return {
            'percent': percent,
            'speed_str': speed_str,
            'encoded_str': encoded_str,
            'duration_str': duration_str,
            'eta_str': eta_str
        }

    for p in video_paths():
        if not is_video(p) or not needs_transcode(p):
            continue
        rel = get_rel_path(p)
        if rel not in config.HLS_PROCESSES or config.HLS_PROCESSES[rel].poll() is not None:
            pid, hls_dir = find_ffmpeg_info_for_path(p)
            if pid:
                config.HLS_PROCESSES[rel] = ProcessProxy(pid, hls_dir=hls_dir)

    for fn, proc in list(config.HLS_PROCESSES.items()):
        if proc is not None and proc.poll() is None:
            try:
                path = safe_path(fn)
                hls_dir = getattr(proc, 'hls_dir', None) or hls_cache_dir(path)
                playlist_file = hls_dir / 'playlist.m3u8'
                is_complete = _is_hls_truly_complete(playlist_file, path)
                if not is_complete:
                    seen.add(fn)
                    info = parse_prog(hls_dir / 'hls.progress', path, playlist_file)
                    m = movie_rows.get(fn, {})
                    title = m.get('title') or Path(fn).stem
                    from app.services.media_resolver import is_anonymous_name
                    if (is_anonymous_name(title) or not m.get('tmdb_id')) and path.is_file():
                        _trigger_active_resolution(path)
                    poster = m.get('poster_path')
                    try:
                        poster_url = (
                            url_for('api.tmdb_poster', tmdb_id=m['tmdb_id'])
                            if m.get('tmdb_id')
                            else (url_for('api.poster', filename=poster) if poster else None)
                        )
                    except Exception:
                        try:
                            poster_url = (
                                url_for('tmdb_poster', tmdb_id=m['tmdb_id'])
                                if m.get('tmdb_id')
                                else (url_for('poster', filename=poster) if poster else None)
                            )
                        except Exception:
                            poster_url = None
                    results.append({
                        'filename': fn,
                        'title': title,
                        'year': m.get('year'),
                        'poster_url': poster_url,
                        'mode': 'HLS Transcode',
                        'status': 'building',
                        'percent': info['percent'],
                        'speed': info['speed_str'],
                        'encoded_str': info['encoded_str'],
                        'duration_str': info['duration_str'],
                        'eta_str': info['eta_str'],
                    })
            except Exception:
                pass

    for lock_key, item in list(config.ACTIVE_DIRECT_TRANSCODES.items()):
        fn = item.get('filename')
        if fn and fn not in seen:
            seen.add(fn)
            try:
                path = item['path']
                info = parse_prog(item.get('progress_path'), path)
                m = movie_rows.get(fn, {})
                title = m.get('title') or Path(fn).stem
                poster = m.get('poster_path')
                try:
                    poster_url = (
                        url_for('api.tmdb_poster', tmdb_id=m['tmdb_id'])
                        if m.get('tmdb_id')
                        else (url_for('api.poster', filename=poster) if poster else None)
                    )
                except Exception:
                    try:
                        poster_url = (
                            url_for('tmdb_poster', tmdb_id=m['tmdb_id'])
                            if m.get('tmdb_id')
                            else (url_for('poster', filename=poster) if poster else None)
                        )
                    except Exception:
                        poster_url = None
                results.append({
                    'filename': fn,
                    'title': title,
                    'year': m.get('year'),
                    'poster_url': poster_url,
                    'mode': 'MP4 Transcode' if item.get('mode') != 'compat' else 'Compat MP4',
                    'status': 'building',
                    'percent': info['percent'],
                    'speed': info['speed_str'],
                    'encoded_str': info['encoded_str'],
                    'duration_str': info['duration_str'],
                    'eta_str': info['eta_str'],
                })
            except Exception:
                pass

    return results


def _pid_is_running(pid):
    return is_pid_alive(pid)


def _wait_for_pid_exit(pid, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not _pid_is_running(pid):
            return True
        time.sleep(0.1)
    return not _pid_is_running(pid)


def _terminate_pid(pid):
    if not pid or pid == os.getpid() or not _pid_is_running(pid):
        return True
    try:
        if os.name == 'nt':
            subprocess.run(
                ['taskkill', '/PID', str(pid), '/T', '/F'],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        else:
            os.kill(pid, signal.SIGTERM)
    except (OSError, subprocess.SubprocessError):
        pass
    return _wait_for_pid_exit(pid, timeout=5.0)


def stop_transcodes_for_media(filename, path=None):
    """Terminate active FFmpeg transcodes associated with this media and verify exit."""
    stopped_pids = []
    rel_name = str(filename)
    if path is None:
        try:
            path = safe_path(rel_name)
        except Exception:
            path = None

    proc = config.HLS_PROCESSES.pop(rel_name, None)
    if proc is not None:
        if hasattr(proc, 'get_active_pids'):
            for p_id in proc.get_active_pids():
                if p_id and p_id not in stopped_pids:
                    stopped_pids.append(p_id)
        else:
            pid = getattr(proc, 'pid', None)
            if pid and pid not in stopped_pids:
                stopped_pids.append(pid)
        try:
            if hasattr(proc, 'terminate'):
                proc.terminate()
            elif hasattr(proc, 'kill'):
                proc.kill()
            elif pid:
                _terminate_pid(pid)
        except Exception as e:
            logger.warning("Error terminating HLS process for %s: %s", rel_name, e)

    if path is not None:
        pid, _ = find_ffmpeg_info_for_path(path)
        if pid and pid not in stopped_pids:
            stopped_pids.append(pid)
            _terminate_pid(pid)

    for lock_key, item in list(config.ACTIVE_DIRECT_TRANSCODES.items()):
        if item.get('filename') == rel_name or (path is not None and str(item.get('path')) == str(path)):
            p = item.get('process')
            if p:
                pid = getattr(p, 'pid', None)
                if pid and pid not in stopped_pids:
                    stopped_pids.append(pid)
                try:
                    if hasattr(p, 'terminate'):
                        p.terminate()
                    if pid:
                        _wait_for_pid_exit(pid, timeout=5.0)
                except Exception:
                    pass
            config.ACTIVE_DIRECT_TRANSCODES.pop(lock_key, None)

    config.TRANSCODE_LOCKS.pop(rel_name, None)
    config.TRANSCODE_LOCKS.pop(f"{rel_name}:direct", None)
    config.TRANSCODE_LOCKS.pop(f"{rel_name}:compat", None)

    for pid in stopped_pids:
        if _pid_is_running(pid):
            _terminate_pid(pid)
    for pid in stopped_pids:
        _wait_for_pid_exit(pid, timeout=5.0)

    return stopped_pids


def _remove_path_with_retries(path, attempts=8, initial_delay=0.15):
    """Remove a file/tree with bounded retries for transient Windows file locks."""
    path = Path(path)
    if not path.exists():
        return True, []
    last_error = None
    for attempt in range(attempts):
        try:
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
            if not path.exists():
                return True, []
        except FileNotFoundError:
            return True, []
        except (PermissionError, OSError) as exc:
            last_error = exc
            if attempt + 1 < attempts:
                time.sleep(initial_delay * (attempt + 1))
    remaining = []
    if path.exists():
        if path.is_dir():
            try:
                remaining = [str(p) for p in path.rglob('*') if p.exists()]
            except OSError:
                remaining = [str(path)]
        else:
            remaining = [str(path)]
    if last_error:
        logger.warning("Failed to remove %s after %d attempts: %s; remaining=%s", path, attempts, last_error, remaining)
    return False, remaining


def purge_transcode_caches_for_media(path, known_hls_dir=None):
    """Purge all HLS chunks and transcoded MP4 cache files with verified deletion."""
    purged = {'hls_dirs': [], 'mp4_files': [], 'failed': []}

    target_hls_dirs = []
    if known_hls_dir:
        hd = Path(known_hls_dir)
        if hd not in target_hls_dirs:
            target_hls_dirs.append(hd)

    if path is not None:
        source_path = Path(path)
        if source_path.exists():
            try:
                calc_dir = hls_cache_dir(source_path)
                if calc_dir not in target_hls_dirs:
                    target_hls_dirs.append(calc_dir)
            except Exception:
                pass

    for hd in target_hls_dirs:
        if not hd.exists():
            # Nothing to remove: logging a purge for a path that never existed made incident
            # timelines unreadable (three such lines appeared during the 2026-09-21 audit).
            continue
        success, remaining = _remove_path_with_retries(hd)
        if success:
            purged['hls_dirs'].append(str(hd))
            logger.info("Purged HLS directory: %s", hd)
        else:
            failure = {'path': str(hd), 'remaining': remaining}
            purged['failed'].append(failure)
            logger.warning("HLS purge incomplete for %s; remaining=%s", hd, remaining)

    if path is not None:
        for mode in ('direct', 'compat'):
            try:
                mp4_path = transcode_cache_path(path, mode)
                prog_path = transcode_progress_path(path, mode)
                part_path = mp4_path.with_name(mp4_path.stem + '.part.mp4')
            except (OSError, ValueError):
                continue
            for cache_path in (mp4_path, prog_path, part_path):
                success, remaining = _remove_path_with_retries(cache_path, attempts=5, initial_delay=0.1)
                if success:
                    if cache_path == mp4_path and not cache_path.exists():
                        if mp4_path.exists():
                            continue
                        purged['mp4_files'].append(str(mp4_path))
                else:
                    purged['failed'].append({'path': str(cache_path), 'remaining': remaining})

    return purged
