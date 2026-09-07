import re
import sqlite3
from pathlib import Path

from flask import (
    Flask,
    abort,
    jsonify,
    render_template_string,
    request,
    send_from_directory,
)

app = Flask(__name__)

MEDIA_ROOT = Path("/home/iamroot/Media/Movies").resolve()
BASE_DIR = Path("/home/iamroot/media-server").resolve()
DATABASE = BASE_DIR / "media.db"
POSTER_CACHE = BASE_DIR / "cache" / "posters"

VIDEO_EXTENSIONS = {
    ".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v"
}

POSTER_EXTENSIONS = [".jpg", ".jpeg", ".png", ".webp"]


# ---------------------------------------------------------
# Database
# ---------------------------------------------------------

def get_db():
    db = sqlite3.connect(DATABASE)
    db.row_factory = sqlite3.Row
    return db


def init_db():
    db = get_db()
    db.execute("""
        CREATE TABLE IF NOT EXISTS progress (
            filename TEXT PRIMARY KEY,
            position REAL NOT NULL DEFAULT 0,
            duration REAL NOT NULL DEFAULT 0,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    """)
    db.commit()
    db.close()


# ---------------------------------------------------------
# Security
# ---------------------------------------------------------

def safe_path(relative_path):
    target = (MEDIA_ROOT / relative_path).resolve()

    try:
        target.relative_to(MEDIA_ROOT)
    except ValueError:
        abort(403)

    return target


# ---------------------------------------------------------
# Movie helpers
# ---------------------------------------------------------

def is_video(path):
    return path.is_file() and path.suffix.lower() in VIDEO_EXTENSIONS


def clean_title(filename):
    title = Path(filename).stem

    title = re.sub(r"[._]+", " ", title)

    title = re.sub(
        r"\b(2160p|1080p|720p|480p|4K|8K)\b",
        "",
        title,
        flags=re.IGNORECASE,
    )

    title = re.sub(
        r"\b(BluRay|WEBRip|WEB-DL|WEB|HDR|REMUX|x264|x265|HEVC)\b",
        "",
        title,
        flags=re.IGNORECASE,
    )

    title = re.sub(r"\s+\(\s*(\d{4})\s*\)", r" (\1)", title)
    title = re.sub(r"\s{2,}", " ", title)

    return title.strip()


def find_poster(video_path):
    """Find an old-style poster stored beside the video."""
    candidates = []

    for ext in POSTER_EXTENSIONS:
        candidates.append(video_path.with_suffix(ext))

    for ext in POSTER_EXTENSIONS:
        candidates.append(video_path.parent / f"poster{ext}")

    for candidate in candidates:
        if candidate.is_file():
            return candidate

    return None


def row_value(row, key, default=None):
    """Safely read a column from a sqlite3.Row."""
    if row is None:
        return default
    try:
        return row[key] if row[key] is not None else default
    except (IndexError, KeyError):
        return default


def build_movie(path, db):
    relative = path.relative_to(MEDIA_ROOT).as_posix()

    progress = db.execute(
        """
        SELECT position, duration
        FROM progress
        WHERE filename = ?
        """,
        (relative,),
    ).fetchone()

    position = 0
    duration = 0
    percent = 0

    if progress:
        position = progress["position"]
        duration = progress["duration"]

        if duration > 0:
            percent = min(100, (position / duration) * 100)

    # Metadata comes from scanner.py.
    metadata = None
    try:
        metadata = db.execute(
            "SELECT * FROM movies WHERE filename = ?",
            (relative,),
        ).fetchone()
    except sqlite3.OperationalError:
        # The app can still work if the metadata table hasn't been created.
        metadata = None

    title = row_value(metadata, "title", clean_title(path.name))
    year = row_value(metadata, "year", "")
    tmdb_id = row_value(metadata, "tmdb_id")
    overview = row_value(metadata, "overview", "")
    rating = row_value(metadata, "vote_average", None)
    runtime = row_value(metadata, "runtime", None)
    genres = row_value(metadata, "genres", "")
    release_date = row_value(metadata, "release_date", "")
    backdrop_path = row_value(metadata, "backdrop_path", "")

    # Prefer the downloaded TMDB poster.
    poster = None
    if tmdb_id:
        cached = POSTER_CACHE / f"{tmdb_id}.jpg"
        if cached.is_file():
            poster = f"tmdb:{tmdb_id}"

    # Fall back to a local sidecar poster.
    if not poster:
        sidecar = find_poster(path)
        if sidecar:
            poster = "local:" + sidecar.relative_to(MEDIA_ROOT).as_posix()

    return {
        "filename": relative,
        "title": title,
        "year": year,
        "tmdb_id": tmdb_id,
        "overview": overview,
        "rating": rating,
        "runtime": runtime,
        "genres": genres,
        "release_date": release_date,
        "backdrop_path": backdrop_path,
        "poster": poster,
        "position": position,
        "duration": duration,
        "percent": percent,
    }


