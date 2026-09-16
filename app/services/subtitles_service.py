"""Subtitle extraction, online fetching, and track catalog service."""
import gzip
import hashlib
import json
import logging
import re
import subprocess
import sys
import threading
import urllib.parse
import urllib.request
from pathlib import Path
from flask import url_for

from app import config
from app.db import get_db
from app.services.media_service import movie, probe_media
from app.utils.filesystem import is_video
from app.utils.subtitles import compute_opensubtitles_hash, detect_subtitle_language, srt_to_vtt


def extract_embedded_subtitle(path, stream_idx):
    """Extract embedded subtitle track via ffmpeg and save as WebVTT in cache."""
    stamp = f"{path}:{path.stat().st_size}:{path.stat().st_mtime_ns}".encode()
    file_hash = hashlib.sha256(stamp).hexdigest()[:16]
    target = config.SUBTITLE_EMBEDDED_CACHE / f"{file_hash}_{stream_idx}.vtt"
    if target.is_file() and target.stat().st_size > 0:
        return target

    lock_key = f"embed:{path}:{stream_idx}"
    lock = config.SUBTITLE_LOCKS.setdefault(lock_key, threading.Lock())
    with lock:
        if target.is_file() and target.stat().st_size > 0:
            return target
        config.SUBTITLE_EMBEDDED_CACHE.mkdir(parents=True, exist_ok=True)
        temp_target = target.with_suffix('.part.vtt')
        try:
            cmd = [
                'ffmpeg', '-y', '-i', str(path),
                '-map', f'0:{stream_idx}',
                '-c:s', 'webvtt',
                '-f', 'webvtt', str(temp_target)
            ]
            res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, timeout=60)
            if res.returncode == 0 and temp_target.is_file() and temp_target.stat().st_size > 0:
                content = temp_target.read_text(encoding='utf-8', errors='replace')
                temp_target.write_text(srt_to_vtt(content), encoding='utf-8')
                temp_target.replace(target)
                return target
        except Exception as e:
            logging.warning(f"Failed to extract embedded subtitle {stream_idx} from {path}: {e}")
        finally:
            if temp_target.exists():
                try:
                    temp_target.unlink()
                except Exception:
                    pass
    return target if target.is_file() else None


def fetch_online_subtitle(path, movie_meta=None):
    """Fetch online subtitle from OpenSubtitles via hash, IMDb ID, or movie title."""
    # Test patch dynamic delegation
    if 'app' in sys.modules and hasattr(sys.modules['app'], 'fetch_online_subtitle'):
        app_mod = sys.modules['app']
        if app_mod.fetch_online_subtitle != fetch_online_subtitle:
            return app_mod.fetch_online_subtitle(path, movie_meta)

    stamp = f"{path}:{path.stat().st_size}".encode()
    file_hash = hashlib.sha256(stamp).hexdigest()[:16]
    target = config.SUBTITLE_ONLINE_CACHE / f"{file_hash}.vtt"
    if target.is_file() and target.stat().st_size > 0:
        return target

    lock_key = f"online:{file_hash}"
    lock = config.SUBTITLE_LOCKS.setdefault(lock_key, threading.Lock())
    with lock:
        if target.is_file() and target.stat().st_size > 0:
            return target
        config.SUBTITLE_ONLINE_CACHE.mkdir(parents=True, exist_ok=True)

        headers = {'User-Agent': 'TemporaryUserAgent'}
        download_url = None

        # 1. MovieHash search
        h, sz = compute_opensubtitles_hash(path)
        if h and sz:
            try:
                url = f"https://rest.opensubtitles.org/search/moviebytesize-{sz}/moviehash-{h}/sublanguageid-eng"
                req = urllib.request.Request(url, headers=headers)
                with urllib.request.urlopen(req, timeout=5) as resp:
                    if resp.status == 200:
                        data = json.loads(resp.read().decode('utf-8'))
                        if data and isinstance(data, list):
                            for item in data:
                                if item.get('SubDownloadLink'):
                                    download_url = item['SubDownloadLink']
                                    break
            except Exception as e:
                logging.debug(f"OpenSubtitles hash search error: {e}")

        # 2. IMDb ID search
        if not download_url and movie_meta:
            imdb_id = movie_meta.get('imdb_id')
            if not imdb_id and movie_meta.get('tmdb_id'):
                try:
                    from app.services.tmdb_service import get_movie_details, load_token
                    token = load_token()
                    if token:
                        details = get_movie_details(None, token, movie_meta['tmdb_id'])
                        if details and details.get('imdb_id'):
                            imdb_id = details['imdb_id']
                except Exception:
                    pass
            if imdb_id:
                try:
                    clean_id = imdb_id.lstrip('t')
                    url = f"https://rest.opensubtitles.org/search/imdbid-{clean_id}/sublanguageid-eng"
                    req = urllib.request.Request(url, headers=headers)
                    with urllib.request.urlopen(req, timeout=5) as resp:
                        if resp.status == 200:
                            data = json.loads(resp.read().decode('utf-8'))
                            if data and isinstance(data, list):
                                for item in data:
                                    if item.get('SubDownloadLink'):
                                        download_url = item['SubDownloadLink']
                                        break
                except Exception as e:
                    logging.debug(f"OpenSubtitles IMDb search error: {e}")

        # 3. Title query search
        if not download_url:
            title = movie_meta.get('title') if movie_meta else path.stem
            clean_t = re.sub(r'[^a-zA-Z0-9 ]', ' ', title).strip().lower()
            if clean_t:
                try:
                    q = urllib.parse.quote(clean_t)
                    url = f"https://rest.opensubtitles.org/search/query-{q}/sublanguageid-eng"
                    req = urllib.request.Request(url, headers=headers)
                    with urllib.request.urlopen(req, timeout=5) as resp:
                        if resp.status == 200:
                            data = json.loads(resp.read().decode('utf-8'))
                            if data and isinstance(data, list):
                                for item in data:
                                    if item.get('SubDownloadLink'):
                                        download_url = item['SubDownloadLink']
                                        break
                except Exception as e:
                    logging.debug(f"OpenSubtitles query search error: {e}")

        if download_url:
            try:
                req = urllib.request.Request(download_url, headers=headers)
                with urllib.request.urlopen(req, timeout=10) as resp:
                    raw = resp.read()
                    try:
                        decompressed = gzip.decompress(raw).decode('utf-8', errors='replace')
                    except Exception:
                        decompressed = raw.decode('utf-8', errors='replace')
                    vtt = srt_to_vtt(decompressed)
                    temp_target = target.with_suffix('.part.vtt')
                    temp_target.write_text(vtt, encoding='utf-8')
                    temp_target.replace(target)
                    return target
            except Exception as e:
                logging.warning(f"Failed downloading subtitle from {download_url}: {e}")

    return target if target.is_file() else None


