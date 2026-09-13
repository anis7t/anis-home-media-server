"""Background daemon workers for transcoding and library maintenance."""
import logging
import os
import sys
import subprocess
import threading
import time

from app import config
from app.services.media_service import video_paths
from app.services.transcode_service import (
    _is_hls_truly_complete,
    ensure_hls_transcode,
    hls_cache_dir,
    needs_transcode,
)
from app.utils.filesystem import is_video

logger = logging.getLogger(__name__)


def _deprioritize_background_process(proc):
    """Lower CPU and disk-I/O scheduling priority without imposing a resource cap."""
    pid = getattr(proc, 'pid', None)
    if not pid:
        return

    # Increasing niceness makes background FFmpeg yield CPU to normal-priority
    # web/streaming work when the machine is busy, while still allowing it to
    # use all available CPU when higher-priority work is idle.
    try:
        os.setpriority(os.PRIO_PROCESS, pid, 10)
    except (AttributeError, PermissionError, ProcessLookupError, OSError) as exc:
        logger.debug("Could not lower CPU priority for background FFmpeg pid %s: %s", pid, exc)

    # Linux idle I/O class lets uploads and interactive media reads/writes win
    # disk access. ionice is optional, so the server remains portable.
    try:
        if shutil_which := getattr(__import__('shutil'), 'which', None):
            ionice = shutil_which('ionice')
            if ionice:
                subprocess.run(
                    [ionice, '-c', '3', '-p', str(pid)],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                )
    except (OSError, subprocess.SubprocessError) as exc:
        logger.debug("Could not lower I/O priority for background FFmpeg pid %s: %s", pid, exc)


def auto_transcoder_loop():
    """Continuously transcode any non-web movie missing a completed HLS stream."""
    time.sleep(5)
    while not config.SHUTDOWN_EVENT.is_set():
        try:
            for p in video_paths():
                if config.SHUTDOWN_EVENT.is_set():
                    break
                if not is_video(p) or not needs_transcode(p):
                    continue
                try:
                    rel = p.relative_to(config.MEDIA_ROOT).as_posix()
                except ValueError:
                    continue
                hls_dir = hls_cache_dir(p)
                pl_file = hls_dir / 'playlist.m3u8'
                if not _is_hls_truly_complete(pl_file, p):
                    proc = ensure_hls_transcode(rel)
                    if proc is not None:
                        _deprioritize_background_process(proc)
                        while not config.SHUTDOWN_EVENT.is_set():
                            if proc.poll() is not None:
                                break
                            time.sleep(2)
        except Exception as e:
            logger.warning(f"Auto-transcoder loop error: {e}")
        time.sleep(config.PRECACHE_INTERVAL)


def start_auto_transcoder_worker():
    """Start auto-transcoder worker thread (disabled in test environments)."""
    if 'pytest' in sys.modules or os.environ.get('MEDIA_SERVER_DISABLE_PRECACHE', '0') == '1':
        return
    threading.Thread(target=auto_transcoder_loop, name='media-transcoder-worker', daemon=True).start()


def start_precache_worker():
    """Backwards-compatible alias for start_auto_transcoder_worker."""
    start_auto_transcoder_worker()