def get_movies():
    db = get_db()
    movies = []

    for path in MEDIA_ROOT.rglob("*"):
        if is_video(path):
            movies.append(build_movie(path, db))

    db.close()

    movies.sort(key=lambda movie: movie["title"].lower())
    return movies


# ---------------------------------------------------------
# Poster serving
# ---------------------------------------------------------

@app.route("/poster/<path:filename>")
def poster(filename):
    path = safe_path(filename)

    if not path.is_file():
        abort(404)

    return send_from_directory(
        MEDIA_ROOT,
        filename,
        conditional=True,
    )


@app.route("/tmdb-poster/<int:tmdb_id>")
def tmdb_poster(tmdb_id):
    filename = f"{tmdb_id}.jpg"
    path = POSTER_CACHE / filename

    if not path.is_file():
        abort(404)

    return send_from_directory(
        POSTER_CACHE,
        filename,
        conditional=True,
    )


# ---------------------------------------------------------
# Library page
# ---------------------------------------------------------

LIBRARY_HTML = """
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>My Movies</title>
<style>
* { box-sizing: border-box; }
body {
    margin: 0;
    background: #0f0f0f;
    color: #fff;
    font-family: system-ui, -apple-system, BlinkMacSystemFont, sans-serif;
}
.header {
    position: sticky;
    top: 0;
    z-index: 20;
    background: rgba(15,15,15,.96);
    backdrop-filter: blur(12px);
    padding: 18px 20px;
    border-bottom: 1px solid #222;
}
.header-row {
    max-width: 1300px;
    margin: auto;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 15px;
}
.logo { font-size: 22px; font-weight: 800; }
.search {
    width: 100%;
    max-width: 420px;
    padding: 11px 14px;
    border: 1px solid #333;
    border-radius: 10px;
    background: #1c1c1c;
    color: #fff;
    font-size: 15px;
    outline: none;
}
.search:focus { border-color: #666; }
.container {
    max-width: 1300px;
    margin: auto;
    padding: 25px 20px 60px;
}
.section { margin-top: 35px; }
.section:first-child { margin-top: 0; }
.section-title {
    font-size: 21px;
    font-weight: 750;
    margin-bottom: 15px;
}
.grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(145px, 1fr));
    gap: 18px;
}
.card { position: relative; min-width: 0; }
.card a { color: white; text-decoration: none; }
.poster {
    position: relative;
    width: 100%;
    aspect-ratio: 2 / 3;
    border-radius: 10px;
    overflow: hidden;
    background: #222;
    box-shadow: 0 5px 20px rgba(0,0,0,.3);
    transition: transform .15s ease;
}
.poster img {
    width: 100%;
    height: 100%;
    object-fit: cover;
}
.poster-placeholder {
    width: 100%;
    height: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 48px;
}
.card:hover .poster { transform: translateY(-3px); }
.title {
    margin-top: 9px;
    font-size: 14px;
    font-weight: 650;
    line-height: 1.3;
    word-break: break-word;
}
.year { color: #999; font-size: 13px; margin-top: 2px; }
.progress {
    position: absolute;
    left: 0;
    right: 0;
    bottom: 0;
    height: 4px;
    background: #333;
}
.progress-bar { height: 100%; background: #e50914; }
.empty { color: #999; padding: 30px 0; }
@media (max-width: 600px) {
    .header-row { flex-direction: column; align-items: stretch; }
    .search { max-width: none; }
    .grid {
        grid-template-columns: repeat(auto-fill, minmax(110px, 1fr));
        gap: 13px;
    }
}
</style>
</head>
<body>
<header class="header">
<div class="header-row">
<div class="logo">🎬 My Movies</div>
<form method="get" style="flex:1;display:flex;justify-content:flex-end;">
<input class="search" name="q" type="search"
       placeholder="Search movies..." value="{{ query }}">
</form>
</div>
</header>

<main class="container">
{% if continue_watching %}
<section class="section">
<div class="section-title">Continue Watching</div>
<div class="grid">
{% for movie in continue_watching %}
<div class="card">
<a href="{{ url_for('movie_details', filename=movie.filename) }}">
<div class="poster">
{% if movie.poster %}
{% if movie.poster.startswith('tmdb:') %}
<img src="{{ url_for('tmdb_poster', tmdb_id=movie.tmdb_id) }}" loading="lazy">
{% else %}
<img src="{{ url_for('poster', filename=movie.poster[6:]) }}" loading="lazy">
{% endif %}
{% else %}
<div class="poster-placeholder">🎬</div>
{% endif %}
<div class="progress"><div class="progress-bar" style="width: {{ movie.percent }}%"></div></div>
</div>
<div class="title">{{ movie.title }}</div>
{% if movie.year %}<div class="year">{{ movie.year }}</div>{% endif %}
</a>
</div>
{% endfor %}
</div>
</section>
{% endif %}

<section class="section">
<div class="section-title">{% if query %}Search results{% else %}All Movies{% endif %}</div>
{% if movies %}
<div class="grid">
{% for movie in movies %}
<div class="card">
<a href="{{ url_for('movie_details', filename=movie.filename) }}">
<div class="poster">
{% if movie.poster %}
{% if movie.poster.startswith('tmdb:') %}
<img src="{{ url_for('tmdb_poster', tmdb_id=movie.tmdb_id) }}" loading="lazy">
{% else %}
<img src="{{ url_for('poster', filename=movie.poster[6:]) }}" loading="lazy">
{% endif %}
{% else %}
<div class="poster-placeholder">🎬</div>
{% endif %}
{% if movie.percent > 0 %}
<div class="progress"><div class="progress-bar" style="width: {{ movie.percent }}%"></div></div>
{% endif %}
</div>
<div class="title">{{ movie.title }}</div>
{% if movie.year %}<div class="year">{{ movie.year }}</div>{% endif %}
</a>
</div>
{% endfor %}
</div>
{% else %}
<div class="empty">No movies found.</div>
{% endif %}
</section>
</main>
</body>
</html>
"""


