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


def trigger_missing_transcodes():
    """Start HLS transcoding for every eligible media item missing a complete cache."""
    started = 0
    skipped = 0
    errors = 0

    try:
        paths = list(video_paths())
    except Exception as exc:
        logger.warning("Unable to enumerate media for manual transcode pass: %s", exc)
        return {"started": 0, "skipped": 0, "errors": 1}

    for p in paths:
        if config.SHUTDOWN_EVENT.is_set():
            break
        if not is_video(p) or not needs_transcode(p):
            skipped += 1
            continue

        try:
            rel = p.relative_to(config.MEDIA_ROOT).as_posix()
        except ValueError:
            skipped += 1
            continue

        try:
            hls_dir = hls_cache_dir(p)
            playlist = hls_dir / "playlist.m3u8"
            already_complete = _is_hls_truly_complete(playlist, p)
            proc = ensure_hls_transcode(rel)

            if already_complete:
                skipped += 1
            elif proc is not None:
                started += 1
            else:
                skipped += 1
        except Exception as exc:
            errors += 1
            logger.warning("Manual transcode trigger failed for %s: %s", rel, exc)

    return {"started": started, "skipped": skipped, "errors": errors}


def auto_transcoder_loop():
    """Continuously transcode any non-web movie missing a completed HLS stream."""
    time.sleep(5)
    while not config.SHUTDOWN_EVENT.is_set():
        try:
            result = trigger_missing_transcodes()
            if result.get("started"):
                logger.info(
                    "Auto-transcoder pass started %d missing HLS transcodes",
                    result["started"]
                )
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

