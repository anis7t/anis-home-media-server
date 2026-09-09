"""Background daemon workers for transcoding and library maintenance."""
import logging
import os
import sys
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

