# My Movies

A lightweight Flask media server for a private LAN. It discovers local video files, stores playback progress and TMDB metadata in SQLite, and is designed for Android and desktop browsers.

## Setup

```sh
python3 -m venv venv
. venv/bin/activate
pip install -r requirements.txt
cp .env.example .env # create this yourself if it does not exist
python scanner.py     # optional: fetch TMDB metadata
python posters.py     # optional: cache posters and backdrops
python app.py
```

Set `TMDB_API_TOKEN` in `.env` for scanner access. Never commit that file. By default the library is `/home/iamroot/Media/Movies`, the database is `media.db`, and the app listens on `0.0.0.0:8000`. Override paths with `MEDIA_SERVER_MEDIA_ROOT`, `MEDIA_SERVER_DATABASE`, and `MEDIA_SERVER_BASE_DIR`.

## Features

- Responsive searchable movie library with Continue Watching and sort options.
- Cached TMDB posters/backdrops and filename fallbacks.
- Details pages, custom touch/keyboard player controls, resume, speed, volume, fullscreen and throttled progress persistence.
- Local subtitles: use `Movie.srt`, `Movie.en.srt`, `Movie.hi.srt`, or matching `.vtt`. SRT is converted to VTT in memory; source files are never changed.
- Explicit HTTP byte ranges (200/206/416) for seeking. Direct play is preferred. `ffprobe`/`ffmpeg` are detected but transcoding is not enabled automatically because it is CPU-expensive and should only follow verified codec incompatibility.
- Installable PWA shell; it does not cache media files offline.

`media.db`, `cache/`, virtual environments, media, and `.env` are intentionally ignored. TMDB data is provided by [TMDB](https://www.themoviedb.org/).

## Troubleshooting

Run `curl -I http://127.0.0.1:8000/` after starting the service. If a video does not play, use `/api/media-info/<movie path>` to see whether codec inspection tools are installed. Install FFmpeg only when a real browser compatibility issue is identified; direct-play files remain the fast path.
