# Windows Development Setup

Current Windows development environment and resume instructions for the Media Server.

## Project layout

- Repository/worktree: `C:\MediaServer`
- Media library: `C:\Flicks`
- SQLite database: `C:\MediaServer\media.db`
- Environment file: `C:\MediaServer\.env`
- Virtual environment: `C:\MediaServer\venv`
- Python: 3.14.3
- FFmpeg: 9.0.1 essentials build with AMD AMF enabled
- cloudflared: `C:\Cloudflared\cloudflared.exe`, version 2026.9.1

## Python setup

```powershell
cd C:\MediaServer
.\venv\Scripts\Activate.ps1
python --version
pip install -r requirements.txt
```

`python-dotenv` is required by `app/config.py`. `waitress` is required by `run_production.py`. Both are declared in `requirements.txt`.

## `.env`

The real `.env` is local-only and must never be committed. Current settings are:

```ini
TMDB_API_TOKEN=<secret>
MEDIA_SERVER_MEDIA_ROOT=C:\Flicks
MEDIA_SERVER_DATABASE=C:\MediaServer\media.db
MEDIA_SERVER_BASE_DIR=C:\MediaServer
MEDIA_SERVER_ENABLE_AMF=1
```

Use `.env.example` as the safe template. Never copy the real TMDb token into documentation or agent prompts.

## FFmpeg / AMF validation

The installed FFmpeg exposes `h264_amf`, `hevc_amf`, `av1_amf`, AMF filters, and D3D11 support. Independent AMF encoding succeeded.

```powershell
ffmpeg -hide_banner -encoders | Select-String "amf"
ffmpeg -hide_banner -hwaccels
ffmpeg -hide_banner -filters | Select-String "amf|d3d11va"
```

Independent encoder test:

```powershell
ffmpeg -hide_banner -f lavfi -i testsrc2=size=1280x720:rate=30 -t 10 -c:v h264_amf -f null -
```

This completed successfully at roughly 80 fps on the test machine.

## Two AMD GPUs

Windows Task Manager currently shows:

- GPU 0: Radeon RX 560X Series (discrete)
- GPU 1: AMD Radeon(TM) Vega 8 Graphics (integrated)

FFmpeg's D3D11 adapter numbering is not the same as the Task Manager GPU labels. A direct test proved that **D3D11 adapter index `1` selects the RX 560X**:

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

Task Manager confirmed the RX 560X became active during this test.

## AMF application status

`gpu-amf-transcoding` contains AMF support in `app/config.py` and `app/services/transcode_service.py`. The actual Media Server HLS process was verified to use `h264_amf`.

The remaining AMF task is to explicitly bind the application to D3D11 adapter `1` using:

```text
-init_hw_device d3d11va=dx11:1
-init_hw_device amf=amf@dx11
-filter_hw_device amf
```

Do not merge into `testing` until the real movie test confirms the RX 560X is used.

## Production server

Windows production mode uses Waitress:

```powershell
cd C:\MediaServer
.\venv\Scripts\Activate.ps1
python run_production.py
```

Default: port `8000`, 8 threads. For Cloudflare-origin use, binding to `127.0.0.1` is preferable to exposing the origin on all interfaces.

Automatic Windows startup for Waitress + cloudflared is not finished.

## Cloudflare

- Executable: `C:\Cloudflared\cloudflared.exe`
- Named tunnel: `media-server`
- Tunnel ID: `cfd34bc3-8aee-4afa-9c7a-42bbdc10b57f`
- Hostname: `media.anisparvez.in`
- Origin: `http://127.0.0.1:8000`

The tunnel token/credential material is secret and must never be committed.

## Current playback issue

The player contains `#shellTranscodePill`, which currently blinks repeatedly during playback. This has not been fixed.

First diagnose with DevTools rather than rewriting the player:

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

Also inspect Network → Fetch/XHR for repeated transcode/status/progress requests. Determine whether state toggling, DOM replacement, or CSS animation restart is responsible.

## Parked items

- Do not modify `templates/player.html` for the hold-click speed-up request unless explicitly resumed. A previous broad/formatted edit caused a player/Jinja regression and was reverted.
- Local subtitle playback is working; incorrect automatic OpenSubtitles behavior is parked.

## Git safety

- Known-good baseline: `4ce82dad2775d816b84dd6767b8b252e6fcf639c`.
- `testing` remains at the known-good baseline.
- `gpu-amf-transcoding` is the active feature branch.
- Do not force-push or rewrite `testing`.
- Do not accidentally add local `start_media_server.ps1`.

## Next session

1. Pull the latest branch state.
2. Implement explicit AMF adapter-1 binding.
3. Syntax-check and test.
4. Transcode the HEVC movie from `C:\Flicks`.
5. Confirm `h264_amf` and RX 560X activity.
6. Diagnose/fix the blinking transcoding pill separately.
7. Run tests and review the branch diff.
8. Only then consider merging into `testing`.
