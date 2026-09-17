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
from app.utils.filesystem import get_rel_path, is_video

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
                rel = get_rel_path(p)
                hls_dir = hls_cache_dir(p)
                pl_file = hls_dir / 'playlist.m3u8'
                if not _is_hls_truly_complete(pl_file, p):
                    proc = ensure_hls_transcode(rel)
                    if proc is not None:
                        while not config.SHUTDOWN_EVENT.is_set():
                            if proc.poll() is not None:
                                break
                            time.sleep(2)
                # Check post-transcode retention policy if transcode is complete
                if _is_hls_truly_complete(pl_file, p):
                    try:
                        from app.db import get_setting
                        policy = get_setting('retention_policy', config.DEFAULT_RETENTION_POLICY)
                        if policy == 'archive':
                            from app.services.transcode_service import apply_post_transcode_policy
                            apply_post_transcode_policy(p, policy='archive')
                    except Exception as e:
                        logger.warning(f"Failed to apply post-transcode policy for {p}: {e}")
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


def metadata_refresh_loop():
    """Periodic daemon loop that refreshes TMDb metadata every 4 hours."""
    time.sleep(30)
    while not config.SHUTDOWN_EVENT.is_set():
        try:
            if not config.SCANNER_LOCK.locked():
                with config.SCANNER_LOCK:
                    from app.services.tmdb_service import refresh_all_library_metadata
                    refresh_all_library_metadata(force=False, max_age_seconds=config.METADATA_REFRESH_INTERVAL)
        except Exception as e:
            logger.warning(f"Metadata refresh loop error: {e}")

        # Sleep in intervals to remain responsive to shutdown events
        elapsed = 0
        interval = config.METADATA_REFRESH_INTERVAL
        while elapsed < interval and not config.SHUTDOWN_EVENT.is_set():
            time.sleep(min(5, interval - elapsed))
            elapsed += 5


def start_metadata_refresh_worker():
    """Start background TMDb metadata refresh thread unless disabled by environment."""
    if 'pytest' in sys.modules or os.environ.get('MEDIA_SERVER_DISABLE_METADATA_REFRESH', '0') == '1':
        return
    threading.Thread(target=metadata_refresh_loop, name='metadata-refresh-worker', daemon=True).start()


def cache_maintenance_loop():
    """Periodic daemon loop that audits and safely purges orphaned transcode caches every 2 hours."""
    time.sleep(60)
    while not config.SHUTDOWN_EVENT.is_set():
        try:
            from app.services.transcode_service import purge_orphaned_caches
            res = purge_orphaned_caches(dry_run=False)
            if res.get('purged_count', 0) > 0:
                logger.info(
                    f"Periodic cache maintenance purged {res['purged_count']} orphaned directories ({res['freed_bytes']} bytes freed)"
                )
        except Exception as e:
            logger.warning(f"Cache maintenance loop error: {e}")

        elapsed = 0
        interval = 7200  # 2 hours
        while elapsed < interval and not config.SHUTDOWN_EVENT.is_set():
            time.sleep(min(5, interval - elapsed))
            elapsed += 5


def start_cache_maintenance_worker():
    """Start background cache maintenance thread unless disabled by environment."""
    if 'pytest' in sys.modules or os.environ.get('MEDIA_SERVER_DISABLE_CACHE_MAINTENANCE', '0') == '1':
        return
    threading.Thread(target=cache_maintenance_loop, name='cache-maintenance-worker', daemon=True).start()


