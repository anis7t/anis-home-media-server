"""LAN-first Flask media server."""
import hashlib, json, logging, mimetypes, os, re, sqlite3, struct, subprocess, threading, time, urllib.parse, gzip
from functools import lru_cache
from pathlib import Path
from shutil import which
from flask import Flask, Response, abort, jsonify, render_template_string, request, send_file, url_for
from markupsafe import escape

BASE_DIR = Path(os.environ.get("MEDIA_SERVER_BASE_DIR", Path(__file__).parent)).resolve()
MEDIA_ROOT = Path(os.environ.get("MEDIA_SERVER_MEDIA_ROOT", "/home/iamroot/Media/Movies")).resolve()
DATABASE = Path(os.environ.get("MEDIA_SERVER_DATABASE", BASE_DIR / "media.db"))
CACHE_DIR, POSTER_CACHE, BACKDROP_CACHE, SUBTITLE_CACHE = BASE_DIR / "cache", BASE_DIR / "cache/posters", BASE_DIR / "cache/backdrops", BASE_DIR / "cache/subtitles"
SUBTITLE_EMBEDDED_CACHE = SUBTITLE_CACHE / "embedded"
SUBTITLE_ONLINE_CACHE = SUBTITLE_CACHE / "online"
SUBTITLE_LOCKS = {}
VIDEO_EXTENSIONS = {".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v"}; SUBTITLE_EXTENSIONS = {".srt", ".vtt"}; POSTER_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}
app = Flask(__name__); logging.basicConfig(level=os.environ.get("MEDIA_SERVER_LOG_LEVEL", "INFO"))
TRANSCODE_LOCKS = {}
HLS_PROCESSES = {}
PRECACHE_INTERVAL = 30
CACHE_MAX_BYTES = 10 * 1024 * 1024 * 1024  # 10 GB cap on transcode cache

def is_vaapi_enabled():
    if os.environ.get("MEDIA_SERVER_ENABLE_VAAPI", "0").lower() in {"1", "true", "yes"}:
        dev = os.environ.get("MEDIA_SERVER_VAAPI_DEVICE", "/dev/dri/renderD128")
        return Path(dev).exists() and os.access(dev, os.R_OK | os.W_OK)
    return False

def transcode_cache_path(path, mode='direct'):
    stamp = f'{path}:{path.stat().st_size}:{path.stat().st_mtime_ns}'.encode()
    key = stamp if mode == 'direct' else (mode + ':').encode() + stamp
    return CACHE_DIR / 'transcodes' / f'{hashlib.sha256(key).hexdigest()}.mp4'

def compat_transcode_args(vaapi_available=False):
    preset = os.environ.get("MEDIA_SERVER_TRANSCODE_PRESET", "superfast")
    crf = os.environ.get("MEDIA_SERVER_TRANSCODE_CRF", "23")
    if vaapi_available:
        return ['-vf', 'format=nv12,hwupload,scale_vaapi=w=1920:h=-2', '-c:v', 'h264_vaapi', '-qp', '24', '-pix_fmt', 'nv12']
    return ['-vf', 'scale=-2:1080,format=yuv420p', '-c:v', 'libx264', '-preset', preset, '-crf', crf, '-pix_fmt', 'yuv420p']

def hls_transcode_args(vaapi_available=False):
    preset = os.environ.get("MEDIA_SERVER_TRANSCODE_PRESET", "superfast")
    crf = os.environ.get("MEDIA_SERVER_TRANSCODE_CRF", "23")
    if vaapi_available:
        return ['-vf', 'format=nv12,hwupload,scale_vaapi=w=1920:h=-2', '-c:v', 'h264_vaapi', '-qp', '24', '-pix_fmt', 'nv12']
    return ['-vf', 'scale=-2:1080,format=yuv420p', '-c:v', 'libx264', '-preset', preset, '-crf', crf, '-pix_fmt', 'yuv420p', '-profile:v', 'high', '-level', '4.1']

def needs_transcode(path):
    return path.suffix.lower() not in {'.mp4', '.m4v', '.webm'}

def transcode_progress_path(path, mode='direct'):
    return transcode_cache_path(path, mode).with_suffix('.progress')

def hls_cache_dir(path):
    key = hashlib.sha256(f'hls:{path}:{path.stat().st_size}:{path.stat().st_mtime_ns}'.encode()).hexdigest()
    return CACHE_DIR / 'hls' / key

def cleanup_cache():
    """Remove orphaned .part.mp4 files and enforce size cap on transcode cache."""
    transcode_dir = CACHE_DIR / 'transcodes'
    if not transcode_dir.is_dir():
        return
    part_files = list(transcode_dir.glob('*.part.mp4'))
    total = sum(p.stat().st_size for p in transcode_dir.iterdir() if p.is_file())
    for p in part_files:
        final = p.with_name(p.name[:-len('.part.mp4')] + '.mp4')
        age = time.time() - p.stat().st_mtime
        if age > 3600 or not final.is_file():
            p.unlink(missing_ok=True)
            continue
    for prg in transcode_dir.glob('*.progress'):
        final = prg.with_suffix('.mp4')
        part = prg.with_name(prg.stem + '.part.mp4')
        if not final.is_file() and not part.is_file():
            prg.unlink(missing_ok=True)
    mp4_files = sorted(
        [p for p in transcode_dir.glob('*.mp4') if p.is_file()],
        key=lambda p: p.stat().st_mtime
    )
    while total > CACHE_MAX_BYTES and mp4_files:
        oldest = mp4_files.pop(0)
        total -= oldest.stat().st_size
        oldest.unlink()

def cleanup_cache_on_startup():
    """Clean orphaned part files and enforce cache size cap on server start."""
    cleanup_cache()

def probe_media(path):
    probe = which('ffprobe')
    if not probe: return {}
    result = subprocess.run([probe, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)], capture_output=True, text=True, check=False)
    try: return json.loads(result.stdout)
    except (json.JSONDecodeError, TypeError): return {}

def get_db():
    DATABASE.parent.mkdir(parents=True, exist_ok=True); db=sqlite3.connect(DATABASE); db.row_factory=sqlite3.Row; return db
def init_db():
    db=get_db(); db.execute("CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY)")
    db.execute("CREATE TABLE IF NOT EXISTS progress(filename TEXT PRIMARY KEY,position REAL NOT NULL DEFAULT 0,duration REAL NOT NULL DEFAULT 0,updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)")
    db.execute("CREATE TABLE IF NOT EXISTS movies(filename TEXT PRIMARY KEY,title TEXT,year INTEGER,tmdb_id INTEGER,overview TEXT,poster_path TEXT,backdrop_path TEXT,runtime INTEGER,genres TEXT,vote_average REAL,updated_at INTEGER)")
    columns={r['name'] for r in db.execute("PRAGMA table_info(movies)")}
    for name, spec in (("release_date","TEXT"),("added_at","INTEGER")):
        if name not in columns: db.execute(f"ALTER TABLE movies ADD COLUMN {name} {spec}")
    db.execute("CREATE INDEX IF NOT EXISTS idx_progress_updated ON progress(updated_at DESC)"); db.execute("INSERT OR IGNORE INTO schema_migrations VALUES(1)"); db.commit(); db.close()
def safe_path(name):
    if not name or "\0" in name: abort(404)
    name = urllib.parse.unquote(name)
    if "\0" in name: abort(404)
    path=(MEDIA_ROOT/name).resolve()
    try: path.relative_to(MEDIA_ROOT)
    except ValueError: abort(403)
    return path
def is_video(path): return path.is_file() and path.suffix.lower() in VIDEO_EXTENSIONS
def value(row,key,default=None): return default if row is None or key not in row.keys() or row[key] is None else row[key]
def clean_title(name):
    title=re.sub(r'^(?:Copy\s+of\s+)+','',Path(name).stem,flags=re.I)
    title=re.sub(r'\s*\(\d+\)$','',title)
    title=re.sub(r'^[【\[].*?[】\]]\s*','',title)
    title=re.sub(r'[._]+',' ',title)
    return re.sub(r'\s+',' ',re.sub(r'\b(2160p|1080p|720p|480p|4K|BluRay|WEBRip|WEB-DL|WEB|HDR|REMUX|x264|x265|HEVC)\b','',title,flags=re.I)).strip()
def poster_for(path,row):
    tmdb_id=value(row,'tmdb_id')
    if tmdb_id and ((POSTER_CACHE/f'{tmdb_id}.jpg').is_file() or value(row,'poster_path')): return f'tmdb:{tmdb_id}'
    for p in [path.with_suffix(ext) for ext in POSTER_EXTENSIONS]+[path.parent/f'poster{ext}' for ext in POSTER_EXTENSIONS]:
        if p.is_file(): return 'local:'+p.relative_to(MEDIA_ROOT).as_posix()
    return None
_paths=(0,[])
def video_paths():
    global _paths
    current = sorted((p for p in MEDIA_ROOT.rglob('*') if is_video(p)), key=lambda p: p.name.lower()) if MEDIA_ROOT.exists() else []
    if time.monotonic() - _paths[0] > 30 or len(current) != len(_paths[1]) or {p.resolve() for p in current} != {p.resolve() for p in _paths[1]}:
        if len(current) != len(_paths[1]) or {p.resolve() for p in current} != {p.resolve() for p in _paths[1]}:
            trigger_library_scan()
        _paths = (time.monotonic(), current)
    return _paths[1]
