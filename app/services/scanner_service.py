"""Library scanning background service and triggers."""
import logging
import os
import sys
import threading
import time

from app import config

logger = logging.getLogger(__name__)


def run_library_scan(refresh_metadata=False, force_refresh=False):
    """Execute media directory scan and TMDB metadata enrichment under lock."""
    # Test patch dynamic delegation
    if 'app' in sys.modules and hasattr(sys.modules['app'], 'run_library_scan'):
        app_mod = sys.modules['app']
        if app_mod.run_library_scan != run_library_scan:
            try:
                return app_mod.run_library_scan(refresh_metadata=refresh_metadata, force_refresh=force_refresh)
            except TypeError:
                return app_mod.run_library_scan()

    if not config.SCANNER_LOCK.acquire(blocking=False):
        return
    try:
        import scanner
        scanner.scan()
        if refresh_metadata:
            from app.services.tmdb_service import refresh_all_library_metadata
            refresh_all_library_metadata(force=force_refresh)
    except Exception as e:
        logger.warning(f"Library scanner error: {e}")
    finally:
        config.SCANNER_LOCK.release()


def trigger_library_scan(refresh_metadata=False, force_refresh=False):
    """Trigger an asynchronous library scan if one is not already running."""
    if config.SCANNER_LOCK.locked():
        return False
    thread = threading.Thread(
        target=run_library_scan,
        args=(refresh_metadata, force_refresh),
        name="media-scanner-manual",
        daemon=True
    )
    thread.start()
    return True


def scanner_loop():
    """Periodic daemon loop that invokes library scan every SCAN_INTERVAL seconds."""
    time.sleep(10)
    while not config.SHUTDOWN_EVENT.is_set():
        try:
            run_library_scan()
        except Exception as e:
            logger.warning(f"Scanner loop error: {e}")
        time.sleep(config.SCAN_INTERVAL)


def start_media_scanner_worker():
    """Start background library scanner thread unless disabled by environment."""
    if os.environ.get('MEDIA_SERVER_DISABLE_SCANNER', '0') == '1':
        return
    threading.Thread(target=scanner_loop, name='media-scanner', daemon=True).start()

