"""Library scanning background service and triggers."""
import logging
import os
import sys
import threading
import time

from app import config

logger = logging.getLogger(__name__)


def run_library_scan():
    """Execute media directory scan and TMDB metadata enrichment under lock."""
    # Test patch dynamic delegation
    if 'app' in sys.modules and hasattr(sys.modules['app'], 'run_library_scan'):
        app_mod = sys.modules['app']
        if app_mod.run_library_scan != run_library_scan:
            return app_mod.run_library_scan()

    if not config.SCANNER_LOCK.acquire(blocking=False):
        return
    try:
        import scanner
        scanner.scan()
    except Exception as e:
        logger.warning(f"Library scanner error: {e}")
    finally:
        config.SCANNER_LOCK.release()


def trigger_library_scan():
    """Trigger an asynchronous library scan if one is not already running."""
    if config.SCANNER_LOCK.locked():
        return False
    thread = threading.Thread(target=run_library_scan, name="media-scanner-manual", daemon=True)
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