def movie(path,db):
    name=path.relative_to(MEDIA_ROOT).as_posix(); meta=db.execute('SELECT * FROM movies WHERE filename=?',(name,)).fetchone(); progress=db.execute('SELECT * FROM progress WHERE filename=?',(name,)).fetchone(); pos,dur=value(progress,'position',0),value(progress,'duration',0)
    return dict(filename=name,title=value(meta,'title',clean_title(path.name)),year=value(meta,'year',''),tmdb_id=value(meta,'tmdb_id'),overview=value(meta,'overview',''),rating=value(meta,'vote_average'),runtime=value(meta,'runtime'),genres=value(meta,'genres',''),release_date=value(meta,'release_date',''),poster=poster_for(path,meta),position=pos,duration=dur,percent=min(100,pos/dur*100) if dur else 0,updated_at=value(progress,'updated_at',''))
def get_movies():
    db=get_db()
    try: return [movie(p,db) for p in video_paths()]
    finally: db.close()
def mimetype(path): return mimetypes.guess_type(path.name)[0] or {'.mkv':'video/x-matroska','.m4v':'video/mp4'}.get(path.suffix.lower(),'application/octet-stream')
def parse_range(header,size):
    m=re.fullmatch(r'bytes=(\d*)-(\d*)',header.strip()) if header else None
    if not m:return None
    a,b=m.groups()
    if not a and not b:return 'bad'
    if a: start,end=int(a),int(b) if b else size-1
    else: end=size-1;start=max(0,size-int(b))
    return 'bad' if start>=size or start>end else (start,min(end,size-1))
