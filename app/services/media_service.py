"""Media inspection, technical specifications, and library metadata service."""
import json
import subprocess
import sys
import time
from pathlib import Path
from shutil import which

from app import config
from app.db import get_db, value
from app.utils.filesystem import is_video
from app.utils.formatting import clean_title, format_bytes_display

# Cached video paths (timestamp, list_of_paths)
_paths = (0, [])


def probe_media(path):
    """Run ffprobe on path and return parsed json metadata."""
    # Test patch dynamic delegation
    if 'app' in sys.modules and hasattr(sys.modules['app'], 'probe_media'):
        app_mod = sys.modules['app']
        if app_mod.probe_media != probe_media:
            return app_mod.probe_media(path)

    probe = which('ffprobe')
    if not probe:
        return {}
    result = subprocess.run(
        [probe, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    try:
        return json.loads(result.stdout)
    except (json.JSONDecodeError, TypeError):
        return {}


def video_paths():
    """Discover all video files in MEDIA_ROOT with a 30-second in-memory cache and immediate change detection."""
    global _paths
    if 'app' in sys.modules and hasattr(sys.modules['app'], '_paths'):
        app_paths = sys.modules['app']._paths
        if app_paths != _paths:
            _paths = app_paths

    current = (
        sorted((p for p in config.MEDIA_ROOT.rglob('*') if is_video(p)), key=lambda p: str(getattr(p, 'name', p)).lower())
        if config.MEDIA_ROOT.exists()
        else []
    )
    if (
        time.monotonic() - _paths[0] > 30
        or len(current) != len(_paths[1])
        or {p.resolve() for p in current} != {p.resolve() for p in _paths[1]}
    ):
        if len(current) != len(_paths[1]) or {p.resolve() for p in current} != {p.resolve() for p in _paths[1]}:
            from app.services.scanner_service import trigger_library_scan
            trigger_library_scan()
        _paths = (time.monotonic(), current)
        if 'app' in sys.modules:
            sys.modules['app']._paths = _paths
    return _paths[1]


def poster_for(path, row):
    """Find local poster image file for a given video path or row."""
    db_poster = value(row, 'poster_path')
    if db_poster and not str(db_poster).startswith('tmdb:'):
        p = Path(db_poster)
        if p.exists():
            return f"local:{p.relative_to(config.MEDIA_ROOT).as_posix()}"
        return None
    for ext in config.POSTER_EXTENSIONS:
        p = path.with_suffix(ext)
        if p.is_file():
            return f"local:{p.relative_to(config.MEDIA_ROOT).as_posix()}"
    return None


def movie(path, db):
    """Build movie metadata dictionary for a video path combining database and filesystem data."""
    name = path.relative_to(config.MEDIA_ROOT).as_posix()
    meta = db.execute("SELECT * FROM movies WHERE filename=?", (name,)).fetchone()
    progress = db.execute("SELECT * FROM progress WHERE filename=?", (name,)).fetchone()
    pos = value(progress, 'position', 0)
    dur = value(progress, 'duration', 0)
    p = poster_for(path, meta) or (
        f"tmdb:{meta['tmdb_id']}"
        if meta and meta['tmdb_id'] and (config.POSTER_CACHE / f"{meta['tmdb_id']}.jpg").exists()
        else None
    )
    return dict(
        filename=name,
        path=path,
        title=value(meta, 'title', clean_title(path.name)),
        year=value(meta, 'year', ''),
        tmdb_id=value(meta, 'tmdb_id'),
        overview=value(meta, 'overview', ''),
        rating=value(meta, 'vote_average'),
        runtime=value(meta, 'runtime'),
        genres=value(meta, 'genres', ''),
        release_date=value(meta, 'release_date', ''),
        poster=p,
        position=pos,
        duration=dur,
        percent=min(100, pos / dur * 100) if dur else 0,
        updated_at=value(progress, 'updated_at', ''),
        backdrop_path=value(meta, 'backdrop_path', ''),
        details_json=value(meta, 'details_json', '')
    )


def get_movies():
    """Retrieve metadata dictionaries for all discovered video files in the library."""
    db = get_db()
    try:
        return [movie(p, db) for p in video_paths()]
    finally:
        db.close()


def extract_media_technical_specs(path, movie_meta=None):
    """Extract resolution, codecs, container, bitrate, and audio specs from media file."""
    from app.services.subtitles_service import tracks

    specs = {
        'resolution': '',
        'resolution_badge': '',
        'video_codec': '',
        'video_profile': '',
        'audio_codec': '',
        'audio_channels': '',
        'container': path.suffix[1:].upper() if path.suffix else '',
        'file_size': format_bytes_display(path.stat().st_size) if path.exists() else '',
        'bitrate': '',
        'subtitles': [],
        'aspect_ratio': ''
    }
    probe = probe_media(path)
    if not probe:
        return specs

    streams = probe.get('streams', [])
    fmt = probe.get('format', {})

    bit_rate = fmt.get('bit_rate')
    if bit_rate:
        try:
            br_num = int(bit_rate)
            if br_num >= 1_000_000:
                specs['bitrate'] = f"{br_num / 1_000_000:.1f} Mbps"
            else:
                specs['bitrate'] = f"{br_num // 1000} kbps"
        except (ValueError, TypeError):
            pass

    for s in streams:
        if s.get('codec_type') == 'video':
            codec = (s.get('codec_name') or '').lower()
            w = int(s.get('width') or 0)
            h = int(s.get('height') or 0)

            if w >= 3800 or h >= 2100:
                specs['resolution'] = '4K 2160p'
                specs['resolution_badge'] = '4K'
            elif w >= 1900 or h >= 1000:
                specs['resolution'] = '1080p'
                specs['resolution_badge'] = '1080p'
            elif w >= 1200 or h >= 700:
                specs['resolution'] = '720p'
                specs['resolution_badge'] = '720p'
            elif h >= 480:
                specs['resolution'] = '480p'
                specs['resolution_badge'] = 'SD'
            elif w and h:
                specs['resolution'] = f"{w}x{h}"
                specs['resolution_badge'] = 'SD'

            codec_map = {
                'hevc': 'HEVC (H.265)',
                'h264': 'H.264 (AVC)',
                'vp9': 'VP9',
                'av01': 'AV1',
                'av1': 'AV1',
                'mpeg4': 'MPEG-4',
                'vc1': 'VC-1'
            }
            specs['video_codec'] = codec_map.get(codec, codec.upper() if codec else 'Video')
            specs['aspect_ratio'] = s.get('display_aspect_ratio') or ''
            break

    for s in streams:
        if s.get('codec_type') == 'audio':
            acodec = (s.get('codec_name') or '').lower()
            channels = s.get('channels') or 0
            audio_map = {
                'eac3': 'Dolby Digital Plus',
                'ac3': 'Dolby Digital',
                'truehd': 'Dolby TrueHD',
                'dts': 'DTS',
                'dts-hd': 'DTS-HD',
                'aac': 'AAC',
                'flac': 'FLAC',
                'mp3': 'MP3',
                'opus': 'Opus',
                'vorbis': 'Vorbis'
            }
            specs['audio_codec'] = audio_map.get(acodec, acodec.upper() if acodec else 'Audio')
            chan_map = {1: '1.0 Mono', 2: '2.0 Stereo', 6: '5.1 Surround', 8: '7.1 Surround'}
            specs['audio_channels'] = chan_map.get(channels, f"{channels} ch" if channels else '')
            break

    try:
        sub_trks = tracks(path, movie_meta)
        specs['subtitles'] = [t['label'] for t in sub_trks]
    except Exception:
        specs['subtitles'] = []

    return specs
