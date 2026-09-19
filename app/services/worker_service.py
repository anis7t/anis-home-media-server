"""Background daemon workers for transcoding and library maintenance."""
import logging
import os
import sys
import threading
import time
from queue import Empty, Queue

from app import config
from app.services.media_service import video_paths
from app.services.transcode_service import (
    _is_hls_truly_complete,
    ensure_hls_transcode,
    hls_cache_dir,
    needs_transcode,
)
from app.utils.filesystem import get_rel_path, is_video, safe_path

logger = logging.getLogger(__name__)


_MANUAL_TRANSCODE_QUEUE = Queue()
_MANUAL_TRANSCODE_QUEUED = set()
_MANUAL_TRANSCODE_LOCK = threading.Lock()
_MANUAL_TRANSCODE_WORKER = None


def _manual_transcode_worker():
    """Process manually requested transcodes one at a time to avoid GPU/FFmpeg overload."""
    while not config.SHUTDOWN_EVENT.is_set():
        try:
            rel = _MANUAL_TRANSCODE_QUEUE.get(timeout=1.0)
        except Empty:
            continue

        try:
            path = safe_path(rel)
            if not is_video(path):
                continue

            hls_dir = hls_cache_dir(path)
            playlist = hls_dir / "playlist.m3u8"
            if _is_hls_truly_complete(playlist, path) or not needs_transcode(path):
                continue

            proc = ensure_hls_transcode(rel)
            if proc is None:
                logger.warning("Manual transcode could not start for %s", rel)
                continue

            logger.info("Manual transcode started for %s (queued job)", rel)
            while not config.SHUTDOWN_EVENT.is_set() and proc.poll() is None:
                time.sleep(2)

            if proc.poll() not in (0, None):
                logger.warning("Manual transcode failed for %s with return code %s", rel, proc.poll())
        except Exception as exc:
            logger.warning("Manual transcode worker failed for %s: %s", rel, exc)
        finally:
            with _MANUAL_TRANSCODE_LOCK:
                _MANUAL_TRANSCODE_QUEUED.discard(rel)
            _MANUAL_TRANSCODE_QUEUE.task_done()


def start_manual_transcode_worker():
    """Start the persistent manual-transcode queue worker once per process."""
    global _MANUAL_TRANSCODE_WORKER
    with _MANUAL_TRANSCODE_LOCK:
        if _MANUAL_TRANSCODE_WORKER is None or not _MANUAL_TRANSCODE_WORKER.is_alive():
            _MANUAL_TRANSCODE_WORKER = threading.Thread(
                target=_manual_transcode_worker,
                name="manual-transcode-worker",
                daemon=True,
            )
            _MANUAL_TRANSCODE_WORKER.start()


def _ensure_manual_transcode_worker():
    global _MANUAL_TRANSCODE_WORKER
    with _MANUAL_TRANSCODE_LOCK:
        if _MANUAL_TRANSCODE_WORKER is None or not _MANUAL_TRANSCODE_WORKER.is_alive():
            _MANUAL_TRANSCODE_WORKER = threading.Thread(
                target=_manual_transcode_worker,
                name="manual-transcode-worker",
                daemon=True,
            )
            _MANUAL_TRANSCODE_WORKER.start()
\n

def trigger_missing_transcodes():
    """Queue every eligible media item missing a complete HLS cache.

    The scan request only enqueues work. A single background worker starts
    transcodes sequentially so one Scan click cannot launch many simultaneous
    multi-GPU FFmpeg pipelines and exhaust the machine.
    """
    queued = 0
    skipped = 0
    errors = 0

    try:
        paths = list(video_paths())
    except Exception as exc:
        logger.warning("Unable to enumerate media for manual transcode pass: %s", exc)
        return {"started": 0, "queued": 0, "skipped": 0, "errors": 1}

    _ensure_manual_transcode_worker()

    for p in paths:
        if config.SHUTDOWN_EVENT.is_set():
            break
        if not is_video(p):
            skipped += 1
            continue

        try:
            hls_dir = hls_cache_dir(p)
            playlist = hls_dir / "playlist.m3u8"
            if _is_hls_truly_complete(playlist, p) or not needs_transcode(p):
                skipped += 1
                continue

            rel = get_rel_path(p)
            with _MANUAL_TRANSCODE_LOCK:
                if rel in _MANUAL_TRANSCODE_QUEUED:
                    skipped += 1
                    continue
                _MANUAL_TRANSCODE_QUEUED.add(rel)
            _MANUAL_TRANSCODE_QUEUE.put(rel)
            queued += 1
        except Exception as exc:
            errors += 1
            logger.warning("Manual transcode queue failed for %s: %s", get_rel_path(p), exc)

    return {"started": 0, "queued": queued, "skipped": skipped, "errors": errors}


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
                        if policy in ('archive', 'delete_source', 'delete_raw', 'delete_original'):
                            from app.services.transcode_service import apply_post_transcode_policy
                            apply_post_transcode_policy(p, policy=policy)
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