@app.route("/")
def home():
    query = request.args.get("q", "").strip().lower()

    movies = get_movies()

    continue_watching = [
        movie for movie in movies
        if movie["position"] > 10
        and (
            movie["duration"] == 0
            or movie["position"] < movie["duration"] - 10
        )
    ]

    continue_watching.sort(
        key=lambda movie: movie["position"],
        reverse=True,
    )

    if query:
        movies = [
            movie for movie in movies
            if query in movie["title"].lower()
        ]

    return render_template_string(
        LIBRARY_HTML,
        movies=movies,
        continue_watching=continue_watching,
        query=query,
    )


# ---------------------------------------------------------
# Movie details page
# ---------------------------------------------------------

DETAILS_HTML = """
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ movie.title }}</title>
<style>
* { box-sizing: border-box; }
body {
    margin: 0;
    background: #0b0b0b;
    color: white;
    font-family: system-ui, -apple-system, BlinkMacSystemFont, sans-serif;
}
.page { max-width: 1100px; margin: auto; padding: 20px; }
.back { color: #aaa; text-decoration: none; display: inline-block; margin-bottom: 22px; }
.hero {
    display: grid;
    grid-template-columns: 260px 1fr;
    gap: 30px;
    align-items: start;
}
.poster {
    width: 100%;
    aspect-ratio: 2 / 3;
    object-fit: cover;
    border-radius: 12px;
    background: #222;
    box-shadow: 0 10px 40px rgba(0,0,0,.45);
}
.info h1 { margin: 0 0 8px; font-size: 34px; line-height: 1.1; }
.meta { color: #aaa; margin: 8px 0 18px; }
.rating { margin: 14px 0; font-weight: 650; }
.overview { color: #d0d0d0; font-size: 16px; line-height: 1.6; }
.play {
    display: inline-block;
    margin-top: 22px;
    padding: 12px 22px;
    border-radius: 9px;
    background: #e50914;
    color: white;
    text-decoration: none;
    font-weight: 700;
}
@media (max-width: 650px) {
    .hero { grid-template-columns: 140px 1fr; gap: 18px; }
    .info h1 { font-size: 24px; }
    .overview { font-size: 14px; }
}
</style>
</head>
<body>
<div class="page">
<a class="back" href="{{ url_for('home') }}">← My Movies</a>
<div class="hero">
{% if movie.poster %}
{% if movie.poster.startswith('tmdb:') %}
<img class="poster" src="{{ url_for('tmdb_poster', tmdb_id=movie.tmdb_id) }}">
{% else %}
<img class="poster" src="{{ url_for('poster', filename=movie.poster[6:]) }}">
{% endif %}
{% else %}
<div class="poster"></div>
{% endif %}

<div class="info">
<h1>{{ movie.title }}</h1>
<div class="meta">
{% if movie.year %}{{ movie.year }}{% endif %}
{% if movie.runtime %} · {{ movie.runtime }} min{% endif %}
</div>
{% if movie.rating %}<div class="rating">⭐ {{ "%.1f"|format(movie.rating) }}/10</div>{% endif %}
{% if movie.genres %}<div class="meta">{{ movie.genres }}</div>{% endif %}
{% if movie.overview %}<div class="overview">{{ movie.overview }}</div>{% endif %}
<a class="play" href="{{ url_for('watch', filename=movie.filename) }}">▶ Play</a>
</div>
</div>
</div>
</body>
</html>
"""


