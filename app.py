"""LAN-first Flask media server."""
import json, logging, mimetypes, os, re, sqlite3, time
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
    if time.monotonic()-_paths[0] > 30: _paths=(time.monotonic(),sorted((p for p in MEDIA_ROOT.rglob('*') if is_video(p)),key=lambda p:p.name.lower()) if MEDIA_ROOT.exists() else [])
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
    probe=which('ffprobe'); return jsonify(container=path.suffix[1:].lower(),direct_play=path.suffix.lower() in {'.mp4','.m4v','.webm'},ffprobe_available=bool(probe),transcoding_available=bool(which('ffmpeg')),reason='Codec inspection unavailable: install ffprobe for a precise compatibility report.' if not probe else 'Direct play is preferred; codec inspection can be extended without changing media files.')
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
PLAYER_HTML = PLAYER_HTML.replace(
    'full.onclick=()=>shell.requestFullscreen?.();',
    'full.onclick=()=>document.fullscreenElement?document.exitFullscreen?.():shell.requestFullscreen?.();',
)
ERROR_HTML='''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font:16px system-ui;background:#090b10;color:#fff;display:grid;place-items:center;min-height:100vh;margin:0}main{text-align:center;padding:2rem}a{color:#fff}</style><main><h1>{{code}}</h1><p>{{message}}</p><a href="/">Back to library</a></main>'''
@app.context_processor
def helpers():
    def poster(m):
        if m['poster']:
            src=url_for('tmdb_poster',tmdb_id=m['tmdb_id']) if m['poster'].startswith('tmdb:') else url_for('poster',filename=m['poster'][6:]);return f'<div class="art"><img src="{escape(src)}" alt="" loading="lazy"></div>'
        return '<div class="art"><div class="fallback">◉</div></div>'
    def card(m):return f'<a class="card" href="{escape(url_for("details",filename=m["filename"]))}">{poster(m)}<div class="bar"><i style="width:{m["percent"]:.2f}%"></i></div><div class="name">{escape(m["title"])}</div><div class="year">{escape(m["year"] or "")}</div></a>'
    return dict(css=CSS,poster=poster,card=card)
if __name__=='__main__':
    MEDIA_ROOT.mkdir(parents=True,exist_ok=True);POSTER_CACHE.mkdir(parents=True,exist_ok=True);BACKDROP_CACHE.mkdir(parents=True,exist_ok=True);init_db();app.run(host='0.0.0.0',port=int(os.environ.get('PORT',8000)),debug=False)
