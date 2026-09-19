# Windows Development Setup

This document records the current Windows development environment for the Media Server. It supersedes older Linux/Kali-only development instructions for the current workstation; the existing Cloudflare/Kali document is retained as historical/remote-access documentation.

## Project layout

- Repository/worktree: `C:\MediaServer`
- Media library: `C:\Flicks`
- SQLite database: `C:\MediaServer\media.db`
- Environment file: `C:\MediaServer\.env`
- Virtual environment: `C:\MediaServer\venv`
- Python: 3.14.x
- FFmpeg: a supported FFmpeg build, with AMD AMF enabled
- cloudflared: `C:\Cloudflared\cloudflared.exe`, a supported version

## Python environment

From PowerShell:

```powershell
cd C:\MediaServer
.\venv\Scripts\Activate.ps1
python --version
pip install -r requirements.txt
```

The application imports `python-dotenv`, and production mode uses Waitress. Both are therefore explicit runtime dependencies in `requirements.txt`.

## Required `.env` configuration

The real `.env` is local-only and must never be committed. Current Windows values are conceptually:

```ini
TMDB_API_TOKEN=<secret>
MEDIA_SERVER_MEDIA_ROOT=C:\Flicks
MEDIA_SERVER_DATABASE=C:\MediaServer\media.db
MEDIA_SERVER_BASE_DIR=C:\MediaServer
MEDIA_SERVER_ENABLE_AMF=1
```

Do not copy the real TMDb token into documentation, source control, agent prompts, screenshots, or issue comments.

## FFmpeg / AMD AMF

The installed FFmpeg build supports AMD AMF:

```powershell
ffmpeg -hide_banner -encoders | Select-String "amf"
ffmpeg -hide_banner -hwaccels
ffmpeg -hide_banner -filters | Select-String "amf|d3d11va"
```

Expected AMF encoders include `h264_amf`, `hevc_amf`, and `av1_amf`. The available filters include AMF-related filters such as `vpp_amf`.

An independent encoder test succeeded:

```powershell
ffmpeg -hide_banner -f lavfi -i testsrc2=size=1280x720:rate=30 -t 10 -c:v h264_amf -f null -
```

This completed successfully at roughly 80 fps on the test system.

## Two AMD GPUs

The Windows machine has:

- GPU 0: Radeon RX 560X Series (discrete GPU)
- GPU 1: AMD Radeon(TM) Vega 8 Graphics (integrated GPU)

Windows Task Manager labels these in the opposite numerical order from the FFmpeg D3D11 adapter test used below. Do not infer FFmpeg adapter numbers from the Task Manager GPU number alone.

A direct FFmpeg test established that **D3D11 adapter index `1` selects the Radeon RX 560X**:

```powershell
ffmpeg -hide_banner `
  -init_hw_device d3d11va=dx11:1 `
  -init_hw_device amf=amf@dx11 `
  -filter_hw_device amf `
  -f lavfi -i testsrc2=size=1920x1080:rate=30 `
  -t 30 `
  -vf "scale=1920:1080,format=nv12" `
  -c:v h264_amf `
  -quality speed `
  -f null -
```

While this test ran, Task Manager showed the discrete RX 560X becoming active instead of the Vega 8. This is the authoritative adapter-selection result for the current machine.

## Current AMF application state

The branch `gpu-amf-transcoding` contains commit `8b21b2b` (`Add AMD AMF transcoding support`) on top of the known-good baseline `4ce82dad2775d816b84dd6767b8b252e6fcf639c`.

The current implementation adds `MEDIA_SERVER_ENABLE_AMF` support and selects `h264_amf` for compatibility/HLS video transcoding. The actual Media Server HLS process was verified to use `h264_amf`.

**Important pending change:** AMF currently needs explicit D3D11 adapter binding so the application selects the RX 560X rather than the Vega 8. The intended HLS command-level initialization is:

```text
-init_hw_device d3d11va=dx11:1
-init_hw_device amf=amf@dx11
-filter_hw_device amf
```

Do not merge this pending adapter-selection change into `testing` until it has been tested on the real movie.

## Production server on Windows

`run_production.py` uses Waitress:

```powershell
cd C:\MediaServer
.\venv\Scripts\Activate.ps1
python run_production.py
```

Default configuration is port `8000` and 8 Waitress threads. For a machine hosting a reverse tunnel, binding the application to `127.0.0.1` is preferable to exposing port 8000 on all network interfaces.

## Cloudflare Tunnel on Windows

The Windows cloudflared executable is:

```text
C:\Cloudflared\cloudflared.exe
```

The named tunnel is `media-server` with ID `cfd34bc3-8aee-4afa-9c7a-42bbdc10b57f` and the public hostname is `<media-hostname>`.

The Windows config is:

```yaml
tunnel: cfd34bc3-8aee-4afa-9c7a-42bbdc10b57f
ingress:
  - hostname: <media-hostname>
    service: http://127.0.0.1:8000
  - service: http_status:404
```

The tunnel token/credential material is secret. Never put it in Git, documentation, or agent prompts.

Automatic startup of Waitress + cloudflared on Windows is **not yet finished**. This is a future deployment task.

## Git workflow / safety

The known-good production/testing baseline is commit `4ce82da`.

`testing` is intentionally preserved at that baseline. The AMF work is isolated on `gpu-amf-transcoding`.

Before changing code:

```powershell
git status
git branch --show-current
git log --oneline -5
```

Do not accidentally add the local untracked `start_media_server.ps1` unless explicitly requested.

Do not force-push. Do not reset or rewrite `testing` unless explicitly instructed.

## Current troubleshooting item: playback transcoding indicator

The playback page has a `#shellTranscodePill` / transcoding status indicator. It is currently observed to blink repeatedly while playback is running, as if the status is being repeatedly shown and hidden or the DOM/CSS animation is being restarted.

This has **not** been fixed yet.

Next diagnostic step:

```javascript
setInterval(() => {
    const el = document.querySelector('#shellTranscodePill');
    console.log(
        new Date().toLocaleTimeString(),
        'display=', el?.style.display,
        'hidden=', el?.hidden,
        'text=', el?.innerText
    );
}, 1000);
```

Also inspect DevTools Network → Fetch/XHR for repeatedly requested transcode/status/progress endpoints. Determine whether the issue is polling state toggling, DOM replacement, or a CSS animation restart before changing player code.

## Parked player issue

The previous request to remove hold-click playback-speed acceleration while retaining the normal speed dropdown is parked. Do not modify `templates/player.html` for that issue unless explicitly resumed. A prior formatted edit to the player caused a Jinja/player regression and was reverted.

## Subtitle status

Local `.srt`/`.vtt` playback is working. The local subtitle route was fixed to use a query-string `name` parameter to disambiguate subtitle filenames. The incorrect automatic OpenSubtitles behavior is intentionally parked for later.

## Resume point for the next session

1. Verify/implement explicit AMF adapter 1 selection for the RX 560X.
2. Restart the server and transcode a real HEVC movie from `C:\Flicks`.
3. Confirm Task Manager shows RX 560X activity rather than Vega 8 activity.
4. Run Python syntax/tests.
5. Inspect the playback transcoding-pill blinking issue.
6. Only after these checks consider merging `gpu-amf-transcoding` into `testing`.
7. Finish Windows automatic startup for Waitress + cloudflared later.
