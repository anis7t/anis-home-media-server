"""Production WSGI entry point for Windows using Waitress."""
import logging
import os
import sys
from pathlib import Path

from dotenv import load_dotenv

# Ensure environment variables are loaded
load_dotenv()

from app import create_app
from app.config import (
    BACKDROP_CACHE,
    MEDIA_ROOT,
    POSTER_CACHE,
    SUBTITLE_EMBEDDED_CACHE,
    SUBTITLE_ONLINE_CACHE,
)
from app.db import init_db
from app.services.scanner_service import start_media_scanner_worker
from app.services.transcode_service import cleanup_cache_on_startup
from app.services.worker_service import start_auto_transcoder_worker


def init_runtime():
    """Ensure all required directories, database schemas, and background workers are initialized."""
    MEDIA_ROOT.mkdir(parents=True, exist_ok=True)
    POSTER_CACHE.mkdir(parents=True, exist_ok=True)
    BACKDROP_CACHE.mkdir(parents=True, exist_ok=True)
    SUBTITLE_EMBEDDED_CACHE.mkdir(parents=True, exist_ok=True)
    SUBTITLE_ONLINE_CACHE.mkdir(parents=True, exist_ok=True)

    cleanup_cache_on_startup()
    init_db()
    start_auto_transcoder_worker()
    start_media_scanner_worker()


def main():
    logging.basicConfig(
        level=getattr(logging, os.environ.get("LOG_LEVEL", "INFO").upper(), logging.INFO),
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    init_runtime()

    host = os.environ.get("HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "8000"))
    threads = int(os.environ.get("WAITRESS_THREADS", "8"))

    try:
        from waitress import serve
    except ImportError:
        logging.error(
            "Waitress is not installed. Please install it using 'pip install waitress'."
        )
        sys.exit(1)

    logging.info(
        f"Starting Waitress WSGI server on http://{host}:{port} with {threads} threads..."
    )
    app = create_app()
    serve(app, host=host, port=port, threads=threads)


if __name__ == "__main__":
    main()

