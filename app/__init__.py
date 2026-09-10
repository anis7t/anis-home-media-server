"""Media Server Flask application package and factory."""
import logging
import subprocess
from pathlib import Path
from shutil import which
from flask import Flask, render_template
from markupsafe import Markup, escape

from app import config
from app.routes.api import api_bp
from app.routes.media import media_bp
from app.routes.pages import pages_bp
from app.routes.subtitles import subtitles_bp

# Configuration and state re-exports
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

# Database re-exports
from app.db import get_db, init_db, value

# Utility re-exports
from app.utils.filesystem import is_video, mimetype, parse_range, safe_path
from app.utils.formatting import clean_title, format_bytes_display, format_eta, format_runtime_display
from app.utils.subtitles import compute_opensubtitles_hash, srt_to_vtt

# Service re-exports
from app.services.media_service import (
    _paths,
    extract_media_technical_specs,
    get_managed_media_items,
    get_movies,
    movie,
    poster_for,
    probe_media,
    purge_media,
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
    purge_subtitles_for_media,
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
    purge_transcode_caches_for_media,
    stop_transcodes_for_media,
    transcode_cache_path,
    transcode_progress_path,
)
from app.services.worker_service import (
    auto_transcoder_loop,
    start_auto_transcoder_worker,
    start_precache_worker,
)
from app.services.system_service import get_system_telemetry

# Frontend assets & templates for test assertions
_STATIC_CSS_PATH = BASE_DIR / 'static' / 'css' / 'main.css'
CSS = _STATIC_CSS_PATH.read_text(encoding='utf-8') if _STATIC_CSS_PATH.is_file() else ""

_TEMPLATES_DIR = BASE_DIR / 'templates'
DETAILS_HTML = (_TEMPLATES_DIR / 'details.html').read_text(encoding='utf-8') if (_TEMPLATES_DIR / 'details.html').is_file() else ""
PLAYER_HTML = (_TEMPLATES_DIR / 'player.html').read_text(encoding='utf-8') if (_TEMPLATES_DIR / 'player.html').is_file() else ""
LIBRARY_HTML = (_TEMPLATES_DIR / 'library.html').read_text(encoding='utf-8') if (_TEMPLATES_DIR / 'library.html').is_file() else ""
ERROR_HTML = (_TEMPLATES_DIR / 'error.html').read_text(encoding='utf-8') if (_TEMPLATES_DIR / 'error.html').is_file() else ""


def create_app(test_config=None):
    """Create and configure the Media Server Flask application."""
    base_path = Path(__file__).resolve().parent.parent
    app_instance = Flask(
        __name__,
        template_folder=str(base_path / 'templates'),
        static_folder=str(base_path / 'static'),
    )

    logging.basicConfig(level=config.LOG_LEVEL)

    # Register blueprints
    app_instance.register_blueprint(pages_bp)
    app_instance.register_blueprint(media_bp)
    app_instance.register_blueprint(subtitles_bp)
    app_instance.register_blueprint(api_bp)

    # Alias bare endpoint names so url_for('details'), url_for('poster'), etc. work seamlessly
    for rule in list(app_instance.url_map.iter_rules()):
        if '.' in rule.endpoint:
            bare = rule.endpoint.split('.', 1)[1]
            if bare not in app_instance.view_functions:
                app_instance.add_url_rule(
                    rule.rule,
                    endpoint=bare,
                    view_func=app_instance.view_functions[rule.endpoint],
                    methods=rule.methods,
                )

    # Context processors
    @app_instance.context_processor
    def helpers():
        from flask import url_for

        def poster(m, show_bar=False):
            pct = m.get('percent', 0) if isinstance(m, dict) else getattr(m, 'percent', 0)
            bar_html = f'<div class="bar"><i style="width:{pct:.2f}%"></i></div>' if (show_bar and pct and pct > 0) else ''
            if m.get('poster'):
                src = (
                    url_for('tmdb_poster', tmdb_id=m['tmdb_id'])
                    if m['poster'].startswith('tmdb:')
                    else url_for('poster', filename=m['poster'][6:])
                )
                return f'<div class="art"><img src="{escape(src)}" alt="" loading="lazy">{bar_html}</div>'
            return f'<div class="art"><div class="fallback">◉</div>{bar_html}</div>'

        def card(m):
            return (
                f'<a class="card" href="{escape(url_for("details", filename=m["filename"]))}">'
                f'{poster(m, show_bar=True)}'
                f'<div class="name">{escape(m["title"])}</div>'
                f'<div class="year">{escape(m["year"] or "")}</div></a>'
            )

        import sys
        if 'app' in sys.modules and hasattr(sys.modules['app'], 'CSS'):
            css_content = sys.modules['app'].CSS
        else:
            css_content = CSS

        return dict(css=Markup(css_content), poster=poster, card=card)

    # Error handlers
    @app_instance.errorhandler(404)
    def missing(_):
        return render_template('error.html', code=404, message='That media item is unavailable or has moved.'), 404

    @app_instance.errorhandler(403)
    def denied(_):
        return render_template('error.html', code=403, message='That location is not available.'), 403

    return app_instance


app = create_app()

