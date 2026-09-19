"""Gunicorn production configuration for Media Server."""
import os
from pathlib import Path

# Server socket
bind = os.environ.get("BIND", f"0.0.0.0:{os.environ.get('PORT', '8000')}")
backlog = 2048

# Worker processes & threading
# 1 worker process with 8 threads is optimal for media streaming and in-memory locks
workers = int(os.environ.get("GUNICORN_WORKERS", "1"))
worker_class = "gthread"
threads = int(os.environ.get("GUNICORN_THREADS", "8"))
worker_connections = 1000
timeout = int(os.environ.get("GUNICORN_TIMEOUT", "120"))
keepalive = int(os.environ.get("GUNICORN_KEEPALIVE", "5"))

# Logging
accesslog = "-"
errorlog = "-"
loglevel = os.environ.get("LOG_LEVEL", "info").lower()
access_log_format = '%(h)s %(l)s %(u)s %(t)s "%(r)s" %(s)s %(b)s "%(f)s" "%(a)s" (%(D)s µs)'

# Process naming
proc_name = "media-server-gunicorn"


def on_starting(server):
    """Ensure all media directories, caches, and background workers are initialized."""
    from app.config import (
        MEDIA_ROOT,
        POSTER_CACHE,
        BACKDROP_CACHE,
        SUBTITLE_EMBEDDED_CACHE,
        SUBTITLE_ONLINE_CACHE,
    )
    from app.db import init_db
    from app.services.transcode_service import cleanup_cache_on_startup
    from app.services.worker_service import start_auto_transcoder_worker, start_metadata_refresh_worker
    from app.services.scanner_service import start_media_scanner_worker

    MEDIA_ROOT.mkdir(parents=True, exist_ok=True)
    POSTER_CACHE.mkdir(parents=True, exist_ok=True)
    BACKDROP_CACHE.mkdir(parents=True, exist_ok=True)
    SUBTITLE_EMBEDDED_CACHE.mkdir(parents=True, exist_ok=True)
    SUBTITLE_ONLINE_CACHE.mkdir(parents=True, exist_ok=True)
    cleanup_cache_on_startup()
    init_db()
    start_auto_transcoder_worker()
    start_media_scanner_worker()
    start_metadata_refresh_worker()