def tracks(path, movie_meta=None):
    """Catalog local directory subtitles, embedded tracks, and online fallbacks for a media file."""
    result = []
    found_english = False
    try:
        rel_filename = path.relative_to(config.MEDIA_ROOT).as_posix()
    except Exception:
        rel_filename = path.name

    if movie_meta is None:
        try:
            db = get_db()
            movie_meta = movie(path, db)
            db.close()
        except Exception:
            pass

    # 1. Directory subtitles
    if path.parent.exists():
        from app.utils.subtitles import get_short_movie_name
        short_name = get_short_movie_name(path)
        for sub in sorted(path.parent.iterdir()):
            if sub.is_file() and sub.suffix.lower() in config.SUBTITLE_EXTENSIONS:
                is_short_match = bool(short_name and sub.stem.lower().startswith(f"{short_name}_"))
                is_match = (
                    sub.stem == path.stem
                    or sub.stem.startswith(path.stem + '.')
                    or is_short_match
                    or len(list(p for p in path.parent.iterdir() if is_video(p))) == 1
                )
                if is_match:
                    code = ''
                    if sub.stem.startswith(path.stem):
                        code = sub.stem[len(path.stem):].strip('.').split('.')[0].lower()
                    elif is_short_match:
                        parts = sub.stem.lower().split('_')
                        if len(parts) >= 3:
                            code = parts[-2]
                    lang_names = {
                        'en': 'English', 'hi': 'Hindi', 'es': 'Spanish', 'fr': 'French',
                        'de': 'German', 'it': 'Italian', 'pt': 'Portuguese', 'ru': 'Russian',
                        'ja': 'Japanese', 'zh': 'Chinese', 'ko': 'Korean', 'ar': 'Arabic', 'bn': 'Bengali'
                    }
                    is_eng = ('eng' in sub.stem.lower() or 'english' in sub.stem.lower() or code in {'en', 'eng'})
                    detected_lang = 'en' if is_eng else (code or 'und')
                    if detected_lang == 'und':
                        detected_lang = detect_subtitle_language(sub)
                    if detected_lang in {'en', 'eng'}:
                        detected_lang = 'en'
                        found_english = True
                    label = lang_names.get(detected_lang, detected_lang.upper() if detected_lang != 'und' else 'Subtitles')
                    try:
                        src = url_for('subtitles.subtitle', filename=rel_filename, name=sub.name)
                    except Exception:
                        try:
                            src = url_for('subtitle', filename=rel_filename, name=sub.name)
                        except Exception:
                            src = f"/subtitles/{rel_filename}/{sub.name}"
                    result.append(dict(
                        id=f"dir:{sub.name}",
                        name=sub.name,
                        src=src,
                        lang=detected_lang,
                        label=f"{label} (Local)",
                        default=False
                    ))

    # 2. Embedded subtitle tracks
    try:
        streams = probe_media(path).get('streams', [])
        sub_streams = [s for s in streams if s.get('codec_type') == 'subtitle']
        supported_codecs = {'subrip', 'webvtt', 'mov_text', 'ass', 'ssa', 'text'}
        lang_map = {
            'eng': 'English', 'en': 'English', 'hin': 'Hindi', 'hi': 'Hindi',
            'spa': 'Spanish', 'es': 'Spanish', 'fre': 'French', 'fra': 'French', 'fr': 'French',
            'ger': 'German', 'deu': 'German', 'de': 'German', 'ita': 'Italian', 'it': 'Italian',
            'jpn': 'Japanese', 'ja': 'Japanese', 'kor': 'Korean', 'ko': 'Korean',
            'chi': 'Chinese', 'zho': 'Chinese', 'zh': 'Chinese', 'rus': 'Russian', 'ru': 'Russian',
            'ind': 'Indonesian', 'id': 'Indonesian', 'por': 'Portuguese', 'pt': 'Portuguese'
        }
        for s in sub_streams:
            codec = s.get('codec_name', '').lower()
            if codec not in supported_codecs:
                continue
            idx = s.get('index')
            tags = s.get('tags', {}) or {}
            raw_lang = tags.get('language', 'und').lower()
            title = tags.get('title', '').strip()
            is_eng = (
                raw_lang in {'eng', 'en'}
                or 'english' in title.lower()
                or (raw_lang == 'und' and not found_english and len(sub_streams) == 1)
            )
            if is_eng:
                found_english = True
            lang_code = 'en' if is_eng else (raw_lang if raw_lang != 'und' else 'und')
            lang_label = lang_map.get(raw_lang, raw_lang.upper() if raw_lang != 'und' else 'Subtitles')
            full_label = f"{lang_label}" + (f" - {title}" if title and title.lower() != lang_label.lower() else "") + " (Embedded)"
            try:
                src = url_for('subtitles.subtitle_embedded', filename=rel_filename, stream_idx=idx)
            except Exception:
                try:
                    src = url_for('subtitle_embedded', filename=rel_filename, stream_idx=idx)
                except Exception:
                    src = f"/subtitles/embedded/{rel_filename}/{idx}.vtt"
            result.append(dict(
                id=f"embed:{idx}",
                name=f"embedded_{idx}.vtt",
                src=src,
                lang=lang_code,
                label=full_label,
                default=False
            ))
    except Exception as e:
        logging.warning(f"Failed probing embedded subtitles for {path}: {e}")

    # 3. Online provider fallback
    if not found_english:
        try:
            online_target = fetch_online_subtitle(path, movie_meta)
            if online_target and online_target.is_file():
                found_english = True
                try:
                    src = url_for('subtitles.subtitle_online', filename=rel_filename)
                except Exception:
                    try:
                        src = url_for('subtitle_online', filename=rel_filename)
                    except Exception:
                        src = f"/subtitles/online/{rel_filename}.vtt"
                result.append(dict(
                    id="online:en",
                    name="online_en.vtt",
                    src=src,
                    lang='en',
                    label='English (OpenSubtitles)',
                    default=False
                ))
        except Exception as e:
            logging.warning(f"Online subtitle fetch failed for {path}: {e}")

    # Default to first English track
    for t in result:
        lang = (t.get('lang') or '').lower()
        label = (t.get('label') or '').lower()
        if lang in {'en', 'eng'} or 'english' in label:
            t['default'] = True
            break

    return result


