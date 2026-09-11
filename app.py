"""Media Server main application and entrypoint.

This module exposes `create_app()` and `app = create_app()`, and re-exports
core services and configuration for backwards compatibility with tests and systemd.
"""
import os
import subprocess
from pathlib import Path
from shutil import which

# Configuration and state
from app.config import (
    ACTIVE_DIRECT_TRANSCODES,
    BACKDROP_CACHE,
    BASE_DIR,
    CACHE_DIR,
    CACHE_MAX_BYTES,
    DATABASE,
    HLS_PROCESSES,
    LOG_LEVEL,
    MEDIA_ROOT,
    POSTER_CACHE,
    POSTER_EXTENSIONS,
    PRECACHE_INTERVAL,
    SCAN_INTERVAL,
    SCANNER_LOCK,
    SHUTDOWN_EVENT,
    SUBTITLE_CACHE,
    SUBTITLE_EMBEDDED_CACHE,
    SUBTITLE_EXTENSIONS,
    SUBTITLE_LOCKS,
    SUBTITLE_ONLINE_CACHE,
    TRANSCODE_LOCKS,
    VIDEO_EXTENSIONS,
    is_vaapi_enabled,
)

# Database
from app.db import get_db, init_db, value

# Utilities
from app.utils.filesystem import is_video, mimetype, parse_range, safe_path
from app.utils.formatting import clean_title, format_bytes_display, format_eta, format_runtime_display
from app.utils.subtitles import compute_opensubtitles_hash, srt_to_vtt

# Services
from app.services.media_service import (
    _paths,
    extract_media_technical_specs,
    get_movies,
    movie,
    poster_for,
    probe_media,
    video_paths,
)
from app.services.scanner_service import (
    run_library_scan,
    scanner_loop,
    start_media_scanner_worker,
    trigger_library_scan,
)
from app.services.subtitles_service import (
    extract_embedded_subtitle,
    fetch_online_subtitle,
    tracks,
)
from app.services.tmdb_service import (
    download_poster,
    get_movie_details,
    load_token,
)
from app.services.transcode_service import (
    ProcessProxy,
    _hls_resume_point,
    _is_hls_truly_complete,
    cleanup_cache,
    cleanup_cache_on_startup,
    compat_transcode_args,
    ensure_hls_transcode,
    find_ffmpeg_for_path,
    get_active_transcodes,
    hls_cache_dir,
    hls_transcode_args,
    needs_transcode,
    transcode_cache_path,
    transcode_progress_path,
)
from app.services.worker_service import (
    auto_transcoder_loop,
    start_auto_transcoder_worker,
    start_precache_worker,
)

# Frontend assets & templates for test assertions and backwards compatibility
_STATIC_CSS_PATH = BASE_DIR / 'static' / 'css' / 'main.css'
CSS = _STATIC_CSS_PATH.read_text(encoding='utf-8') if _STATIC_CSS_PATH.is_file() else ""

_TEMPLATES_DIR = BASE_DIR / 'templates'
DETAILS_HTML = (_TEMPLATES_DIR / 'details.html').read_text(encoding='utf-8') if (_TEMPLATES_DIR / 'details.html').is_file() else ""
PLAYER_HTML = (_TEMPLATES_DIR / 'player.html').read_text(encoding='utf-8') if (_TEMPLATES_DIR / 'player.html').is_file() else ""
LIBRARY_HTML = (_TEMPLATES_DIR / 'library.html').read_text(encoding='utf-8') if (_TEMPLATES_DIR / 'library.html').is_file() else ""
ERROR_HTML = (_TEMPLATES_DIR / 'error.html').read_text(encoding='utf-8') if (_TEMPLATES_DIR / 'error.html').is_file() else ""

# Application Factory
from app import create_app

app = create_app()

if __name__ == '__main__':
    MEDIA_ROOT.mkdir(parents=True, exist_ok=True)
    POSTER_CACHE.mkdir(parents=True, exist_ok=True)
    BACKDROP_CACHE.mkdir(parents=True, exist_ok=True)
    SUBTITLE_EMBEDDED_CACHE.mkdir(parents=True, exist_ok=True)
    SUBTITLE_ONLINE_CACHE.mkdir(parents=True, exist_ok=True)
    cleanup_cache_on_startup()
    init_db()
    start_auto_transcoder_worker()
    start_media_scanner_worker()
    port = int(os.environ.get('PORT', 8000))
    host = os.environ.get('HOST', '0.0.0.0')

    use_gunicorn = os.environ.get('FLASK_DEBUG', '0') != '1' and not os.environ.get('USE_DEV_SERVER')
    if use_gunicorn:
        try:
            import sys
            import logging
            from gunicorn.app.base import BaseApplication

            class StandaloneGunicornApp(BaseApplication):
                def __init__(self, wsgi_app, options=None):
                    self.options = options or {}
                    self.application = wsgi_app
                    super().__init__()

                def load_config(self):
                    for key, val in self.options.items():
                        if key in self.cfg.settings and val is not None:
                            self.cfg.set(key.lower(), val)

                def load(self):
                    return self.application

            gunicorn_opts = {
                'bind': f'{host}:{port}',
                'workers': int(os.environ.get('GUNICORN_WORKERS', '1')),
                'worker_class': 'gthread',
                'threads': int(os.environ.get('GUNICORN_THREADS', '8')),
                'timeout': int(os.environ.get('GUNICORN_TIMEOUT', '120')),
                'keepalive': int(os.environ.get('GUNICORN_KEEPALIVE', '5')),
                'accesslog': '-',
                'errorlog': '-',
                'loglevel': os.environ.get('LOG_LEVEL', 'info').lower(),
                'proc_name': 'media-server',
            }
            logging.info(f"Starting production Gunicorn WSGI server on {host}:{port} with 8 worker threads...")
            StandaloneGunicornApp(app, gunicorn_opts).run()
            sys.exit(0)
        except Exception as e:
            import logging
            logging.warning(f"Gunicorn startup failed ({e}); falling back to Werkzeug development server.")

    app.run(
        host=host,
        port=port,
        debug=False,
    )
