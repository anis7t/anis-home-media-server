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
from app.utils.filesystem import is_video, safe_path

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


def hls_cache_dir(path):
    """Generate deterministic directory path for HLS chunks and playlist."""
    path = Path(path)
    key = hashlib.sha256(f'hls:{path}:{path.stat().st_size}:{path.stat().st_mtime_ns}'.encode()).hexdigest()
    return get_cache_dir() / 'hls' / key


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
    """Clean orphaned part files, purge orphaned HLS/preview directories, and enforce cache size cap on server start."""
    cleanup_cache()
    try:
        purge_orphaned_caches()
    except Exception as e:
        logger.warning("Startup orphaned cache purge error: %s", e)


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

    # Gather active cache directories from currently known video files
    try:
        active_videos = video_paths()
    except Exception:
        active_videos = []

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
        except Exception:
            continue

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
    }


def purge_orphaned_caches(dry_run=False):
    """Purge all verified orphaned HLS and preview cache directories.

    Uses _remove_path_with_retries to ensure Windows file locks are handled safely.
    Returns dict with freed_bytes, purged_dirs, failed_dirs, dry_run.
    """
    audit = audit_orphaned_caches()
    orphans = audit['orphaned_hls'] + audit['orphaned_previews']

    freed_bytes = 0
    purged_dirs = []
    failed_dirs = []

    for item in orphans:
        target = Path(item['path'])
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
        'dry_run': dry_run,
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
        try:
            rel = path.relative_to(config.MEDIA_ROOT)
        except ValueError:
            rel = Path(path.name)
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
    """Find any running external FFmpeg process actively converting target media path and extract PID and HLS output dir."""
    target = str(path)
    target_name = Path(path).name
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


def _hls_resume_point(directory, playlist_path):
    """Parse an existing HLS playlist or segment cache to find the resume point.

    Returns (resume_time_seconds, count_of_segments) or (0.0, 0) if
    no usable cache exists. Keeps existing valid .ts files intact so FFmpeg
    can continue from where it left off.
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

    if not valid_segments and (directory / 'segment_000000.ts').is_file() and (directory / 'segment_000000.ts').stat().st_size > 0:
        idx = 0
        disk_segs = []
        while True:
            f = directory / f'segment_{idx:06d}.ts'
            if not f.is_file() or f.stat().st_size == 0:
                break
            disk_segs.append(f)
            idx += 1
        if disk_segs:
            logger.info("HLS resume: reconstructed playlist from %d consecutive segment files on disk", len(disk_segs))
            for i in range(len(disk_segs) - 1):
                valid_segments.append((4.0, disk_segs[i].name))
                cumulative += 4.0
            last_file = disk_segs[-1]
            last_dur = 4.0
            try:
                probe = subprocess.run(
                    ['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', str(last_file)],
                    capture_output=True, text=True, check=False
                )
                last_dur = float(probe.stdout.strip())
            except Exception:
                pass
            valid_segments.append((last_dur, last_file.name))
            cumulative += last_dur

    if not valid_segments:
        logger.info('HLS resume check: 0 valid segments found for %s', directory)
        return 0.0, 0

    first_extinf = text.find('#EXTINF:') if text else -1
    header = text[:first_extinf] if first_extinf != -1 else "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-INDEPENDENT-SEGMENTS\n"
    header = header.replace('#EXT-X-ENDLIST', '')
    body = "".join(f"#EXTINF:{d:.6f},\n{name}\n" for d, name in valid_segments)
    clean_pl = header + body
    playlist_path.write_text(clean_pl)
    try:
        bak_path.write_text(clean_pl)
    except OSError:
        pass

    next_seg = len(valid_segments)
    logger.info('HLS resume: found %d valid segments, cumulative %.1fs, resuming from segment %d',
                len(valid_segments), cumulative, next_seg)
    return cumulative, next_seg


def _is_hls_truly_complete(playlist_path, source_path):
    """Check if an HLS playlist is truly complete (covers at least 90% of source duration)."""
    playlist_path = Path(playlist_path)
    source_path = Path(source_path)
    if not playlist_path.is_file():
        return False
    try:
        text = playlist_path.read_text(errors='replace')
    except OSError:
        return False
    if '#EXT-X-ENDLIST' not in text:
        return False

    extinf_re = re.compile(r'^#EXTINF:([\d.]+)', re.MULTILINE)
    cumulative = sum(float(m.group(1)) for m in extinf_re.finditer(text))
    try:
        source_duration = float(probe_media(source_path).get('format', {}).get('duration') or 0)
    except (TypeError, ValueError):
        source_duration = 0
    if source_duration <= 0:
        return True
    ratio = cumulative / source_duration
    if ratio >= 0.90:
        return True
    logger.info('HLS completeness check: playlist has %.1fs (%.1f%%) of %.1fs source — treating as INCOMPLETE',
                cumulative, ratio * 100, source_duration)
    return False


def ensure_hls_transcode(filename):
    """Ensure HLS transcode is running for *filename*, returning the process or None."""
    path = safe_path(filename)
    if not is_video(path) or config.SHUTDOWN_EVENT.is_set():
        return None
    directory = hls_cache_dir(path)
    playlist = directory / 'playlist.m3u8'
    lock = config.TRANSCODE_LOCKS.setdefault('hls:' + filename, threading.Lock())
    with lock:
        if config.SHUTDOWN_EVENT.is_set():
            return None
        is_complete = _is_hls_truly_complete(playlist, path)
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
            resume_time, start_seg = _hls_resume_point(directory, playlist)
            resuming = resume_time > 0.0 and start_seg > 0
            if not resuming and directory.is_dir():
                for f in directory.glob('*'):
                    f.unlink(missing_ok=True)
            if resuming and playlist.is_file():
                pl_text = playlist.read_text(errors='replace')
                pl_text = pl_text.replace('#EXT-X-ENDLIST', '').rstrip() + '\n'
                playlist.write_text(pl_text)
                try:
                    (directory / 'playlist.m3u8.bak').write_text(pl_text)
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
                    and not (
                        video.get('codec_name') == 'h264'
                        and (video.get('height') or 0) <= 1088
                        and (video.get('width') or 0) <= 1920
                        and video.get('pix_fmt', 'yuv420p') in {'yuv420p', 'yuvj420p'}
                    )
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
        try:
            rel = p.relative_to(config.MEDIA_ROOT).as_posix()
        except ValueError:
            continue
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
