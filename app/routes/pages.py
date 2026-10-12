"""Frontend page routes and PWA manifests."""
import json
from flask import Blueprint, Response, render_template, request

from app import config
from app.services.device_service import current_device_id
from app.utils.formatting import format_bytes_display

pages_bp = Blueprint('pages', __name__)


@pages_bp.route('/manifest.webmanifest')
def manifest():
    """Serve PWA web app manifest."""
    manifest_data = {
        'name': "Anis' Home Media Server",
        'short_name': 'Anis Media',
        'start_url': '/',
        'display': 'standalone',
        'background_color': '#090b10',
        'theme_color': '#090b10',
        'icons': [{'src': '/icon.svg', 'sizes': 'any', 'type': 'image/svg+xml'}]
    }
    return Response(json.dumps(manifest_data), mimetype='application/manifest+json')


@pages_bp.route('/download')
def download():
    """Render the production Android client download page."""
    manifest = {}
    manifest_file = config.UPDATES_DIR / 'production' / 'manifest.json'
    apk_file = config.UPDATES_DIR / 'production' / 'media-server-client.apk'

    if manifest_file.is_file():
        try:
            parsed = json.loads(manifest_file.read_text(encoding='utf-8'))
            if isinstance(parsed, dict):
                manifest = parsed
        except (OSError, json.JSONDecodeError):
            manifest = {}

    return render_template(
        'download.html',
        app_manifest=manifest,
        app_available=apk_file.is_file() and apk_file.stat().st_size > 0,
        app_download_url='/api/app/download?channel=production',
        app_size_display=(
            format_bytes_display(manifest.get('fileSizeBytes'))
            if manifest.get('fileSizeBytes') else None
        ),
    )


@pages_bp.route('/icon.svg')
def icon():
    """Serve vector branding app icon."""
    svg = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
<defs>
  <linearGradient id="g" x1="0%" y1="0%" x2="100%" y2="100%">
    <stop offset="0%" stop-color="#ff334b"/>
    <stop offset="100%" stop-color="#b80017"/>
  </linearGradient>
</defs>
<rect width="128" height="128" rx="28" fill="url(#g)"/>
<rect x="2" y="2" width="124" height="124" rx="26" fill="none" stroke="rgba(255,255,255,0.25)" stroke-width="2"/>
<path fill="#ffffff" d="M50 38l38 26-38 26V38z"/>
<circle cx="84" cy="42" r="7" fill="#ffffff" fill-opacity="0.9"/>
</svg>'''
    return Response(svg, mimetype='image/svg+xml')


@pages_bp.route('/sw.js')
def sw():
    """Serve service worker script."""
    js = "self.addEventListener('install',e=>self.skipWaiting());self.addEventListener('activate',e=>clients.claim());"
    return Response(js, mimetype='application/javascript', headers={'Service-Worker-Allowed': '/'})


@pages_bp.after_request
def stamp_device_cookie(response):
    """Retained for compatibility: stamping now happens app-wide.

    This used to live here, which worked while every page was a blueprint view.
    Since the React SPA migration the user-facing routes are served by the
    catch-all in `app/__init__.py`, and a blueprint-scoped hook does not run for
    routes another blueprint (or the app itself) owns - so the SPA's HTML
    responses stopped carrying `ms_device_id`. The hook moved to the app level
    (`create_app`) where it applies to whichever route served the response.
    """
    return response
