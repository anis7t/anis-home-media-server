"""LAN-first Flask media server."""
import hashlib, json, logging, mimetypes, os, re, sqlite3, subprocess, threading, time
from functools import lru_cache
from pathlib import Path
from shutil import which
from flask import Flask, Response, abort, jsonify, render_template_string, request, send_file, url_for
from markupsafe import escape

BASE_DIR = Path(os.environ.get("MEDIA_SERVER_BASE_DIR", Path(__file__).parent)).resolve()
MEDIA_ROOT = Path(os.environ.get("MEDIA_SERVER_MEDIA_ROOT", "/home/iamroot/Media/Movies")).resolve()
DATABASE = Path(os.environ.get("MEDIA_SERVER_DATABASE", BASE_DIR / "media.db"))
CACHE_DIR, POSTER_CACHE, BACKDROP_CACHE = BASE_DIR / "cache", BASE_DIR / "cache/posters", BASE_DIR / "cache/backdrops"
VIDEO_EXTENSIONS = {".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v"}; SUBTITLE_EXTENSIONS = {".srt", ".vtt"}; POSTER_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}
app = Flask(__name__); logging.basicConfig(level=os.environ.get("MEDIA_SERVER_LOG_LEVEL", "INFO"))
TRANSCODE_LOCKS = {}
PRECACHE_INTERVAL = 30

def transcode_cache_path(path, mode='direct'):
    stamp = f'{path}:{path.stat().st_size}:{path.stat().st_mtime_ns}'.encode()
    key = stamp if mode == 'direct' else (mode + ':').encode() + stamp
    return CACHE_DIR / 'transcodes' / f'{hashlib.sha256(key).hexdigest()}.mp4'

def needs_transcode(path):
    return path.suffix.lower() not in {'.mp4', '.m4v', '.webm'}

def transcode_progress_path(path, mode='direct'):
    return transcode_cache_path(path, mode).with_suffix('.progress')

def hls_cache_dir(path):
    key = hashlib.sha256(f'hls:{path}:{path.stat().st_size}:{path.stat().st_mtime_ns}'.encode()).hexdigest()
    return CACHE_DIR / 'hls' / key

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
    path=(MEDIA_ROOT/name).resolve()
    try: path.relative_to(MEDIA_ROOT)
    except ValueError: abort(403)
    return path
def is_video(path): return path.is_file() and path.suffix.lower() in VIDEO_EXTENSIONS
def value(row,key,default=None): return default if row is None or key not in row.keys() or row[key] is None else row[key]
def clean_title(name):
    title=re.sub(r'[._]+',' ',Path(name).stem)
    return re.sub(r'\s+',' ',re.sub(r'\b(2160p|1080p|720p|480p|4K|BluRay|WEBRip|WEB-DL|WEB|HDR|REMUX|x264|x265|HEVC)\b','',title,flags=re.I)).strip()
def poster_for(path,row):
    tmdb_id=value(row,'tmdb_id')
    if tmdb_id and (POSTER_CACHE/f'{tmdb_id}.jpg').is_file(): return f'tmdb:{tmdb_id}'
    for p in [path.with_suffix(ext) for ext in POSTER_EXTENSIONS]+[path.parent/f'poster{ext}' for ext in POSTER_EXTENSIONS]:
        if p.is_file(): return 'local:'+p.relative_to(MEDIA_ROOT).as_posix()
    return None
