"""Subtitle delivery and track catalog routes."""
from flask import Blueprint, Response, abort, jsonify, send_file

from app import config
from app.db import get_db
from app.services.media_service import movie
from app.services.subtitles_service import (
    extract_embedded_subtitle,
    fetch_online_subtitle,
    tracks,
)
from app.utils.filesystem import is_video, safe_path
from app.utils.subtitles import srt_to_vtt

subtitles_bp = Blueprint('subtitles', __name__)


@subtitles_bp.route('/subtitles/<path:filename>/<name>')
def subtitle(filename, name):
    """Serve sidecar subtitle file converted on-the-fly to WebVTT."""
    video = safe_path(filename)
    sub = (video.parent / name).resolve()
    if not sub.is_file() and (config.MEDIA_ROOT / name).is_file():
        sub = (config.MEDIA_ROOT / name).resolve()
    roots = config.get_media_roots() if hasattr(config, 'get_media_roots') else [config.MEDIA_ROOT]
    is_authorized = any(sub == r or r in sub.parents for r in roots)
    if not is_video(video) or not sub.is_file() or not is_authorized or sub.suffix.lower() not in config.SUBTITLE_EXTENSIONS:
        abort(404)
    text = sub.read_text(encoding='utf-8-sig', errors='replace')
    return Response(srt_to_vtt(text), mimetype='text/vtt', headers={'Cache-Control': 'private, max-age=3600'})


@subtitles_bp.route('/subtitles/embedded/<path:filename>/<int:stream_idx>.vtt')
def subtitle_embedded(filename, stream_idx):
    """Extract and serve embedded subtitle track as WebVTT."""
    video = safe_path(filename)
    if not is_video(video):
        abort(404)
    vtt = extract_embedded_subtitle(video, stream_idx)
    if not vtt or not vtt.is_file():
        abort(404)
    return send_file(vtt, mimetype='text/vtt', conditional=True, max_age=3600)


@subtitles_bp.route('/subtitles/online/<path:filename>.vtt')
def subtitle_online(filename):
    """Fetch and serve online subtitle from OpenSubtitles as WebVTT."""
    video = safe_path(filename)
    if not is_video(video):
        abort(404)
    db = get_db()
    m = movie(video, db)
    db.close()
    vtt = fetch_online_subtitle(video, m)
    if not vtt or not vtt.is_file():
        abort(404)
    return send_file(vtt, mimetype='text/vtt', conditional=True, max_age=3600)


@subtitles_bp.route('/api/subtitles/<path:filename>')
def api_subtitles(filename):
    """Return JSON listing of all available subtitle tracks for a movie."""
    video = safe_path(filename)
    if not is_video(video):
        abort(404)
    db = get_db()
    m = movie(video, db)
    db.close()
    return jsonify(tracks=tracks(video, m))