@app.route("/movie/<path:filename>")
def movie_details(filename):
    path = safe_path(filename)

    if not is_video(path):
        abort(404)

    db = get_db()
    movie = build_movie(path, db)
    db.close()

    return render_template_string(
        DETAILS_HTML,
        movie=movie,
    )


# ---------------------------------------------------------
# Player
# ---------------------------------------------------------

PLAYER_HTML = """
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ movie.title }}</title>
<style>
body { margin: 0; background: #000; color: white; font-family: system-ui; }
.header { padding: 15px 18px; background: #111; }
.back { color: #aaa; text-decoration: none; }
.title { margin-top: 8px; font-weight: 650; word-break: break-word; }
.player {
    width: 100%;
    min-height: calc(100vh - 100px);
    display: flex;
    align-items: center;
    justify-content: center;
    background: black;
}
video { width: 100%; max-height: calc(100vh - 100px); background: black; }
.resume {
    position: fixed;
    z-index: 50;
    left: 50%;
    bottom: 30px;
    transform: translateX(-50%);
    width: min(90%, 360px);
    padding: 18px;
    border-radius: 14px;
    background: rgba(30,30,30,.96);
    box-shadow: 0 10px 40px rgba(0,0,0,.6);
    text-align: center;
}
.resume-buttons { margin-top: 12px; }
button {
    border: 0;
    border-radius: 8px;
    padding: 10px 16px;
    margin: 4px;
    font-size: 15px;
    cursor: pointer;
}
.resume-btn { background: #e50914; color: white; }
</style>
</head>
<body>
<div class="header">
<a class="back" href="{{ url_for('movie_details', filename=movie.filename) }}">← {{ movie.title }}</a>
</div>
<div class="player">
<video id="video" controls playsinline preload="metadata">
<source src="{{ url_for('media', filename=movie.filename) }}">
Your browser cannot play this video.
</video>
</div>
<div id="resumeBox" class="resume" style="display:none;">
<div>Resume from <strong id="resumeTime"></strong>?</div>
<div class="resume-buttons">
<button id="resumeButton" class="resume-btn">Resume</button>
<button id="startButton">Start over</button>
</div>
</div>
<script>
const video = document.getElementById("video");
const resumeBox = document.getElementById("resumeBox");
const resumeButton = document.getElementById("resumeButton");
const startButton = document.getElementById("startButton");
const resumeTime = document.getElementById("resumeTime");
const filename = {{ movie.filename | tojson }};
let savedPosition = 0;

function formatTime(seconds) {
    seconds = Math.floor(seconds);
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    const secs = seconds % 60;
    if (hours > 0) {
        return hours + ":" + String(minutes).padStart(2,"0") + ":" + String(secs).padStart(2,"0");
    }
    return minutes + ":" + String(secs).padStart(2,"0");
}

function saveProgress() {
    if (!video.duration || !isFinite(video.duration)) return;
    fetch("/api/progress", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            filename: filename,
            position: video.currentTime,
            duration: video.duration
        })
    });
}

fetch("/api/progress?filename=" + encodeURIComponent(filename))
.then(response => response.json())
.then(data => {
    savedPosition = data.position || 0;
    if (savedPosition > 10 && data.duration > 0 && savedPosition < data.duration - 10) {
        resumeTime.textContent = formatTime(savedPosition);
        resumeBox.style.display = "block";
    }
});

resumeButton.onclick = function() {
    video.currentTime = savedPosition;
    resumeBox.style.display = "none";
    video.play();
};

startButton.onclick = function() {
    video.currentTime = 0;
    resumeBox.style.display = "none";
    video.play();
};

setInterval(saveProgress, 5000);
video.addEventListener("pause", saveProgress);
window.addEventListener("beforeunload", saveProgress);
video.addEventListener("ended", function() {
    fetch("/api/progress", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            filename: filename,
            position: 0,
            duration: video.duration
        })
    });
});
</script>
</body>
</html>
"""