def compute_opensubtitles_hash(path):
    try:
        longlongformat = '<q'
        bytesize = struct.calcsize(longlongformat)
        filesize = path.stat().st_size
        if filesize < 65536 * 2:
            return None, filesize
        hash_val = filesize
        with path.open('rb') as f:
            for _ in range(65536 // bytesize):
                buffer = f.read(bytesize)
                (l_value,) = struct.unpack(longlongformat, buffer)
                hash_val = (hash_val + l_value) & 0xFFFFFFFFFFFFFFFF
            f.seek(max(0, filesize - 65536), 0)
            for _ in range(65536 // bytesize):
                buffer = f.read(bytesize)
                (l_value,) = struct.unpack(longlongformat, buffer)
                hash_val = (hash_val + l_value) & 0xFFFFFFFFFFFFFFFF
        return f"{hash_val:016x}", filesize
    except Exception:
        return None, 0

def srt_to_vtt(text):
    if not text:
        return "WEBVTT\n\n"
    text = text.lstrip('\ufeff')
    vtt = re.sub(r'(\d\d:\d\d:\d\d),(\d{3})', r'\1.\2', text)
    vtt = re.sub(r'(\d\d:\d\d:\d\d),', r'\1.', vtt)
    vtt = re.sub(r'((?:\d\d:)?\d\d:\d\d\.\d{3}\s*-->\s*(?:\d\d:)?\d\d:\d\d\.\d{3})(?!.*line:)', r'\1 line:-3.5', vtt)
    if not vtt.strip().startswith("WEBVTT"):
        vtt = "WEBVTT\n\n" + vtt.lstrip()
    return vtt

def extract_embedded_subtitle(path, stream_idx):
    stamp = f"{path}:{path.stat().st_size}:{path.stat().st_mtime_ns}".encode()
    file_hash = hashlib.sha256(stamp).hexdigest()[:16]
    target = SUBTITLE_EMBEDDED_CACHE / f"{file_hash}_{stream_idx}.vtt"
    if target.is_file() and target.stat().st_size > 0:
        return target

    lock_key = f"embed:{path}:{stream_idx}"
    lock = SUBTITLE_LOCKS.setdefault(lock_key, threading.Lock())
    with lock:
        if target.is_file() and target.stat().st_size > 0:
            return target
        SUBTITLE_EMBEDDED_CACHE.mkdir(parents=True, exist_ok=True)
        temp_target = target.with_suffix('.part.vtt')
        try:
            cmd = ['ffmpeg', '-y', '-i', str(path), '-map', f'0:{stream_idx}', '-c:s', 'webvtt', '-f', 'webvtt', str(temp_target)]
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
                try: temp_target.unlink()
                except Exception: pass
    return target if target.is_file() else None

def fetch_online_subtitle(path, movie_meta=None):
    stamp = f"{path}:{path.stat().st_size}".encode()
    file_hash = hashlib.sha256(stamp).hexdigest()[:16]
    target = SUBTITLE_ONLINE_CACHE / f"{file_hash}.vtt"
    if target.is_file() and target.stat().st_size > 0:
        return target

    lock_key = f"online:{file_hash}"
    lock = SUBTITLE_LOCKS.setdefault(lock_key, threading.Lock())
    with lock:
        if target.is_file() and target.stat().st_size > 0:
            return target
        SUBTITLE_ONLINE_CACHE.mkdir(parents=True, exist_ok=True)
        import urllib.request

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
                    from scanner import load_token, get_movie_details
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
            clean_title = re.sub(r'[^a-zA-Z0-9 ]', ' ', title).strip().lower()
            if clean_title:
                try:
                    q = urllib.parse.quote(clean_title)
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
    result = []
    found_english = False
    try:
        rel_filename = path.relative_to(MEDIA_ROOT).as_posix()
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
        for sub in sorted(path.parent.iterdir()):
            if sub.is_file() and sub.suffix.lower() in SUBTITLE_EXTENSIONS:
                is_match = (sub.stem == path.stem or sub.stem.startswith(path.stem + '.') or
                            len(list(p for p in path.parent.iterdir() if is_video(p))) == 1)
                if is_match:
                    code = sub.stem[len(path.stem):].strip('.').split('.')[0].lower() if sub.stem.startswith(path.stem) else ''
                    lang_names = {'en': 'English', 'hi': 'Hindi', 'es': 'Spanish', 'fr': 'French', 'de': 'German'}
                    is_eng = ('eng' in sub.stem.lower() or 'english' in sub.stem.lower() or code in {'en', 'eng'})
                    detected_lang = 'en' if is_eng else (code or 'und')
                    if detected_lang == 'en':
                        found_english = True
                    label = lang_names.get(detected_lang, detected_lang.upper() if detected_lang != 'und' else 'Subtitles')
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
            is_eng = raw_lang in {'eng', 'en'} or 'english' in title.lower() or (raw_lang == 'und' and not found_english and len(sub_streams) == 1)
            if is_eng:
                found_english = True
            lang_code = 'en' if is_eng else (raw_lang if raw_lang != 'und' else 'und')
            lang_label = lang_map.get(raw_lang, raw_lang.upper() if raw_lang != 'und' else 'Subtitles')
            full_label = f"{lang_label}" + (f" - {title}" if title and title.lower() != lang_label.lower() else "") + " (Embedded)"
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
        if t['lang'] == 'en':
            t['default'] = True
            break

    return result

@app.route('/')
def home():
    q=request.args.get('q','').strip().lower(); sort=request.args.get('sort','title'); movies=get_movies()
    if q: movies=[m for m in movies if q in (m['title']+' '+str(m['year'])+' '+m['genres']).lower()]
    movies.sort(key=(lambda m:m['updated_at'] or '') if sort=='recent' else lambda m:m['title'].lower(),reverse=sort=='recent')
    watching=sorted([m for m in movies if m['position']>10 and (not m['duration'] or m['position']<m['duration']-10)],key=lambda m:m['updated_at'] or '',reverse=True)
    return render_template_string(LIBRARY_HTML,movies=movies,watching=watching,q=q,sort=sort)
@app.route('/movie/<path:filename>')
def details(filename):
    path=safe_path(filename)
    if not is_video(path):abort(404)
    db=get_db(); m=movie(path,db);db.close(); backdrop=m['tmdb_id'] if m['tmdb_id'] and (BACKDROP_CACHE/f"{m['tmdb_id']}.jpg").is_file() else None
    return render_template_string(DETAILS_HTML,movie=m,backdrop=backdrop)
@app.route('/watch/<path:filename>')
def watch(filename):
    path=safe_path(filename)
    if not is_video(path):abort(404)
    db=get_db();m=movie(path,db);db.close()
    return render_template_string(PLAYER_HTML,movie=m,tracks=tracks(path,m))
@app.route('/media/<path:filename>')
def media(filename):
    path=safe_path(filename)
    if not is_video(path):abort(404)
    size=path.stat().st_size; ran=parse_range(request.headers.get('Range'),size); headers={'Accept-Ranges':'bytes','Content-Type':mimetype(path),'Cache-Control':'private, max-age=3600'}
    if ran=='bad':return Response(status=416,headers={**headers,'Content-Range':f'bytes */{size}'})
    if ran:
        start,end=ran; length=end-start+1
        def stream():
            with path.open('rb') as f:
                f.seek(start); left=length
                while left:
                    data=f.read(min(left,1024*1024))
                    if not data:break
                    left-=len(data);yield data
        return Response(stream(),206,{**headers,'Content-Length':str(length),'Content-Range':f'bytes {start}-{end}/{size}'})
    return send_file(path,mimetype=mimetype(path),conditional=True,etag=True,max_age=3600)
@app.route('/poster/<path:filename>')
def poster(filename):
    path=safe_path(filename)
    if not path.is_file() or path.suffix.lower() not in POSTER_EXTENSIONS:abort(404)
    return send_file(path,conditional=True,max_age=86400)
def cached(path):
    if not path.is_file():abort(404)
    return send_file(path,conditional=True,max_age=86400)
@app.route('/tmdb-poster/<int:tmdb_id>')
def tmdb_poster(tmdb_id):
    target = POSTER_CACHE/f'{tmdb_id}.jpg'
    if not target.is_file():
        db = get_db()
        row = db.execute('SELECT poster_path FROM movies WHERE tmdb_id=?', (tmdb_id,)).fetchone()
        db.close()
        if row and value(row, 'poster_path'):
            try:
                from posters import download_poster
                download_poster(tmdb_id, row['poster_path'])
            except Exception: pass
    return cached(target)
@app.route('/tmdb-backdrop/<int:tmdb_id>')
def tmdb_backdrop(tmdb_id):
    target = BACKDROP_CACHE/f'{tmdb_id}.jpg'
    if not target.is_file():
        db = get_db()
        row = db.execute('SELECT backdrop_path FROM movies WHERE tmdb_id=?', (tmdb_id,)).fetchone()
        db.close()
        if row and value(row, 'backdrop_path'):
            try:
                from posters import download_poster
                download_poster(tmdb_id, row['backdrop_path'], backdrop=True)
            except Exception: pass
    return cached(target)
@app.route('/subtitles/<path:filename>/<path:name>')
def subtitle(filename,name):
    video=safe_path(filename); sub=(video.parent/name).resolve()
    if not is_video(video) or sub.parent!=video.parent or not sub.is_file() or sub.suffix.lower() not in SUBTITLE_EXTENSIONS:abort(404)
    text=sub.read_text(encoding='utf-8-sig',errors='replace')
    return Response(srt_to_vtt(text),mimetype='text/vtt',headers={'Cache-Control':'private, max-age=3600'})

@app.route('/subtitles/embedded/<path:filename>/<int:stream_idx>.vtt')
def subtitle_embedded(filename, stream_idx):
    video = safe_path(filename)
    if not is_video(video): abort(404)
    vtt = extract_embedded_subtitle(video, stream_idx)
    if not vtt or not vtt.is_file(): abort(404)
    return send_file(vtt, mimetype='text/vtt', conditional=True, max_age=3600)

@app.route('/subtitles/online/<path:filename>.vtt')
def subtitle_online(filename):
    video = safe_path(filename)
    if not is_video(video): abort(404)
    db = get_db(); m = movie(video, db); db.close()
    vtt = fetch_online_subtitle(video, m)
    if not vtt or not vtt.is_file(): abort(404)
    return send_file(vtt, mimetype='text/vtt', conditional=True, max_age=3600)

@app.route('/api/subtitles/<path:filename>')
def api_subtitles(filename):
    video = safe_path(filename)
    if not is_video(video): abort(404)
    db = get_db(); m = movie(video, db); db.close()
    return jsonify(tracks=tracks(video, m))
@app.route('/transcode/<path:filename>')
def transcode(filename):
    """Create and serve a browser-safe MP4 with normal range support."""
    path = safe_path(filename)
    if not is_video(path):
        abort(404)
    if not which('ffmpeg'):
        return jsonify(error='FFmpeg is not installed; this file cannot be converted.'), 503

    mode = 'compat' if request.args.get('compat') == '1' else 'direct'
    cached = transcode_cache_path(path, mode)
    progress_path = transcode_progress_path(path, mode)
    if cached.is_file() and cached.stat().st_size:
        return send_file(cached, mimetype='video/mp4', conditional=True, max_age=3600)

    lock_key = f'{filename}:{mode}'
    lock = TRANSCODE_LOCKS.setdefault(lock_key, threading.Lock())
    lock.acquire()
    temporary = cached.with_name(cached.stem + '.part.mp4')
    try:
        cached.parent.mkdir(parents=True, exist_ok=True)
        streams = probe_media(path).get('streams', [])
        video = next((s for s in streams if s.get('codec_type') == 'video'), {})
        audio = next((s for s in streams if s.get('codec_type') == 'audio'), {})
        input_args = []
        vaapi = is_vaapi_enabled()
        if mode == 'compat':
            dev = os.environ.get("MEDIA_SERVER_VAAPI_DEVICE", "/dev/dri/renderD128")
            input_args = ['-vaapi_device', dev, '-hwaccel', 'vaapi', '-hwaccel_device', dev] if vaapi else []
            video_args = compat_transcode_args(vaapi)
        elif video.get('codec_name') in {'h264', 'hevc'}:
            video_args = ['-c:v', 'copy']
            if video.get('codec_name') == 'hevc': video_args += ['-tag:v', 'hvc1']
        else:
            video_args = compat_transcode_args(False)
        audio_args = ['-c:a', 'copy'] if audio.get('codec_name') == 'aac' else ['-c:a', 'aac']
        subprocess.run(
            ['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error'] + input_args + ['-i', str(path),
             '-map', '0:v:0', '-map', '0:a?'] + video_args + audio_args +
            ['-movflags', '+frag_keyframe+empty_moov+default_base_moof', '-progress', str(progress_path), '-nostats', str(temporary)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True,
        )
        temporary.replace(cached)
    except (OSError, subprocess.CalledProcessError):
        progress_path.unlink(missing_ok=True)
        return jsonify(error='The media conversion failed.'), 500
    finally:
        lock.release()
        progress_path.unlink(missing_ok=True)
    return send_file(cached, mimetype='video/mp4', conditional=True, max_age=3600)

@app.route('/hls/<path:filename>/playlist.m3u8')
def hls_playlist(filename):
    path = safe_path(filename)
    if not is_video(path): abort(404)
    directory = hls_cache_dir(path); playlist = directory / 'playlist.m3u8'
    lock = TRANSCODE_LOCKS.setdefault('hls:' + filename, threading.Lock())
    is_complete = playlist.is_file() and '#EXT-X-ENDLIST' in playlist.read_text(errors='replace')
    proc = HLS_PROCESSES.get(filename)
    is_running = proc is not None and proc.poll() is None
    if not is_complete and not is_running:
        with lock:
            proc = HLS_PROCESSES.get(filename)
            is_running = proc is not None and proc.poll() is None
            is_complete = playlist.is_file() and '#EXT-X-ENDLIST' in playlist.read_text(errors='replace')
            if not is_complete and not is_running:
                if directory.is_dir():
                    for f in directory.glob('*'):
                        f.unlink(missing_ok=True)
                directory.mkdir(parents=True, exist_ok=True)
                streams = probe_media(path).get('streams', [])
                video = next((s for s in streams if s.get('codec_type') == 'video'), {})
                vaapi = is_vaapi_enabled()
                if vaapi:
                    dev = os.environ.get("MEDIA_SERVER_VAAPI_DEVICE", "/dev/dri/renderD128")
                    input_args = ['-vaapi_device', dev, '-hwaccel', 'vaapi', '-hwaccel_device', dev]
                    video_args = hls_transcode_args(True)
                elif video.get('codec_name') == 'h264' and (video.get('height') or 0) <= 1088 and (video.get('width') or 0) <= 1920 and video.get('pix_fmt', 'yuv420p') in {'yuv420p', 'yuvj420p'}:
                    input_args = []
                    video_args = ['-c:v', 'copy']
                else:
                    input_args = []
                    video_args = hls_transcode_args(False)
                audio = next((s for s in streams if s.get('codec_type') == 'audio'), {})
                audio_args = ['-c:a', 'copy'] if (audio.get('codec_name') == 'aac' and audio.get('channels', 2) <= 2) else ['-c:a', 'aac', '-ac', '2', '-b:a', '192k', '-af', 'aresample=async=1:first_pts=0']
                proc = subprocess.Popen(
                    ['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error'] + input_args + ['-i', str(path), '-map', '0:v:0', '-map', '0:a:0?'] + video_args + audio_args +
                    ['-avoid_negative_ts', 'make_zero', '-muxdelay', '0',
                     '-force_key_frames', 'expr:gte(t,n_forced*4)',
                     '-f', 'hls', '-hls_time', '4', '-hls_list_size', '0', '-hls_flags', 'independent_segments',
                     '-hls_segment_filename', str(directory / 'segment_%06d.ts'),
                     '-progress', str(directory / 'hls.progress'), '-nostats', str(playlist)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                )
                HLS_PROCESSES[filename] = proc
    deadline = time.time() + 2.0
    while time.time() < deadline:
        if playlist.is_file() and 'segment_' in playlist.read_text(errors='replace'):
            break
        if proc is not None and proc.poll() is not None:
            break
        time.sleep(0.05)
    if not playlist.is_file(): return Response('#EXTM3U\n#EXT-X-VERSION:3\n', mimetype='application/vnd.apple.mpegurl')
    return send_file(playlist, mimetype='application/vnd.apple.mpegurl', max_age=0)

@app.route('/hls/<path:filename>/<segment>')
def hls_segment(filename, segment):
    path = safe_path(filename)
    if not is_video(path) or not re.fullmatch(r'(?:init\.mp4|segment_\d{6}\.(?:m4s|ts))', segment): abort(404)
    target = hls_cache_dir(path) / segment
    if not target.is_file(): abort(404)
    mimetype = 'video/mp2t' if segment.endswith('.ts') else 'video/mp4'
    return send_file(target, mimetype=mimetype, max_age=3600)

def precache_loop():
    while True:
        for path in video_paths():
            if needs_transcode(path) and not transcode_cache_path(path).is_file():
                with app.test_request_context():
                    transcode(path.relative_to(MEDIA_ROOT).as_posix())
        time.sleep(PRECACHE_INTERVAL)

def start_precache_worker():
    if os.environ.get('MEDIA_SERVER_ENABLE_PRECACHE', '0') != '1':
        return
    threading.Thread(target=precache_loop, name='media-precache', daemon=True).start()

SCANNER_LOCK = threading.Lock()
SCAN_INTERVAL = int(os.environ.get('MEDIA_SERVER_SCAN_INTERVAL', '60'))

def trigger_library_scan():
    if not SCANNER_LOCK.locked():
        threading.Thread(target=run_library_scan, name='media-scan-worker', daemon=True).start()
        return True
    return False

def run_library_scan():
    if not SCANNER_LOCK.acquire(blocking=False):
        return
    try:
        import scanner
        scanner.scan_unindexed(media_root=MEDIA_ROOT, db_path=DATABASE)
    except Exception as e:
        app.logger.warning(f"Auto-scan failed: {e}")
    finally:
        SCANNER_LOCK.release()

def scanner_loop():
    time.sleep(2)
    while True:
        try:
            run_library_scan()
        except Exception as e:
            app.logger.warning(f"Scanner loop error: {e}")
        time.sleep(SCAN_INTERVAL)

def start_media_scanner_worker():
    if os.environ.get('MEDIA_SERVER_DISABLE_SCANNER', '0') == '1':
        return
    threading.Thread(target=scanner_loop, name='media-scanner', daemon=True).start()

@app.route('/api/scan', methods=['GET', 'POST'])
def api_scan():
    started = trigger_library_scan()
    return jsonify(
        status="scanning" if started or SCANNER_LOCK.locked() else "idle",
        busy=SCANNER_LOCK.locked()
    )

@app.route('/api/media-info/<path:filename>')
def media_info(filename):
    path = safe_path(filename)
    if not is_video(path):
        abort(404)
    probe_data = probe_media(path); format_data = probe_data.get('format', {})
    try: duration = float(format_data.get('duration') or 0)
    except (TypeError, ValueError): duration = 0
    video_stream = next((s for s in probe_data.get('streams', []) if s.get('codec_type') == 'video'), {})
    probe = which('ffprobe')
    return jsonify(
        container=path.suffix[1:].lower(),
        duration=duration,
        video_codec=video_stream.get('codec_name', ''),
        width=video_stream.get('width'),
        height=video_stream.get('height'),
        direct_play=path.suffix.lower() in {'.mp4', '.m4v', '.webm'},
        ffprobe_available=bool(probe),
        transcoding_available=bool(which('ffmpeg')),
        reason='Codec inspection unavailable: install ffprobe for a precise compatibility report.' if not probe else 'Direct play is preferred; codec inspection can be extended without changing media files.'
    )

@app.route('/api/transcode-status/<path:filename>')
def transcode_status(filename):
    path = safe_path(filename)
    if not is_video(path): abort(404)
    req_mode = request.args.get('mode')
    if not req_mode:
        req_mode = 'compat' if request.args.get('compat') == '1' else 'direct'
    hls_dir = hls_cache_dir(path)
    hls_progress = hls_dir / 'hls.progress'
    hls_playlist_file = hls_dir / 'playlist.m3u8'
    proc = HLS_PROCESSES.get(filename)
    hls_running = proc is not None and proc.poll() is None
    hls_complete = hls_playlist_file.is_file() and '#EXT-X-ENDLIST' in hls_playlist_file.read_text(errors='replace')

    is_hls = (req_mode == 'hls') or (req_mode != 'compat' and (hls_running or hls_complete or hls_progress.is_file()))
    if is_hls:
        if hls_complete:
            bytes_val = sum(p.stat().st_size for p in hls_dir.glob('segment_*.*')) if hls_dir.is_dir() else 0
            try: dur_val = float(probe_media(path).get('format', {}).get('duration') or 0)
            except (TypeError, ValueError): dur_val = 0
            return jsonify(status='ready', bytes=bytes_val, percent=100, remaining=0, encoded=dur_val, duration=dur_val, speed=0)
        prog_file = hls_progress
    else:
        cached = transcode_cache_path(path, req_mode)
        part = cached.with_name(cached.stem + '.part.mp4')
        if cached.is_file() and cached.stat().st_size:
            try: dur_val = float(probe_media(path).get('format', {}).get('duration') or 0)
            except (TypeError, ValueError): dur_val = 0
            return jsonify(status='ready', bytes=cached.stat().st_size, percent=100, remaining=0, encoded=dur_val, duration=dur_val, speed=0)
        prog_file = transcode_progress_path(path, req_mode)

    values = {}
    if prog_file and prog_file.is_file():
        for line in prog_file.read_text(errors='replace').splitlines():
            if '=' in line:
                key, value_text = line.split('=', 1); values[key] = value_text.strip()
    try: duration = float(probe_media(path).get('format', {}).get('duration') or 0)
    except (TypeError, ValueError): duration = 0
    try: encoded = float(values.get('out_time_ms', 0)) / 1_000_000
    except (TypeError, ValueError): encoded = 0
    try: speed = float(values.get('speed', '0x').rstrip('x'))
    except (TypeError, ValueError): speed = 0
    percent = min(99, encoded / duration * 100) if duration else 0
    remaining = max(0, (duration - encoded) / speed) if speed else None

    if is_hls:
        bytes_val = sum(p.stat().st_size for p in hls_dir.glob('segment_*.*')) if hls_dir.is_dir() else 0
        status = 'building' if (hls_running or (hls_progress.is_file() and not hls_complete)) else ('ready' if hls_complete else 'idle')
    else:
        bytes_val = part.stat().st_size if part.is_file() else 0
        status = 'building' if (prog_file and prog_file.is_file()) else ('partial' if part.is_file() else 'idle')
    return jsonify(status=status, bytes=bytes_val, percent=percent, remaining=remaining, encoded=encoded, duration=duration, speed=speed)

@app.route('/api/progress', methods=['GET', 'POST'])
def progress():
    if request.method == 'GET':
        filename = request.args.get('filename', ''); path = safe_path(filename)
        if not is_video(path): abort(404)
        db = get_db(); row = db.execute('SELECT position,duration FROM progress WHERE filename=?', (filename,)).fetchone(); db.close()
        return jsonify(position=value(row, 'position', 0), duration=value(row, 'duration', 0))
    data = request.get_json(silent=True) or {}; filename = data.get('filename', ''); path = safe_path(filename)
    if not is_video(path): abort(404)
    try: position = max(0, float(data.get('position', 0))); duration = max(0, float(data.get('duration', 0)))
    except (TypeError, ValueError): return jsonify(error='Invalid progress'), 400
    if duration: position = min(position, duration)
    db = get_db(); db.execute('INSERT INTO progress(filename,position,duration) VALUES(?,?,?) ON CONFLICT(filename) DO UPDATE SET position=excluded.position,duration=excluded.duration,updated_at=CURRENT_TIMESTAMP', (filename, position, duration)); db.commit(); db.close()
    return jsonify(success=True)

@app.route('/manifest.webmanifest')
def manifest():
    return Response(json.dumps({'name':'My Movies','short_name':'Movies','start_url':'/','display':'standalone','background_color':'#090b10','theme_color':'#090b10','icons':[{'src':'/icon.svg','sizes':'any','type':'image/svg+xml'}]}), mimetype='application/manifest+json')

@app.route('/icon.svg')
def icon():
    return Response('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128"><rect width="128" height="128" rx="24" fill="#e50914"/><path fill="white" d="M43 31h42v66H43zm11 17v32l27-16z"/></svg>', mimetype='image/svg+xml')

@app.route('/sw.js')
def sw():
    return Response("self.addEventListener('install',e=>self.skipWaiting());self.addEventListener('activate',e=>clients.claim());", mimetype='application/javascript', headers={'Service-Worker-Allowed': '/'})

ERROR_HTML='''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font:16px system-ui;background:#090b10;color:#fff;display:grid;place-items:center;min-height:100vh;margin:0}main{text-align:center;padding:2rem}a{color:#fff}</style><main><h1>{{code}}</h1><p>{{message}}</p><a href="/">Back to library</a></main>'''

@app.errorhandler(404)
def missing(_):return render_template_string(ERROR_HTML,code=404,message='That media item is unavailable or has moved.'),404
@app.errorhandler(403)
def denied(_):return render_template_string(ERROR_HTML,code=403,message='That location is not available.'),403

CSS='''*{box-sizing:border-box}body{margin:0;background:#090b10;color:#f7f7f8;font:16px system-ui,-apple-system,sans-serif}body:has(#shell){overflow:hidden;height:100vh;max-height:100vh}header{position:sticky;top:0;z-index:4;display:flex;justify-content:space-between;gap:1rem;padding:1rem max(1rem,calc((100% - 1260px)/2));background:#090b10ed;backdrop-filter:blur(12px)}header b{white-space:nowrap;font-size:1.2rem}form{display:flex;gap:.5rem;width:100%;max-width:38rem}input,select,button{font:inherit}header input{width:100%;background:#181a21;color:#fff;border:1px solid #30333d;border-radius:.55rem;padding:.6rem .8rem}header select{background:#181a21;color:#fff;border:1px solid #30333d;border-radius:.55rem}header button{background:#181a21;color:#fff;border:1px solid #30333d;border-radius:.55rem;padding:.6rem .8rem;cursor:pointer;white-space:nowrap}header button:hover{background:#262936}header button:disabled{opacity:.6;cursor:wait}main{max-width:1260px;margin:auto;padding:1.5rem 1rem 4rem}section{margin-bottom:2.5rem}h2{font-size:1.25rem}.grid,.rail{display:grid;grid-template-columns:repeat(auto-fill,minmax(145px,1fr));gap:1rem}.rail{display:flex;overflow:auto;padding-bottom:.5rem}.rail .card{min-width:145px}.card{color:inherit;text-decoration:none}.art{aspect-ratio:2/3;background:#191b22;border-radius:.6rem;overflow:hidden;position:relative;box-shadow:0 5px 20px #0005}.art img{height:100%;width:100%;object-fit:cover}.fallback{height:100%;display:grid;place-items:center;color:#8a8f9e;font-size:2.5rem}.bar{height:4px;background:#343641;position:absolute;bottom:0;left:0;right:0}.bar i{display:block;height:100%;background:#e50914}.name{font-weight:650;font-size:.9rem;margin-top:.5rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.year,.empty,.facts{color:#a8acb9;font-size:.84rem}.back{color:#fff;text-decoration:none;display:inline-block;margin-bottom:1.5rem}.backdrop{position:absolute;z-index:-1;inset:0 0 auto;height:min(65vw,650px);background-size:cover;background-position:center}.detail-grid{display:grid;grid-template-columns:minmax(160px,260px) 1fr;gap:2rem}.detail-grid .art{width:100%}h1{font-size:clamp(2rem,5vw,3.7rem);line-height:1.05;margin:.1rem 0 .7rem}.chips{display:flex;gap:.45rem;flex-wrap:wrap}.chips span{background:#262936;border-radius:99px;padding:.3rem .6rem;font-size:.85rem}.overview{max-width:48rem;line-height:1.65}.actions{display:flex;gap:1rem;align-items:center;flex-wrap:wrap}.primary{padding:.75rem 1.2rem;border-radius:.55rem;background:#e50914;color:#fff;text-decoration:none;font-weight:700}.watch{background:#000}.watch-back{position:fixed;z-index:3;top:1rem;left:1rem;color:#fff;text-decoration:none;text-shadow:0 1px 4px #000}#shell{height:100vh;max-height:100vh;width:100vw;max-width:100vw;overflow:hidden;display:grid;place-items:center;position:relative}video{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#000}#controls{position:absolute;inset:auto 0 0;padding:2rem 1rem 1rem;background:linear-gradient(transparent,#000d);opacity:0;transition:.2s}#shell.show #controls{opacity:1}#seek{display:block;width:100%;accent-color:#e50914}#controls>div{display:flex;gap:.6rem;align-items:center;margin-top:.5rem}#controls button,#controls select{background:#222;color:#fff;border:0;border-radius:.3rem;padding:.35rem .55rem}#volume{width:90px}#center{position:absolute;border:0;border-radius:50%;width:4rem;height:4rem;background:#0009;color:#fff;font-size:1.5rem}@media(max-width:600px){.grid{grid-template-columns:repeat(auto-fill,minmax(110px,1fr));gap:.75rem}.detail-grid{grid-template-columns:120px 1fr;gap:1rem}.overview,.actions{grid-column:1/-1}#volume{display:none}#controls{padding:.8rem}#controls>div{gap:.3rem}}'''
CSS += '#playbackError{position:absolute;z-index:2;max-width:28rem;padding:1rem;background:#1b1c22e8;border:1px solid #555;border-radius:.5rem;text-align:center;line-height:1.4}#cacheStatus{position:absolute;z-index:3;left:50%;top:50%;transform:translate(-50%,-50%);width:min(90vw,28rem);padding:1.25rem 1.35rem;background:#11141beF;border:1px solid #3b414e;border-radius:.8rem;box-shadow:0 1rem 3rem #0008;pointer-events:none}#cacheStatus strong,#cacheStatus span{display:block}#cacheStatus strong{font-size:1.05rem}#cacheStatus span{margin-top:.35rem;color:#b7bdc9;font-size:.85rem}#cacheStatus i{display:block;height:.35rem;margin-top:1rem;overflow:hidden;background:#303641;border-radius:99px}#cacheStatus b{display:block;width:38%;height:100%;background:#e50914;border-radius:inherit;animation:cacheProgress 1.25s ease-in-out infinite}@keyframes cacheProgress{0%{transform:translateX(-110%)}100%{transform:translateX(290%)}}'
CSS += '#ccBtn{font-weight:700;font-size:.78rem;padding:.2rem .45rem;border-radius:.25rem;background:#222;color:#bbb;border:1px solid #444;cursor:pointer;position:relative;transition:.15s}#ccBtn:hover{color:#fff;background:#333}#ccBtn.active{background:#e50914;color:#fff;border-color:#e50914;box-shadow:0 0 8px rgba(229,9,20,0.4)}#subSettingsBtn{font-size:1.05rem;padding:.2rem .45rem;border-radius:.25rem;background:#222;color:#bbb;border:1px solid #444;cursor:pointer;line-height:1}#subSettingsBtn:hover{color:#fff;background:#333}.sub-modal{position:absolute;z-index:10;left:50%;top:50%;transform:translate(-50%,-50%);width:min(90vw,340px);background:rgba(18,20,28,0.96);backdrop-filter:blur(16px);border:1px solid #3b414e;border-radius:.8rem;box-shadow:0 1rem 3rem rgba(0,0,0,0.8);color:#fff;padding:1rem 1.2rem}.sub-modal-header{display:flex;justify-content:space-between;align-items:center;font-weight:700;font-size:1.05rem;padding-bottom:.6rem;border-bottom:1px solid #2e323e}.sub-modal-close{background:none;border:none;color:#aaa;font-size:1.4rem;cursor:pointer;line-height:1;padding:0 .3rem}.sub-modal-close:hover{color:#fff}.sub-modal-body{margin-top:.8rem;display:flex;flex-direction:column;gap:.75rem}.sub-field{display:flex;justify-content:space-between;align-items:center;gap:1rem;font-size:.88rem}.sub-field label{color:#bbb;white-space:nowrap}.sub-field select{background:#262936;color:#fff;border:1px solid #3e4454;border-radius:.4rem;padding:.35rem .6rem;font-size:.86rem;max-width:180px}.sub-preview-wrap{flex-direction:column;align-items:stretch;gap:.4rem;margin-top:.4rem}#subPreviewBox{min-height:3.8rem;background:#000;border:1px dashed #444;border-radius:.4rem;display:grid;place-items:center;overflow:hidden;padding:.4rem}'

LIBRARY_HTML='''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="theme-color" content="#090b10"><link rel="manifest" href="/manifest.webmanifest"><style>{{css}}</style><header><b>◉ My Movies</b><form><input name="q" value="{{q}}" placeholder="Search your library"><select name="sort" onchange="this.form.submit()"><option value="title" {%if sort=='title'%}selected{%endif%}>A–Z</option><option value="recent" {%if sort=='recent'%}selected{%endif%}>Recently watched</option></select><button id="scanBtn" type="button" onclick="this.disabled=true;this.textContent='Scanning...';fetch('/api/scan',{method:'POST'}).then(r=>r.json()).then(()=>{setTimeout(()=>location.reload(),2000)}).catch(()=>this.disabled=false)" title="Scan library for newly added media">↻ Scan</button></form></header><main>{%if watching%}<section><h2>Continue watching</h2><div class="rail">{%for m in watching%}{{card(m)|safe}}{%endfor%}</div></section>{%endif%}<section><h2>{%if q%}Results for “{{q}}”{%else%}All movies{%endif%}</h2>{%if movies%}<div class="grid">{%for m in movies%}{{card(m)|safe}}{%endfor%}</div>{%else%}<p class="empty">No movies found.</p>{%endif%}</section></main><script>if('serviceWorker'in navigator)navigator.serviceWorker.register('/sw.js')</script>'''

DETAILS_HTML='''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>{{css}}</style>{%if backdrop%}<div class="backdrop" style="background-image:linear-gradient(90deg,#090b10 10%,transparent),linear-gradient(0deg,#090b10,transparent 60%),url('{{url_for('tmdb_backdrop',tmdb_id=backdrop)}}')"></div>{%endif%}<main><a class="back" href="/">← Library</a><div class="detail-grid">{{poster(movie)|safe}}<div><h1>{{movie.title}}</h1><p class="facts">{{movie.release_date or movie.year}}{%if movie.runtime%} · {{movie.runtime}} min{%endif%}{%if movie.rating%} · ★ {{'%.1f'|format(movie.rating)}}/10{%endif%}</p>{%if movie.genres%}<div class="chips">{%for g in movie.genres.split(', ')%}<span>{{g}}</span>{%endfor%}</div>{%endif%}<p class="overview">{{movie.overview or 'No synopsis is available for this title.'}}</p><div class="actions"><a class="primary" href="{{url_for('watch',filename=movie.filename)}}">▶ {%if movie.position>10%}Resume{%else%}Play{%endif%}</a>{%if movie.position>10%}<span>Watched {{movie.percent|round|int}}%</span>{%endif%}</div></div></div></main>'''

PLAYER_HTML='''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><style>{{css}}</style><div id="shell" class="show"><video id="video" playsinline preload="metadata"><source src="{{url_for('media',filename=movie.filename)}}">{%for t in tracks%}<track kind="subtitles" label="{{t.label}}" srclang="{{t.lang}}" src="{{t.src}}" {%if t.default%}default{%endif%}>{%endfor%}</video><button id="center">▶</button><div id="controls"><input id="seek" type="range" min="0" max="100" value="0"><div><button id="play">▶</button><span id="time">0:00 / 0:00</span><button id="mute">🔊</button><input id="volume" type="range" min="0" max="1" step=".05" value="1"><select id="speed"><option>.75×</option><option selected>1×</option><option>1.25×</option><option>1.5×</option><option>2×</option></select>{%if tracks%}<button id="ccBtn" type="button" title="Subtitles/closed captions (c)">CC</button><button id="subSettingsBtn" type="button" title="Subtitle settings">⚙</button>{%endif%}<button id="full">⛶</button></div></div>{%if tracks%}<div id="subSettingsModal" class="sub-modal" hidden><div class="sub-modal-content"><div class="sub-modal-header"><span>Subtitle Settings</span><button id="closeSubModal" type="button" class="sub-modal-close">&times;</button></div><div class="sub-modal-body"><div class="sub-field"><label for="subTrackSelect">Track</label><select id="subTrackSelect"><option value="-1">Subtitles off</option>{%for t in tracks%}<option value="{{loop.index0}}">{{t.label}}</option>{%endfor%}</select></div><div class="sub-field"><label for="subColorSelect">Text Color</label><select id="subColorSelect"><option value="#ffffff" selected>White</option><option value="#ffff00">Yellow</option><option value="#00e5ff">Cyan</option><option value="#00ff66">Green</option><option value="#ff4081">Magenta</option></select></div><div class="sub-field"><label for="subBgSelect">Background Opacity</label><select id="subBgSelect"><option value="0">0% (None)</option><option value="0.25">25%</option><option value="0.5">50%</option><option value="0.75" selected>75%</option><option value="1">100% (Solid)</option></select></div><div class="sub-field"><label for="subSizeSelect">Font Size</label><select id="subSizeSelect"><option value="clamp(17px, 2.1vw, 27px)">75% (Small)</option><option value="clamp(22px, 2.8vw, 36px)" selected>100% (Normal)</option><option value="clamp(28px, 3.5vw, 45px)">125% (Medium)</option><option value="clamp(33px, 4.2vw, 54px)">150% (Large)</option><option value="clamp(44px, 5.6vw, 72px)">200% (Huge)</option></select></div><div class="sub-field sub-preview-wrap"><label>Preview</label><div id="subPreviewBox"><span id="subPreviewSample">Subtitle preview sample</span></div></div></div></div></div>{%endif%}</div><a class="watch-back" href="{{url_for('details',filename=movie.filename)}}">← {{movie.title}}</a><script>const filename={{movie.filename|tojson}},v=document.querySelector('#video'),shell=document.querySelector('#shell'),seek=document.querySelector('#seek'),play=document.querySelector('#play'),center=document.querySelector('#center'),timeEl=document.querySelector('#time');let last=0,t;const fmt=s=>{s=Math.floor(s||0);return(s>3599?Math.floor(s/3600)+':':'')+String(Math.floor(s%3600/60)).padStart(s>3599?2:1,'0')+':'+String(s%60).padStart(2,'0')};function toggle(){v.paused?v.play():v.pause()}function save(){if(v.duration)fetch('/api/progress',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({filename,position:v.ended?0:v.currentTime,duration:v.duration}),keepalive:true})}function show(){shell.classList.add('show');clearTimeout(t);if(!v.paused)t=setTimeout(()=>shell.classList.remove('show'),2500)}play.onclick=toggle;center.onclick=toggle;v.onclick=toggle;v.onplay=()=>{play.textContent='❚❚';center.hidden=true;show()};v.onpause=()=>{play.textContent='▶';center.hidden=false;save();show()};v.ontimeupdate=()=>{seek.value=v.duration?v.currentTime/v.duration*100:0;timeEl.textContent=fmt(v.currentTime)+' / '+fmt(v.duration);if(v.currentTime-last>10){last=v.currentTime;save()}};v.onended=save;seek.oninput=()=>{if(v.duration)v.currentTime=seek.value/100*v.duration};mute.onclick=()=>v.muted=!v.muted;volume.oninput=e=>{v.volume=e.target.value;v.muted=false};speed.onchange=e=>v.playbackRate=parseFloat(e.target.value);full.onclick=()=>shell.requestFullscreen?.();{%if tracks%}const ccBtn=document.querySelector('#ccBtn'),subSettingsBtn=document.querySelector('#subSettingsBtn'),subSettingsModal=document.querySelector('#subSettingsModal'),closeSubModal=document.querySelector('#closeSubModal'),subTrackSelect=document.querySelector('#subTrackSelect'),subColorSelect=document.querySelector('#subColorSelect'),subBgSelect=document.querySelector('#subBgSelect'),subSizeSelect=document.querySelector('#subSizeSelect'),subPreviewSample=document.querySelector('#subPreviewSample');const SUB_KEY='media_sub_settings',DEFAULT_SUB_SIZE='clamp(22px, 2.8vw, 36px)',SUB_SIZE_MAP={'75%':'clamp(17px, 2.1vw, 27px)','100%':'clamp(22px, 2.8vw, 36px)','125%':'clamp(28px, 3.5vw, 45px)','150%':'clamp(33px, 4.2vw, 54px)','200%':'clamp(44px, 5.6vw, 72px)'};let subPrefs={enabled:true,trackIndex:-1,color:'#ffffff',bgOpacity:'0.75',size:DEFAULT_SUB_SIZE};try{const saved=localStorage.getItem(SUB_KEY);if(saved){Object.assign(subPrefs,JSON.parse(saved));if(subPrefs.size&&SUB_SIZE_MAP[subPrefs.size]){subPrefs.size=SUB_SIZE_MAP[subPrefs.size];}else if(!subPrefs.size||!subPrefs.size.includes('clamp')){subPrefs.size=DEFAULT_SUB_SIZE;}}}catch(e){}function elevateCues(){const trks=[...v.textTracks],isHuge=subPrefs&&subPrefs.size&&(subPrefs.size.includes('44px')||subPrefs.size.includes('33px')),targetLine=isHuge?-4:-3.5;trks.forEach(t=>{if(t.cues){for(let i=0;i<t.cues.length;i++){const c=t.cues[i];c.snapToLines=true;c.line=targetLine;}}if(!t._cueElevated){t._cueElevated=true;t.addEventListener('cuechange',()=>{if(t.activeCues){const l=(subPrefs&&subPrefs.size&&(subPrefs.size.includes('44px')||subPrefs.size.includes('33px')))?-4:-3.5;for(let i=0;i<t.activeCues.length;i++){const c=t.activeCues[i];c.snapToLines=true;c.line=l;}}});}});}function applySubStyles(){let sEl=document.getElementById('cue-styles');if(!sEl){sEl=document.createElement('style');sEl.id='cue-styles';document.head.appendChild(sEl);}const bg='rgba(0,0,0,'+subPrefs.bgOpacity+')';sEl.textContent='video::cue{color:'+subPrefs.color+' !important;background-color:'+bg+' !important;font-size:'+subPrefs.size+' !important;font-family:system-ui,-apple-system,sans-serif !important;text-shadow:0 1px 2px #000,0 0 3px #000 !important;line-height:1.3 !important;}';if(subPreviewSample){subPreviewSample.style.color=subPrefs.color;subPreviewSample.style.backgroundColor=bg;subPreviewSample.style.fontSize=subPrefs.size;subPreviewSample.style.padding='0.2rem 0.5rem';subPreviewSample.style.borderRadius='3px';subPreviewSample.style.textShadow='0 1px 2px #000,0 0 3px #000';}try{localStorage.setItem(SUB_KEY,JSON.stringify(subPrefs));}catch(e){}elevateCues();}function selectTrack(idx){idx=Number(idx);subPrefs.trackIndex=idx;subPrefs.enabled=(idx>=0);[...v.textTracks].forEach((t,i)=>{t.mode=(i===idx)?'showing':'disabled';});if(ccBtn){if(idx>=0)ccBtn.classList.add('active');else ccBtn.classList.remove('active');}if(subTrackSelect)subTrackSelect.value=String(idx);applySubStyles();elevateCues();}function toggleCC(){const trks=[...v.textTracks];if(!trks.length)return;const curr=trks.findIndex(t=>t.mode==='showing');if(curr>=0){selectTrack(-1);}else{let tgt=0;if(subPrefs.trackIndex>=0&&subPrefs.trackIndex<trks.length){tgt=subPrefs.trackIndex;}else{const eng=trks.findIndex(t=>t.language==='en'||(t.label&&t.label.toLowerCase().includes('english')));if(eng>=0)tgt=eng;}selectTrack(tgt);}}if(ccBtn)ccBtn.onclick=e=>{e.stopPropagation();toggleCC();show();};if(subSettingsBtn)subSettingsBtn.onclick=e=>{e.stopPropagation();if(subSettingsModal){subSettingsModal.hidden=!subSettingsModal.hidden;show();}};if(closeSubModal)closeSubModal.onclick=e=>{e.stopPropagation();if(subSettingsModal)subSettingsModal.hidden=true;};if(subSettingsModal)subSettingsModal.onclick=e=>e.stopPropagation();if(subTrackSelect)subTrackSelect.onchange=e=>selectTrack(e.target.value);if(subColorSelect){subColorSelect.value=subPrefs.color;subColorSelect.onchange=e=>{subPrefs.color=e.target.value;applySubStyles();};}if(subBgSelect){subBgSelect.value=subPrefs.bgOpacity;subBgSelect.onchange=e=>{subPrefs.bgOpacity=e.target.value;applySubStyles();};}if(subSizeSelect){subSizeSelect.value=subPrefs.size;subSizeSelect.onchange=e=>{subPrefs.size=e.target.value;applySubStyles();};}const initSubs=()=>{applySubStyles();const trks=[...v.textTracks];if(!trks.length)return;let initIdx=-1;if(subPrefs.enabled){if(subPrefs.trackIndex>=0&&subPrefs.trackIndex<trks.length){initIdx=subPrefs.trackIndex;}else{const eng=trks.findIndex(t=>t.language==='en'||(t.label&&t.label.toLowerCase().includes('english')));initIdx=eng>=0?eng:0;}}selectTrack(initIdx);elevateCues();};document.querySelectorAll('track').forEach(tr=>{tr.addEventListener('load',elevateCues);});window.subPrefs=subPrefs;window.selectTrack=selectTrack;window.toggleCC=toggleCC;window.applySubStyles=applySubStyles;window.elevateCues=elevateCues;v.addEventListener('loadedmetadata',initSubs);setTimeout(initSubs,250);setTimeout(elevateCues,800);setTimeout(elevateCues,1800);{%endif%}document.onkeydown=e=>{if(e.target.matches('input,select'))return;if(e.code==='Space'){e.preventDefault();toggle()}if(e.key==='c'||e.key==='C'){e.preventDefault();if(typeof toggleCC==='function')toggleCC();show();}if(e.code==='ArrowRight')v.currentTime+=5;if(e.code==='ArrowLeft')v.currentTime-=5;if(e.key==='f')full.click();show()};fetch('/api/progress?filename='+encodeURIComponent(filename)).then(r=>r.json()).then(p=>{if(p.position>10&&p.duration&&p.position<p.duration-10)v.addEventListener('loadedmetadata',()=>v.currentTime=p.position,{once:true})});shell.onmousemove=show;shell.ontouchstart=show;shell.addEventListener('click',e=>{if(subSettingsModal&&!subSettingsModal.hidden&&!e.target.closest('.sub-modal')&&!e.target.closest('#subSettingsBtn')){subSettingsModal.hidden=true;}});addEventListener('pagehide',save)</script>'''
PLAYER_HTML = PLAYER_HTML.replace('preload="metadata"', 'preload="none"')
PLAYER_HTML = PLAYER_HTML.replace('if(v.duration)fetch(', 'if(timelineDuration())fetch(')
PLAYER_HTML = PLAYER_HTML.replace('duration:v.duration', 'duration:timelineDuration()')
PLAYER_HTML = PLAYER_HTML.replace(
    'full.onclick=()=>shell.requestFullscreen?.();',
    'full.onclick=()=>document.fullscreenElement?document.exitFullscreen?.():shell.requestFullscreen?.();',
)
PLAYER_HTML = PLAYER_HTML.replace(
    '<source src="{{url_for(\'media\',filename=movie.filename)}}">',
    '<source id="source" src="{{url_for(\'media\',filename=movie.filename)}}">'
    '<p id="playbackError" hidden></p>',
)
PLAYER_HTML = PLAYER_HTML.replace('<span id="time">0:00 / 0:00</span>', '<span id="time">0:00 / 0:00</span><span id="seekEta" style="color:#e50914;font-size:.82rem;font-weight:600;margin-left:.4rem" hidden></span>')
PLAYER_HTML = PLAYER_HTML.replace(
    '</video><button id="center">',
    '</video><p id="playbackError" hidden></p><div id="cacheStatus" hidden><strong>Preparing video</strong><span id="cacheMessage">Converting for browser playback...</span><i><b></b></i><span id="cacheEta" style="display:block;margin-top:.4rem;font-size:.82rem;color:#b7bdc9"></span></div><button id="center">',
)
PLAYER_HTML = PLAYER_HTML.replace('<p id="playbackError" hidden></p>', '')

PLAYER_HTML = PLAYER_HTML.replace(
    'function toggle(){v.paused?v.play():v.pause()}',
    'function toggle(){jumpStartGap();v.paused?v.play():v.pause()}',
)
PLAYER_HTML = PLAYER_HTML.replace(
    '<input id="seek" type="range" min="0" max="100" value="0">',
    '<input id="seek" type="range" min="0" max="100" step="any" value="0">',
)
PLAYER_HTML = PLAYER_HTML.replace(
    "v.ontimeupdate=()=>{seek.value=v.duration?v.currentTime/v.duration*100:0;timeEl.textContent=fmt(v.currentTime)+' / '+fmt(v.duration);if(v.currentTime-last>10){last=v.currentTime;save()}};",
    "v.ontimeupdate=()=>{if(v.currentTime-last>10){last=v.currentTime;save()}};",
)
PLAYER_HTML = PLAYER_HTML.replace(
    "if(e.code==='ArrowLeft')v.currentTime-=5;",
    "if(e.code==='ArrowLeft')v.currentTime=Math.max(0.08,v.currentTime-5);",
)
PLAYER_HTML = PLAYER_HTML.replace(
    '</script>',
    ''';let mediaDuration=0;const timelineDuration=()=>mediaDuration||v.duration,source=document.querySelector('#source'),playbackError=document.querySelector('#playbackError');
v.addEventListener('error',()=>{if(!source.dataset.transcoded){startHls()}else if(source.dataset.transcoded==='hls'){source.dataset.transcoded='compat';source.src='/transcode/'+filename.split('/').map(encodeURIComponent).join('/')+'?compat=1';v.load();v.play().catch(()=>{})}});''' + '</script>'
)
PLAYER_HTML = PLAYER_HTML.replace(
    '</script>',
    "fetch('/api/media-info/'+encodeURIComponent(filename)).then(r=>r.json()).then(info=>{mediaDuration=Number(info.duration)||0;const d=timelineDuration();if(d)timeEl.textContent=fmt(v.currentTime<0.1?0:v.currentTime)+' / '+fmt(d)});"
    "v.addEventListener('timeupdate',()=>{const d=timelineDuration();if(d&&!isScrubbing){seek.value=v.currentTime<0.1?0:v.currentTime/d*100;timeEl.textContent=fmt(v.currentTime<0.1?0:v.currentTime)+' / '+fmt(d);if(!v.paused&&v.readyState>=3&&currentSeekTarget===null){if(cacheStatus)cacheStatus.hidden=true;if(seekEta)seekEta.hidden=true;}}});"
    "</script>"
)
PLAYER_HTML = PLAYER_HTML.replace(
    ';let mediaDuration=0;const timelineDuration=()=>mediaDuration||v.duration,source=document.querySelector(\'#source\'),playbackError=document.querySelector(\'#playbackError\');',
    ";let mediaDuration=0,cacheTimer,currentSeekTarget=null,isScrubbing=false,isTranscodeReady=false,wasPlayingBeforeScrub=false;"
    "const timelineDuration=()=>mediaDuration||v.duration,source=document.querySelector('#source'),playbackError=document.querySelector('#playbackError'),"
    "cacheStatus=document.querySelector('#cacheStatus'),cacheMessage=document.querySelector('#cacheMessage'),cacheEta=document.querySelector('#cacheEta'),"
    "seekEta=document.querySelector('#seekEta'),cacheBar=document.querySelector('#cacheStatus b'),"
    "formatBytes=n=>n<1048576?Math.round(n/1024)+' KB':(n/1048576).toFixed(0)+' MB',"
    "formatEta=s=>{if(s==null||!isFinite(s))return 'calculating time';s=Math.max(0,Math.round(s));return s>=3600?Math.floor(s/3600)+'h '+Math.floor(s%3600/60)+'m remaining':Math.floor(s/60)+'m '+String(s%60).padStart(2,'0')+'s remaining'};"
    "const jumpStartGap=()=>{try{if(v.currentTime<0.08){v.currentTime=0.08;}if(v.buffered&&v.buffered.length>0){for(let i=0;i<v.buffered.length;i++){const s=v.buffered.start(i);if(s>0.005&&s<1&&v.currentTime<s){v.currentTime=s+0.01;break;}}}}catch(e){}};"
    "const getStatusEp=()=>{const mode=source.dataset.transcoded||'';return '/api/transcode-status/'+encodeURIComponent(filename)+(mode==='hls'?'?mode=hls':(mode==='compat'?'?compat=1':''));};"
    "const updateProgress=s=>{"
    "if(s.status==='building'||s.status==='partial'){"
    "const targetTime=currentSeekTarget!==null?currentSeekTarget:v.currentTime,encoded=s.encoded||0,isSeekingAhead=targetTime>encoded+2;"
    "if(currentSeekTarget!==null&&encoded>=currentSeekTarget){const t=currentSeekTarget;currentSeekTarget=null;v.currentTime=t;v.play().catch(()=>{});}"
    "const needsTranscodeWait=(encoded===0)||isSeekingAhead||(currentSeekTarget!==null&&currentSeekTarget>encoded);"
    "if(cacheStatus)cacheStatus.hidden=!needsTranscodeWait;"
    "if(cacheBar){cacheBar.style.animation='none';cacheBar.style.width=Math.max(2,s.percent)+'%';}"
    "let etaText=formatEta(s.remaining);"
    "if(isSeekingAhead&&s.speed>0){const targetRemaining=Math.max(0,(targetTime-encoded)/s.speed);etaText=formatEta(targetRemaining)+' for this scene';}"
    "if(isSeekingAhead){if(cacheMessage)cacheMessage.textContent='Preparing video up to '+fmt(targetTime)+' (ready up to '+fmt(encoded)+')...';if(cacheEta)cacheEta.textContent='ETA: '+etaText+' · '+s.percent.toFixed(0)+'% overall'+(s.speed?' ('+s.speed.toFixed(1)+'x speed)':'');}"
    "else if(encoded===0){if(cacheMessage)cacheMessage.textContent='Converting for browser playback...';if(cacheEta)cacheEta.textContent='ETA: '+etaText;}"
    "else{if(cacheMessage)cacheMessage.textContent=s.percent>=99?'Finalizing cached video...':'Preparing video · '+s.percent.toFixed(0)+'% · '+formatBytes(s.bytes)+' ready';if(cacheEta)cacheEta.textContent='ETA: '+etaText+' ('+s.percent.toFixed(0)+'% prepared)';}"
    "seek.title='Preparing: '+s.percent.toFixed(0)+'% · ETA: '+etaText;"
    "if(seekEta){seekEta.hidden=!isSeekingAhead;seekEta.textContent='ETA: '+etaText;}"
    "if(!needsTranscodeWait&&cacheTimer){clearInterval(cacheTimer);cacheTimer=null;}"
    "}else if(s.status==='ready'){"
    "isTranscodeReady=true;"
    "if(currentSeekTarget!==null){const t=currentSeekTarget;currentSeekTarget=null;v.currentTime=t;v.play().catch(()=>{});}"
    "if(cacheStatus)cacheStatus.hidden=true;seek.title='';if(seekEta)seekEta.hidden=true;"
    "if(cacheTimer){clearInterval(cacheTimer);cacheTimer=null;}"
    "}"
    "};"
    "const checkPreparing=target=>{"
    "if(isTranscodeReady)return;"
    "if(target!==undefined)currentSeekTarget=target;"
    "const ep=getStatusEp();"
    "fetch(ep).then(r=>r.json()).then(s=>{"
    "if(s.status==='building'||s.status==='partial'){"
    "updateProgress(s);"
    "if(!cacheTimer){const targetTime=currentSeekTarget!==null?currentSeekTarget:v.currentTime,encoded=s.encoded||0;if((encoded===0)||(targetTime>encoded+2)){cacheTimer=setInterval(()=>fetch(ep).then(r=>r.json()).then(updateProgress).catch(()=>{}),1000);}}"
    "}else if(s.status==='ready'){updateProgress(s);}"
    "}).catch(()=>{});"
    "};"
    "seek.onpointerdown=seek.ontouchstart=()=>{isScrubbing=true;wasPlayingBeforeScrub=!v.paused;};"
    "seek.oninput=()=>{const d=timelineDuration();if(d){let target=seek.value/100*d,s=(v.buffered&&v.buffered.length)?v.buffered.start(0):0;if(target<0.1)target=(s>0.005&&s<1)?s+0.01:0.08;v.currentTime=target;currentSeekTarget=null;timeEl.textContent=fmt(seek.value<0.1?0:target)+' / '+fmt(d);if(!isTranscodeReady)checkPreparing(target);}};"
    "seek.onpointerup=seek.ontouchend=seek.onchange=()=>{isScrubbing=false;const d=timelineDuration();if(d){let target=seek.value/100*d,s=(v.buffered&&v.buffered.length)?v.buffered.start(0):0;if(target<0.1)target=(s>0.005&&s<1)?s+0.01:0.08;v.currentTime=target;currentSeekTarget=null;if(wasPlayingBeforeScrub||!v.paused)v.play().catch(()=>{});if(!isTranscodeReady)checkPreparing(target);}};"
    "v.addEventListener('loadeddata',jumpStartGap);"
    "v.addEventListener('waiting',()=>{jumpStartGap();checkPreparing();});"
    "v.addEventListener('seeking',()=>{jumpStartGap();checkPreparing();});"
    "v.addEventListener('stalled',()=>{jumpStartGap();checkPreparing();});"
    "v.addEventListener('playing',()=>{if(currentSeekTarget===null){if(cacheStatus)cacheStatus.hidden=true;if(seekEta)seekEta.hidden=true;if(cacheTimer){clearInterval(cacheTimer);cacheTimer=null;}}});"
    "v.addEventListener('canplay',()=>{jumpStartGap();if(!v.paused&&currentSeekTarget===null){if(cacheStatus)cacheStatus.hidden=true;if(seekEta)seekEta.hidden=true;if(cacheTimer){clearInterval(cacheTimer);cacheTimer=null;}}});"
    "v.addEventListener('seeked',()=>{jumpStartGap();if(v.readyState>=3&&currentSeekTarget===null){if(cacheStatus)cacheStatus.hidden=true;if(seekEta)seekEta.hidden=true;if(cacheTimer){clearInterval(cacheTimer);cacheTimer=null;}}});"
    "v.addEventListener('loadedmetadata',()=>{jumpStartGap();if(currentSeekTarget===null){if(cacheStatus)cacheStatus.hidden=true;if(cacheTimer){clearInterval(cacheTimer);cacheTimer=null;}}v.play().catch(()=>{});});"
    "const startSource=mode=>{source.dataset.transcoded=mode;source.src='/transcode/'+filename.split('/').map(encodeURIComponent).join('/')+(mode==='compat'?'?compat=1':'');v.load()};"
    "const startHls=()=>{if(source)source.removeAttribute('src');v.load();source.dataset.transcoded='hls';if(cacheMessage)cacheMessage.textContent='Preparing video...';if(cacheEta)cacheEta.textContent='Calculating ETA...';const playlist='/hls/'+filename.split('/').map(encodeURIComponent).join('/')+'/playlist.m3u8';checkPreparing();if(v.canPlayType('application/vnd.apple.mpegurl')){v.src=playlist;return;}const initHls=()=>{if(!window.Hls||!Hls.isSupported()){startSource('compat');return;}const hls=new Hls({lowLatencyMode:false,maxBufferHole:0.5,maxSeekHole:2.0,startPosition:0.08,nudgeOffset:0.1,nudgeMaxRetry:5});window.hlsInstance=hls;hls.loadSource(playlist);hls.attachMedia(v);hls.on(Hls.Events.MANIFEST_PARSED,()=>{jumpStartGap();if(cacheStatus)cacheStatus.hidden=true;if(seekEta)seekEta.hidden=true;if(cacheTimer){clearInterval(cacheTimer);cacheTimer=null;}v.play().catch(()=>{});});hls.on(Hls.Events.BUFFER_APPENDED,()=>{jumpStartGap();if(!v.paused)v.play().catch(()=>{});});hls.on(Hls.Events.FRAG_BUFFERED,jumpStartGap);hls.on(Hls.Events.ERROR,(e,data)=>{if(data.fatal){switch(data.type){case Hls.ErrorTypes.NETWORK_ERROR:hls.startLoad();break;case Hls.ErrorTypes.MEDIA_ERROR:hls.recoverMediaError();break;default:hls.destroy();startSource('compat');break;}}});};if(window.Hls&&Hls.isSupported()){initHls();}else{const script=document.createElement('script');script.src='https://cdn.jsdelivr.net/npm/hls.js@1';script.onload=()=>initHls();script.onerror=()=>startSource('compat');document.head.appendChild(script);}};"
    "if(!/\\.(mp4|m4v|webm)$/i.test(filename)){startHls();}"
)
PLAYER_HTML = PLAYER_HTML.replace(
    "if(p.position>10&&p.duration&&p.position<p.duration-10)v.addEventListener('loadedmetadata',()=>v.currentTime=p.position,{once:true})",
    "if(p.position>10&&p.duration&&p.position<p.duration-10){if(source.dataset.transcoded==='hls'){checkPreparing(p.position);fetch(getStatusEp()).then(r=>r.json()).then(s=>{if((s.status==='ready')||(s.encoded!=null&&s.encoded>=p.position)){v.currentTime=p.position;currentSeekTarget=null;}else{currentSeekTarget=p.position;}}).catch(()=>{v.currentTime=p.position;});}else{v.addEventListener('loadedmetadata',()=>v.currentTime=p.position,{once:true})}}"
)

@app.context_processor
def helpers():
    def poster(m):
        if m['poster']:
            src=url_for('tmdb_poster',tmdb_id=m['tmdb_id']) if m['poster'].startswith('tmdb:') else url_for('poster',filename=m['poster'][6:]);return f'<div class="art"><img src="{escape(src)}" alt="" loading="lazy"></div>'
        return '<div class="art"><div class="fallback">◉</div></div>'
    def card(m):return f'<a class="card" href="{escape(url_for("details",filename=m["filename"]))}">{poster(m)}<div class="bar"><i style="width:{m["percent"]:.2f}%"></i></div><div class="name">{escape(m["title"])}</div><div class="year">{escape(m["year"] or "")}</div></a>'
    return dict(css=CSS,poster=poster,card=card)

if __name__=='__main__':
    MEDIA_ROOT.mkdir(parents=True,exist_ok=True);POSTER_CACHE.mkdir(parents=True,exist_ok=True);BACKDROP_CACHE.mkdir(parents=True,exist_ok=True);SUBTITLE_EMBEDDED_CACHE.mkdir(parents=True,exist_ok=True);SUBTITLE_ONLINE_CACHE.mkdir(parents=True,exist_ok=True);cleanup_cache_on_startup();init_db();start_precache_worker();start_media_scanner_worker();app.run(host='0.0.0.0',port=int(os.environ.get('PORT',8000)),debug=False)