def purge_subtitles_for_media(path):
    """Purge cached embedded and online WebVTT files, and sidecar subtitles for the media path."""
    path = Path(path)
    purged = []

    # 1. Embedded subtitles cache
    try:
        if path.exists():
            stamp = f"{path}:{path.stat().st_size}:{path.stat().st_mtime_ns}".encode()
            file_hash = hashlib.sha256(stamp).hexdigest()[:16]
            if config.SUBTITLE_EMBEDDED_CACHE.is_dir():
                for vtt in config.SUBTITLE_EMBEDDED_CACHE.glob(f"{file_hash}_*.vtt"):
                    try:
                        vtt.unlink(missing_ok=True)
                        purged.append(str(vtt))
                    except Exception:
                        pass
    except Exception:
        pass

    # 2. Online subtitles cache
    try:
        if path.exists():
            stamp_online = f"{path}:{path.stat().st_size}".encode()
            online_hash = hashlib.sha256(stamp_online).hexdigest()[:16]
            online_file = config.SUBTITLE_ONLINE_CACHE / f"{online_hash}.vtt"
            if online_file.is_file():
                online_file.unlink(missing_ok=True)
                purged.append(str(online_file))
    except Exception:
        pass

    # 3. Sidecar subtitles alongside movie file (e.g. .srt or .vtt matching stem)
    try:
        if path.parent.is_dir():
            stem = path.stem
            for ext in ('.srt', '.vtt'):
                for sidecar in path.parent.glob(f"{stem}*{ext}"):
                    try:
                        sidecar.unlink(missing_ok=True)
                        purged.append(str(sidecar))
                    except Exception:
                        pass
    except Exception:
        pass

    return purged