_paths=(0,[])
def video_paths():
    global _paths
    current = sorted((p for p in MEDIA_ROOT.rglob('*') if is_video(p)), key=lambda p: p.name.lower()) if MEDIA_ROOT.exists() else []
    if time.monotonic() - _paths[0] > 30 or len(current) != len(_paths[1]) or {p.resolve() for p in current} != {p.resolve() for p in _paths[1]}:
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
def tracks(path):
    result=[]
    for sub in sorted(path.parent.iterdir()):
        if sub.is_file() and sub.suffix.lower() in SUBTITLE_EXTENSIONS and (sub.stem==path.stem or sub.stem.startswith(path.stem+'.')):
            code=sub.stem[len(path.stem):].strip('.').split('.')[0].lower(); label={'en':'English','hi':'Hindi'}.get(code,code.upper() if code else 'Subtitles'); result.append(dict(name=sub.name,lang=code or 'und',label=label))
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
    return render_template_string(PLAYER_HTML,movie=m,tracks=tracks(path))
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
def tmdb_poster(tmdb_id):return cached(POSTER_CACHE/f'{tmdb_id}.jpg')
@app.route('/tmdb-backdrop/<int:tmdb_id>')
def tmdb_backdrop(tmdb_id):return cached(BACKDROP_CACHE/f'{tmdb_id}.jpg')
@app.route('/subtitles/<path:filename>/<path:name>')
def subtitle(filename,name):
    video=safe_path(filename); sub=(video.parent/name).resolve()
    if not is_video(video) or sub.parent!=video.parent or not sub.is_file() or sub.suffix.lower() not in SUBTITLE_EXTENSIONS:abort(404)
    text=sub.read_text(encoding='utf-8-sig',errors='replace')
    if sub.suffix.lower()=='.srt':text='WEBVTT\n\n'+re.sub(r'(?m)^(\d\d:\d\d:\d\d),',r'\1.',text)
    return Response(text,mimetype='text/vtt',headers={'Cache-Control':'private, max-age=3600'})
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

    lock = TRANSCODE_LOCKS.setdefault(filename, threading.Lock())
    lock.acquire()
    temporary = cached.with_name(cached.stem + '.part.mp4')
    try:
        cached.parent.mkdir(parents=True, exist_ok=True)
        streams = probe_media(path).get('streams', [])
        video = next((s for s in streams if s.get('codec_type') == 'video'), {})
        audio = next((s for s in streams if s.get('codec_type') == 'audio'), {})
        width = int(video.get('width') or 0)
        input_args = []
        vaapi = Path('/dev/dri/renderD128').exists() and os.access('/dev/dri/renderD128', os.R_OK | os.W_OK)
        if mode == 'compat' and vaapi:
            input_args = ['-vaapi_device', '/dev/dri/renderD128']
            video_args = ['-vf', 'format=nv12,hwupload,scale_vaapi=w=1920:h=-2', '-c:v', 'h264_vaapi', '-qp', '24']
        elif mode == 'compat':
            video_args = ['-vf', 'scale=-2:1080', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23']
        elif video.get('codec_name') in {'h264', 'hevc'}:
            video_args = ['-c:v', 'copy']
            if video.get('codec_name') == 'hevc': video_args += ['-tag:v', 'hvc1']
        else:
            video_args = ['-vf', 'scale=-2:1080', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23']
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
    if not playlist.is_file() and lock.acquire(blocking=False):
        directory.mkdir(parents=True, exist_ok=True)
        streams = probe_media(path).get('streams', [])
        video = next((s for s in streams if s.get('codec_type') == 'video'), {})
        width = int(video.get('width') or 0)
        vaapi = Path('/dev/dri/renderD128').exists() and os.access('/dev/dri/renderD128', os.R_OK | os.W_OK)
        if vaapi:
            video_args = ['-vf', 'format=nv12,hwupload,scale_vaapi=w=1920:h=-2', '-c:v', 'h264_vaapi', '-qp', '24']
            input_args = ['-vaapi_device', '/dev/dri/renderD128']
        else:
            video_args = ['-vf', 'scale=-2:1080', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23']
            input_args = []
        audio = next((s for s in streams if s.get('codec_type') == 'audio'), {})
        audio_args = ['-c:a', 'copy'] if audio.get('codec_name') == 'aac' else ['-c:a', 'aac']
        subprocess.Popen(['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error'] + input_args + ['-i', str(path), '-map', '0:v:0', '-map', '0:a?'] + video_args + audio_args + ['-f', 'hls', '-hls_time', '6', '-hls_list_size', '0', '-hls_flags', 'independent_segments+append_list', '-hls_segment_type', 'fmp4', '-hls_fmp4_init_filename', 'init.mp4', '-hls_segment_filename', str(directory / 'segment_%06d.m4s'), str(playlist)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        lock.release()
    if not playlist.is_file(): return Response('#EXTM3U\n#EXT-X-VERSION:7\n', mimetype='application/vnd.apple.mpegurl')
    return send_file(playlist, mimetype='application/vnd.apple.mpegurl', max_age=0)

@app.route('/hls/<path:filename>/<segment>')
def hls_segment(filename, segment):
    path = safe_path(filename)
    if not is_video(path) or not re.fullmatch(r'(?:init\.mp4|segment_\d{6}\.m4s)', segment): abort(404)
    target = hls_cache_dir(path) / segment
    if not target.is_file(): abort(404)
    return send_file(target, mimetype='video/mp4', max_age=3600)

def precache_loop():
    while True:
        for path in video_paths():
            if needs_transcode(path) and not transcode_cache_path(path).is_file():
                with app.test_request_context():
                    transcode(path.relative_to(MEDIA_ROOT).as_posix())
        time.sleep(PRECACHE_INTERVAL)

def start_precache_worker():
    threading.Thread(target=precache_loop, name='media-precache', daemon=True).start()

@app.route('/api/transcode-status/<path:filename>')
def transcode_status(filename):
    path = safe_path(filename)
    if not is_video(path): abort(404)
    mode = 'compat' if request.args.get('compat') == '1' else 'direct'
    cached = transcode_cache_path(path, mode)
    part = cached.with_name(cached.stem + '.part.mp4')
    if cached.is_file() and cached.stat().st_size:
        return jsonify(status='ready', bytes=cached.stat().st_size, percent=100, remaining=0)
    progress = transcode_progress_path(path, mode)
    values = {}
    if progress.is_file():
        for line in progress.read_text(errors='replace').splitlines():
            if '=' in line:
                key, value_text = line.split('=', 1); values[key] = value_text
    try: duration = float(probe_media(path).get('format', {}).get('duration') or 0)
    except (TypeError, ValueError): duration = 0
    try: encoded = float(values.get('out_time_ms', 0)) / 1_000_000
    except (TypeError, ValueError): encoded = 0
    try: speed = float(values.get('speed', '0x').rstrip('x'))
    except (TypeError, ValueError): speed = 0
    percent = min(99, encoded / duration * 100) if duration else 0
    remaining = max(0, (duration - encoded) / speed) if speed else None
    status = 'building' if progress.is_file() else 'partial' if part.is_file() else 'idle'
    return jsonify(status=status, bytes=part.stat().st_size if part.is_file() else 0, percent=percent, remaining=remaining)

@app.route('/api/progress',methods=['GET','POST'])
def progress():
    if request.method=='GET':
        filename=request.args.get('filename',''); path=safe_path(filename)
        if not is_video(path):abort(404)
        db=get_db();row=db.execute('SELECT position,duration FROM progress WHERE filename=?',(filename,)).fetchone();db.close();return jsonify(position=value(row,'position',0),duration=value(row,'duration',0))
    data=request.get_json(silent=True) or {};filename=data.get('filename','');path=safe_path(filename)
    if not is_video(path):abort(404)
    try:position=max(0,float(data.get('position',0)));duration=max(0,float(data.get('duration',0)))
    except (TypeError,ValueError):return jsonify(error='Invalid progress'),400
    if duration:position=min(position,duration)
    db=get_db();db.execute('INSERT INTO progress(filename,position,duration) VALUES(?,?,?) ON CONFLICT(filename) DO UPDATE SET position=excluded.position,duration=excluded.duration,updated_at=CURRENT_TIMESTAMP',(filename,position,duration));db.commit();db.close();return jsonify(success=True)
@app.route('/api/media-info/<path:filename>')
def media_info(filename):
    path=safe_path(filename)
    if not is_video(path):abort(404)
    probe_data=probe_media(path); format_data=probe_data.get('format',{})
    try: duration=float(format_data.get('duration') or 0)
    except (TypeError,ValueError): duration=0
    video_stream=next((s for s in probe_data.get('streams',[]) if s.get('codec_type')=='video'),{})
    probe=which('ffprobe'); return jsonify(container=path.suffix[1:].lower(),duration=duration,video_codec=video_stream.get('codec_name',''),direct_play=path.suffix.lower() in {'.mp4','.m4v','.webm'},ffprobe_available=bool(probe),transcoding_available=bool(which('ffmpeg')),reason='Codec inspection unavailable: install ffprobe for a precise compatibility report.' if not probe else 'Direct play is preferred; codec inspection can be extended without changing media files.')
@app.route('/manifest.webmanifest')
def manifest():return Response(json.dumps({'name':'My Movies','short_name':'Movies','start_url':'/','display':'standalone','background_color':'#090b10','theme_color':'#090b10','icons':[{'src':'/icon.svg','sizes':'any','type':'image/svg+xml'}]}),mimetype='application/manifest+json')
@app.route('/icon.svg')
def icon():return Response('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128"><rect width="128" height="128" rx="24" fill="#e50914"/><path fill="white" d="M43 31h42v66H43zm11 17v32l27-16z"/></svg>',mimetype='image/svg+xml')
@app.route('/sw.js')
def sw():return Response("self.addEventListener('install',e=>self.skipWaiting());self.addEventListener('activate',e=>clients.claim());",mimetype='application/javascript',headers={'Service-Worker-Allowed':'/'})
@app.errorhandler(404)
def missing(_):return render_template_string(ERROR_HTML,code=404,message='That media item is unavailable or has moved.'),404
@app.errorhandler(403)
def denied(_):return render_template_string(ERROR_HTML,code=403,message='That location is not available.'),403

CSS='''*{box-sizing:border-box}body{margin:0;background:#090b10;color:#f7f7f8;font:16px system-ui,-apple-system,sans-serif}header{position:sticky;top:0;z-index:4;display:flex;justify-content:space-between;gap:1rem;padding:1rem max(1rem,calc((100% - 1260px)/2));background:#090b10ed;backdrop-filter:blur(12px)}header b{white-space:nowrap;font-size:1.2rem}form{display:flex;gap:.5rem;width:100%;max-width:38rem}input,select,button{font:inherit}header input{width:100%;background:#181a21;color:#fff;border:1px solid #30333d;border-radius:.55rem;padding:.6rem .8rem}header select{background:#181a21;color:#fff;border:1px solid #30333d;border-radius:.55rem}main{max-width:1260px;margin:auto;padding:1.5rem 1rem 4rem}section{margin-bottom:2.5rem}h2{font-size:1.25rem}.grid,.rail{display:grid;grid-template-columns:repeat(auto-fill,minmax(145px,1fr));gap:1rem}.rail{display:flex;overflow:auto;padding-bottom:.5rem}.rail .card{min-width:145px}.card{color:inherit;text-decoration:none}.art{aspect-ratio:2/3;background:#191b22;border-radius:.6rem;overflow:hidden;position:relative;box-shadow:0 5px 20px #0005}.art img{height:100%;width:100%;object-fit:cover}.fallback{height:100%;display:grid;place-items:center;color:#8a8f9e;font-size:2.5rem}.bar{height:4px;background:#343641;position:absolute;bottom:0;left:0;right:0}.bar i{display:block;height:100%;background:#e50914}.name{font-weight:650;font-size:.9rem;margin-top:.5rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.year,.empty,.facts{color:#a8acb9;font-size:.84rem}.back{color:#fff;text-decoration:none;display:inline-block;margin-bottom:1.5rem}.backdrop{position:absolute;z-index:-1;inset:0 0 auto;height:min(65vw,650px);background-size:cover;background-position:center}.detail-grid{display:grid;grid-template-columns:minmax(160px,260px) 1fr;gap:2rem}.detail-grid .art{width:100%}h1{font-size:clamp(2rem,5vw,3.7rem);line-height:1.05;margin:.1rem 0 .7rem}.chips{display:flex;gap:.45rem;flex-wrap:wrap}.chips span{background:#262936;border-radius:99px;padding:.3rem .6rem;font-size:.85rem}.overview{max-width:48rem;line-height:1.65}.actions{display:flex;gap:1rem;align-items:center;flex-wrap:wrap}.primary{padding:.75rem 1.2rem;border-radius:.55rem;background:#e50914;color:#fff;text-decoration:none;font-weight:700}.watch{background:#000}.watch-back{position:fixed;z-index:3;top:1rem;left:1rem;color:#fff;text-decoration:none;text-shadow:0 1px 4px #000}#shell{height:100vh;display:grid;place-items:center;position:relative}video{width:100%;max-height:100%;background:#000}#controls{position:absolute;inset:auto 0 0;padding:2rem 1rem 1rem;background:linear-gradient(transparent,#000d);opacity:0;transition:.2s}#shell.show #controls{opacity:1}#seek{display:block;width:100%;accent-color:#e50914}#controls>div{display:flex;gap:.6rem;align-items:center;margin-top:.5rem}#controls button,#controls select{background:#222;color:#fff;border:0;border-radius:.3rem;padding:.35rem .55rem}#volume{width:90px}#center{position:absolute;border:0;border-radius:50%;width:4rem;height:4rem;background:#0009;color:#fff;font-size:1.5rem}@media(max-width:600px){.grid{grid-template-columns:repeat(auto-fill,minmax(110px,1fr));gap:.75rem}.detail-grid{grid-template-columns:120px 1fr;gap:1rem}.overview,.actions{grid-column:1/-1}#volume{display:none}#controls{padding:.8rem}#controls>div{gap:.3rem}}'''
LIBRARY_HTML='''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="theme-color" content="#090b10"><link rel="manifest" href="/manifest.webmanifest"><style>{{css}}</style><header><b>◉ My Movies</b><form><input name="q" value="{{q}}" placeholder="Search your library"><select name="sort" onchange="this.form.submit()"><option value="title" {%if sort=='title'%}selected{%endif%}>A–Z</option><option value="recent" {%if sort=='recent'%}selected{%endif%}>Recently watched</option></select></form></header><main>{%if watching%}<section><h2>Continue watching</h2><div class="rail">{%for m in watching%}{{card(m)|safe}}{%endfor%}</div></section>{%endif%}<section><h2>{%if q%}Results for “{{q}}”{%else%}All movies{%endif%}</h2>{%if movies%}<div class="grid">{%for m in movies%}{{card(m)|safe}}{%endfor%}</div>{%else%}<p class="empty">No movies found.</p>{%endif%}</section></main><script>if('serviceWorker'in navigator)navigator.serviceWorker.register('/sw.js')</script>'''
DETAILS_HTML='''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>{{css}}</style>{%if backdrop%}<div class="backdrop" style="background-image:linear-gradient(90deg,#090b10 10%,transparent),linear-gradient(0deg,#090b10,transparent 60%),url('{{url_for('tmdb_backdrop',tmdb_id=backdrop)}}')"></div>{%endif%}<main><a class="back" href="/">← Library</a><div class="detail-grid">{{poster(movie)|safe}}<div><h1>{{movie.title}}</h1><p class="facts">{{movie.release_date or movie.year}}{%if movie.runtime%} · {{movie.runtime}} min{%endif%}{%if movie.rating%} · ★ {{'%.1f'|format(movie.rating)}}/10{%endif%}</p>{%if movie.genres%}<div class="chips">{%for g in movie.genres.split(', ')%}<span>{{g}}</span>{%endfor%}</div>{%endif%}<p class="overview">{{movie.overview or 'No synopsis is available for this title.'}}</p><div class="actions"><a class="primary" href="{{url_for('watch',filename=movie.filename)}}">▶ {%if movie.position>10%}Resume{%else%}Play{%endif%}</a>{%if movie.position>10%}<span>Watched {{movie.percent|round|int}}%</span>{%endif%}</div></div></div></main>'''
PLAYER_HTML='''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><style>{{css}}</style><div id="shell" class="show"><video id="video" playsinline preload="metadata"><source src="{{url_for('media',filename=movie.filename)}}">{%for t in tracks%}<track kind="subtitles" label="{{t.label}}" srclang="{{t.lang}}" src="{{url_for('subtitle',filename=movie.filename,name=t.name)}}">{%endfor%}</video><button id="center">▶</button><div id="controls"><input id="seek" type="range" min="0" max="100" value="0"><div><button id="play">▶</button><span id="time">0:00 / 0:00</span><button id="mute">🔊</button><input id="volume" type="range" min="0" max="1" step=".05" value="1"><select id="speed"><option>.75×</option><option selected>1×</option><option>1.25×</option><option>1.5×</option><option>2×</option></select>{%if tracks%}<select id="subs"><option value="-1">Subtitles off</option>{%for t in tracks%}<option value="{{loop.index0}}">{{t.label}}</option>{%endfor%}</select>{%endif%}<button id="full">⛶</button></div></div></div><a class="watch-back" href="{{url_for('details',filename=movie.filename)}}">← {{movie.title}}</a><script>const filename={{movie.filename|tojson}},v=document.querySelector('#video'),shell=document.querySelector('#shell'),seek=document.querySelector('#seek'),play=document.querySelector('#play'),center=document.querySelector('#center'),timeEl=document.querySelector('#time');let last=0,t;const fmt=s=>{s=Math.floor(s||0);return(s>3599?Math.floor(s/3600)+':':'')+String(Math.floor(s%3600/60)).padStart(s>3599?2:1,'0')+':'+String(s%60).padStart(2,'0')};function toggle(){v.paused?v.play():v.pause()}function save(){if(v.duration)fetch('/api/progress',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({filename,position:v.ended?0:v.currentTime,duration:v.duration}),keepalive:true})}function show(){shell.classList.add('show');clearTimeout(t);if(!v.paused)t=setTimeout(()=>shell.classList.remove('show'),2500)}play.onclick=toggle;center.onclick=toggle;v.onclick=toggle;v.onplay=()=>{play.textContent='❚❚';center.hidden=true;show()};v.onpause=()=>{play.textContent='▶';center.hidden=false;save();show()};v.ontimeupdate=()=>{seek.value=v.duration?v.currentTime/v.duration*100:0;timeEl.textContent=fmt(v.currentTime)+' / '+fmt(v.duration);if(v.currentTime-last>10){last=v.currentTime;save()}};v.onended=save;seek.oninput=()=>{if(v.duration)v.currentTime=seek.value/100*v.duration};mute.onclick=()=>v.muted=!v.muted;volume.oninput=e=>{v.volume=e.target.value;v.muted=false};speed.onchange=e=>v.playbackRate=parseFloat(e.target.value);full.onclick=()=>shell.requestFullscreen?.();{%if tracks%}subs.onchange=e=>[...v.textTracks].forEach((x,i)=>x.mode=i==e.target.value?'showing':'disabled');{%endif%}document.onkeydown=e=>{if(e.target.matches('input,select'))return;if(e.code==='Space'){e.preventDefault();toggle()}if(e.code==='ArrowRight')v.currentTime+=5;if(e.code==='ArrowLeft')v.currentTime-=5;if(e.key==='f')full.click();show()};fetch('/api/progress?filename='+encodeURIComponent(filename)).then(r=>r.json()).then(p=>{if(p.position>10&&p.duration&&p.position<p.duration-10)v.addEventListener('loadedmetadata',()=>v.currentTime=p.position,{once:true})});shell.onmousemove=show;shell.ontouchstart=show;addEventListener('pagehide',save)</script>'''
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
PLAYER_HTML = PLAYER_HTML.replace(
    '</script>',
    ''';let mediaDuration=0;const timelineDuration=()=>mediaDuration||v.duration,source=document.querySelector('#source'),playbackError=document.querySelector('#playbackError');
v.addEventListener('error',()=>{if(source.dataset.transcoded==='remux'){source.dataset.transcoded='compat';cacheStatus.hidden=false;cacheMessage.textContent='Switching to hardware-compatible playback...';clearInterval(cacheTimer);cacheTimer=setInterval(()=>fetch('/api/transcode-status/'+encodeURIComponent(filename)+'?compat=1').then(r=>r.json()).then(s=>{if(s.status==='building'){cacheBar.style.animation='none';cacheBar.style.width=Math.max(2,s.percent)+'%';cacheMessage.textContent='Preparing hardware-compatible playback · '+s.percent.toFixed(0)+'% · '+formatEta(s.remaining)+' · '+formatBytes(s.bytes)+' ready';}}),1000);source.src='/transcode/'+filename.split('/').map(encodeURIComponent).join('/')+'?compat=1';v.load();v.play().catch(()=>{})}else if(!source.dataset.transcoded){fetch('/api/media-info/'+encodeURIComponent(filename)).then(r=>r.json()).then(info=>{if(info.transcoding_available){source.dataset.transcoded='compat';source.src='/transcode/'+filename.split('/').map(encodeURIComponent).join('/')+'?compat=1';v.load();v.play().catch(()=>{playbackError.hidden=false;playbackError.textContent='This video could not start after conversion.'})}else{playbackError.hidden=false;playbackError.textContent='This format is not supported by this browser. Install FFmpeg on the server to enable compatibility playback.'}}).catch(()=>{playbackError.hidden=false;playbackError.textContent='Playback failed. Check this media file and server connection.'})}});''' + '</script>'
)
PLAYER_HTML = PLAYER_HTML.replace(
    '</script>',
    "fetch('/api/media-info/'+encodeURIComponent(filename)).then(r=>r.json()).then(info=>{mediaDuration=Number(info.duration)||0;const d=timelineDuration();if(d)timeEl.textContent=fmt(v.currentTime)+' / '+fmt(d)});v.addEventListener('timeupdate',()=>{const d=timelineDuration();if(d){seek.value=v.currentTime/d*100;timeEl.textContent=fmt(v.currentTime)+' / '+fmt(d)}});seek.oninput=()=>{const d=timelineDuration();if(d)v.currentTime=seek.value/100*d}</script>"
)
PLAYER_HTML = PLAYER_HTML.replace(
    ';let mediaDuration=0;const timelineDuration=()=>mediaDuration||v.duration,source=document.querySelector(\'#source\'),playbackError=document.querySelector(\'#playbackError\');',
    ";let mediaDuration=0,cacheTimer;const timelineDuration=()=>mediaDuration||v.duration,source=document.querySelector('#source'),playbackError=document.querySelector('#playbackError'),cacheStatus=document.querySelector('#cacheStatus'),cacheMessage=document.querySelector('#cacheMessage'),cacheBar=document.querySelector('#cacheStatus b'),formatBytes=n=>n<1048576?Math.round(n/1024)+' KB':(n/1048576).toFixed(0)+' MB',formatEta=s=>{if(s==null)return 'calculating time';s=Math.max(0,Math.round(s));return s>=3600?Math.floor(s/3600)+'h '+Math.floor(s%3600/60)+'m remaining':Math.floor(s/60)+'m '+String(s%60).padStart(2,'0')+'s remaining'};v.addEventListener('loadedmetadata',()=>{if(source.dataset.transcoded!=='compat'){cacheStatus.hidden=true;clearInterval(cacheTimer)}if(source.dataset.transcoded==='compat')v.play().catch(()=>{})});const startSource=mode=>{source.dataset.transcoded=mode;source.src='/transcode/'+filename.split('/').map(encodeURIComponent).join('/')+(mode==='compat'?'?compat=1':'');v.load()};if(!/\\.(mp4|m4v|webm)$/i.test(filename)){fetch('/api/media-info/'+encodeURIComponent(filename)).then(r=>r.json()).then(info=>{const hevcUnsupported=info.video_codec==='hevc';if(hevcUnsupported){cacheStatus.hidden=false;cacheTimer=setInterval(()=>fetch('/api/transcode-status/'+encodeURIComponent(filename)+'?compat=1').then(r=>r.json()).then(s=>{if(s.status==='building'){cacheBar.style.animation='none';cacheBar.style.width=Math.max(2,s.percent)+'%';cacheMessage.textContent=s.percent>=99?'Finalizing cached video...':'Preparing hardware-compatible playback · '+s.percent.toFixed(0)+'% · '+formatEta(s.remaining)+' · '+formatBytes(s.bytes)+' ready';}}),1000);startSource('compat')}else{startSource('remux')}})}"
)
PLAYER_HTML = PLAYER_HTML.replace(
    'const startSource=mode=>{',
    "const startHls=()=>{source.dataset.transcoded='hls';cacheStatus.hidden=false;cacheMessage.textContent='Preparing segmented playback...';const playlist='/hls/'+filename.split('/').map(encodeURIComponent).join('/')+'/playlist.m3u8';if(v.canPlayType('application/vnd.apple.mpegurl')){source.src=playlist;v.load();return}const script=document.createElement('script');script.src='https://cdn.jsdelivr.net/npm/hls.js@1';script.onload=()=>{if(window.Hls&&Hls.isSupported()){const hls=new Hls({lowLatencyMode:false});hls.loadSource(playlist);hls.attachMedia(v);hls.on(Hls.Events.MANIFEST_PARSED,()=>v.play().catch(()=>{}))}else{playbackError.hidden=false;playbackError.textContent='This browser cannot play HLS video.'}};document.head.appendChild(script)};const startSource=mode=>{"
)
PLAYER_HTML = PLAYER_HTML.replace("startSource('compat')", 'startHls()')
PLAYER_HTML = PLAYER_HTML.replace('<p id="playbackError" hidden></p>', '')
PLAYER_HTML = PLAYER_HTML.replace(
    '</video><button id="center">',
    '</video><p id="playbackError" hidden></p><div id="cacheStatus" hidden><strong>Preparing video</strong><span id="cacheMessage">Converting for browser playback...</span><i><b></b></i></div><button id="center">',
)
ERROR_HTML='''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font:16px system-ui;background:#090b10;color:#fff;display:grid;place-items:center;min-height:100vh;margin:0}main{text-align:center;padding:2rem}a{color:#fff}</style><main><h1>{{code}}</h1><p>{{message}}</p><a href="/">Back to library</a></main>'''
CSS += '#playbackError{position:absolute;z-index:2;max-width:28rem;padding:1rem;background:#1b1c22e8;border:1px solid #555;border-radius:.5rem;text-align:center;line-height:1.4}#cacheStatus{position:absolute;z-index:3;left:50%;top:50%;transform:translate(-50%,-50%);width:min(90vw,28rem);padding:1.25rem 1.35rem;background:#11141beF;border:1px solid #3b414e;border-radius:.8rem;box-shadow:0 1rem 3rem #0008}#cacheStatus strong,#cacheStatus span{display:block}#cacheStatus strong{font-size:1.05rem}#cacheStatus span{margin-top:.35rem;color:#b7bdc9;font-size:.85rem}#cacheStatus i{display:block;height:.35rem;margin-top:1rem;overflow:hidden;background:#303641;border-radius:99px}#cacheStatus b{display:block;width:38%;height:100%;background:#e50914;border-radius:inherit;animation:cacheProgress 1.25s ease-in-out infinite}@keyframes cacheProgress{0%{transform:translateX(-110%)}100%{transform:translateX(290%)}}'
@app.context_processor
def helpers():
    def poster(m):
        if m['poster']:
            src=url_for('tmdb_poster',tmdb_id=m['tmdb_id']) if m['poster'].startswith('tmdb:') else url_for('poster',filename=m['poster'][6:]);return f'<div class="art"><img src="{escape(src)}" alt="" loading="lazy"></div>'
        return '<div class="art"><div class="fallback">◉</div></div>'
    def card(m):return f'<a class="card" href="{escape(url_for("details",filename=m["filename"]))}">{poster(m)}<div class="bar"><i style="width:{m["percent"]:.2f}%"></i></div><div class="name">{escape(m["title"])}</div><div class="year">{escape(m["year"] or "")}</div></a>'
    return dict(css=CSS,poster=poster,card=card)
if __name__=='__main__':
    MEDIA_ROOT.mkdir(parents=True,exist_ok=True);POSTER_CACHE.mkdir(parents=True,exist_ok=True);BACKDROP_CACHE.mkdir(parents=True,exist_ok=True);init_db();start_precache_worker();app.run(host='0.0.0.0',port=int(os.environ.get('PORT',8000)),debug=False)
