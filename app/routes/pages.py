"""Frontend page routes and PWA manifests."""
import json
from flask import Blueprint, Response, abort, render_template, request

from app import config
from app.db import get_db
from app.services.media_service import (
    extract_media_technical_specs,
    get_movies,
    movie,
)
from app.services.subtitles_service import tracks
from app.services.system_service import get_system_telemetry
from app.services.transcode_service import get_active_transcodes
from app.utils.filesystem import is_video, safe_path
from app.utils.formatting import format_runtime_display

pages_bp = Blueprint('pages', __name__)


@pages_bp.route('/')
def home():
    """Render home media library page with search, sorting, and transcode status."""
    q = request.args.get('q', '').strip().lower()
    sort = request.args.get('sort', 'title')
    movies = get_movies()
    if q:
        movies = [m for m in movies if q in (m['title'] + ' ' + str(m['year']) + ' ' + m['genres']).lower()]
    movies.sort(
        key=(lambda m: m['updated_at'] or '') if sort == 'recent' else lambda m: m['title'].lower(),
        reverse=sort == 'recent'
    )
    watching = sorted(
        [m for m in movies if m['position'] > 10 and (not m['duration'] or m['position'] < m['duration'] - 10)],
        key=lambda m: m['updated_at'] or '',
        reverse=True
    )
    active_transcodes = get_active_transcodes()
    try:
        telemetry = get_system_telemetry()
    except Exception:
        telemetry = None
    return render_template(
        'library.html',
        movies=movies,
        watching=watching,
        q=q,
        sort=sort,
        active_transcodes=active_transcodes,
        telemetry=telemetry
    )


@pages_bp.route('/movie/<path:filename>')
def details(filename):
    """Render movie details hero, technical specifications, cast rail, and trailer modal."""
    path = safe_path(filename)
    if not is_video(path):
        abort(404)
    from app.services.device_service import get_or_create_device_id
    device_id, _ = get_or_create_device_id(request)
    db = get_db()
    m = movie(path, db, device_id=device_id)
    backdrop = m['tmdb_id'] if m['tmdb_id'] and (config.BACKDROP_CACHE / f"{m['tmdb_id']}.jpg").is_file() else None
    extended = {}
    if m.get('details_json'):
        try:
            extended = json.loads(m['details_json'])
        except Exception:
            extended = {}
    db.close()
    specs = extract_media_technical_specs(path, m)
    formatted_runtime = format_runtime_display(m.get('runtime'))
    active_transcodes = get_active_transcodes()
    transcode_info = next((t for t in active_transcodes if t['filename'] == filename), None)
    html = render_template(
        'details.html',
        movie=m,
        backdrop=backdrop,
        extended=extended,
        specs=specs,
        formatted_runtime=formatted_runtime,
        transcode_info=transcode_info
    )
    details_script = '<script src="/static/js/details-enhancements.js?v=1" defer></script>'
    return html.replace('</body>', details_script + '</body>') if '</body>' in html else html + details_script


@pages_bp.route('/watch/<path:filename>')
def watch(filename):
    """Render media player interface with HLS/compat streaming and custom controls."""
    path = safe_path(filename)
    if not is_video(path):
        abort(404)
    from app.services.device_service import get_or_create_device_id
    device_id, _ = get_or_create_device_id(request)
    db = get_db()
    m = movie(path, db, device_id=device_id)
    db.close()
    active_transcodes = get_active_transcodes()
    transcode_info = next((t for t in active_transcodes if t['filename'] == filename), None)
    html = render_template(
        'player.html',
        movie=m,
        tracks=tracks(path, m),
        transcode_info=transcode_info
    )
    prefs_script = '<script src="/static/js/player-prefs.js?v=5" defer></script>'
    enhancement_script = '<script src="/static/js/player-enhancements.js?v=3" defer></script>'
    injected = prefs_script + enhancement_script
    return html.replace('</body>', injected + '</body>') if '</body>' in html else html + injected


@pages_bp.route('/manifest.webmanifest')
def manifest():
    """Serve PWA web app manifest."""
    manifest_data = {
        'name': "Anis' Media Server",
        'short_name': 'Anis Media',
        'start_url': '/',
        'display': 'standalone',
        'background_color': '#090b10',
        'theme_color': '#090b10',
        'icons': [{'src': '/icon.svg', 'sizes': 'any', 'type': 'image/svg+xml'}]
    }
    return Response(json.dumps(manifest_data), mimetype='application/manifest+json')


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


@pages_bp.route('/manage')
@pages_bp.route('/library')
def manage():
    """Render media library management dashboard with delete/purge actions and storage metrics."""
    from app.services.media_service import get_managed_media_items
    from app.services.transcode_service import get_active_transcodes, get_cache_dir
    from app.utils.formatting import format_bytes_display

    items = get_managed_media_items()
    total_size = sum(i['size_bytes'] for i in items)

    cache_dir = get_cache_dir()
    hls_dir = cache_dir / 'hls'
    transcode_dir = cache_dir / 'transcodes'
    hls_size = sum(f.stat().st_size for f in hls_dir.rglob('*') if f.is_file()) if hls_dir.is_dir() else 0
    mp4_size = sum(f.stat().st_size for f in transcode_dir.rglob('*') if f.is_file()) if transcode_dir.is_dir() else 0
    total_cache_size = hls_size + mp4_size

    active_transcodes = get_active_transcodes()

    return render_template(
        'manage.html',
        items=items,
        total_movies=len(items),
        total_size_str=format_bytes_display(total_size),
        total_cache_str=format_bytes_display(total_cache_size),
        active_transcodes=active_transcodes,
    )


@pages_bp.route('/devices')
@pages_bp.route('/clients')
def devices():
    """Render client devices and network telemetry dashboard."""
    from app.services.device_service import get_all_devices, get_or_create_device_id
    current_dev_id, _ = get_or_create_device_id(request)
    dev_list, stats = get_all_devices(current_device_id=current_dev_id)
    return render_template(
        'devices.html',
        devices=dev_list,
        stats=stats,
        current_dev_id=current_dev_id,
    )


@pages_bp.after_request
def stamp_device_cookie(response):
    """Ensure persistent device tracking cookie is set on client page visits."""
    try:
        if response.mimetype == 'text/html':
            response.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
            response.headers['Pragma'] = 'no-cache'
            from app.services.device_service import register_device_request
            dev_id, is_new = register_device_request(request)
            if is_new or not request.cookies.get('ms_device_id'):
                response.set_cookie(
                    'ms_device_id',
                    dev_id,
                    max_age=31536000,
                    path='/',
                    samesite='Lax'
                )
    except Exception:
        pass
    return response