@app.route("/watch/<path:filename>")
def watch(filename):
    path = safe_path(filename)

    if not is_video(path):
        abort(404)

    db = get_db()
    movie = build_movie(path, db)
    db.close()

    return render_template_string(PLAYER_HTML, movie=movie)


# ---------------------------------------------------------
# Media streaming
# ---------------------------------------------------------

@app.route("/media/<path:filename>")
def media(filename):
    path = safe_path(filename)

    if not is_video(path):
        abort(404)

    return send_from_directory(
        MEDIA_ROOT,
        filename,
        conditional=True,
    )


# ---------------------------------------------------------
# Progress API
# ---------------------------------------------------------

@app.route("/api/progress")
def get_progress():
    filename = request.args.get("filename", "")
    path = safe_path(filename)

    if not is_video(path):
        abort(404)

    db = get_db()
    row = db.execute(
        """
        SELECT position, duration
        FROM progress
        WHERE filename = ?
        """,
        (filename,),
    ).fetchone()
    db.close()

    if not row:
        return jsonify({"position": 0, "duration": 0})

    return jsonify({
        "position": row["position"],
        "duration": row["duration"],
    })


@app.route("/api/progress", methods=["POST"])
def save_progress():
    data = request.get_json() or {}

    filename = data.get("filename", "")
    position = float(data.get("position", 0))
    duration = float(data.get("duration", 0))

    path = safe_path(filename)

    if not is_video(path):
        abort(404)

    db = get_db()
    db.execute(
        """
        INSERT INTO progress (filename, position, duration)
        VALUES (?, ?, ?)
        ON CONFLICT(filename)
        DO UPDATE SET
            position = excluded.position,
            duration = excluded.duration,
            updated_at = CURRENT_TIMESTAMP
        """,
        (filename, position, duration),
    )
    db.commit()
    db.close()

    return jsonify({"success": True})


# ---------------------------------------------------------
# Start
# ---------------------------------------------------------

if __name__ == "__main__":
    MEDIA_ROOT.mkdir(parents=True, exist_ok=True)
    POSTER_CACHE.mkdir(parents=True, exist_ok=True)
    init_db()

    app.run(
        host="0.0.0.0",
        port=8000,
        debug=False,
    )
