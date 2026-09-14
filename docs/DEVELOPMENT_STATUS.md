# Development Status / Session Handoff

Last updated: 2026-09-15

## Branch state

- Known-good baseline: `4ce82dad2775d816b84dd6767b8b252e6fcf639c` (`4ce82da`)
- `testing`: intentionally remains at the known-good baseline.
- Current work branch: `gpu-amf-transcoding`
- AMF commit: `8b21b2b` — `Add AMD AMF transcoding support`
- The AMF branch was created directly from the baseline and was verified against `testing` as one commit ahead before the latest documentation commit.
- Do not merge until the GPU-selection and player-status checks below are complete.

## Working Windows environment

```text
Project:       C:\MediaServer
Media root:    C:\Flicks
Database:      C:\MediaServer\media.db
Venv:          C:\MediaServer\venv
Python:        3.14.3
FFmpeg:        9.0.1 essentials build with AMF
cloudflared:   C:\Cloudflared\cloudflared.exe (2026.9.1)
```

Current `.env` settings include:

```text
MEDIA_SERVER_MEDIA_ROOT=C:\Flicks
MEDIA_SERVER_DATABASE=C:\MediaServer\media.db
MEDIA_SERVER_BASE_DIR=C:\MediaServer
MEDIA_SERVER_ENABLE_AMF=1
```

`TMDB_API_TOKEN` exists locally but is intentionally omitted from all repository documentation.

## Dependency state

`requirements.txt` now needs to represent the actual Python runtime dependencies, including `python-dotenv` (imported by `app/config.py`) and `waitress` (used by `run_production.py`). Gunicorn remains present for Linux compatibility/deployment history.

## TMDb / library

TMDb authentication has been validated previously. The scanner successfully found and indexed **The Odyssey (2026)** with TMDb ID `1368337`.

The current Windows media root contains a HEVC release of The Odyssey, which requires video transcoding for HLS rather than H.264 video copy.

## AMD AMF work

The Windows FFmpeg build exposes:

- `h264_amf`
- `hevc_amf`
- `av1_amf`
- AMF filters including `vpp_amf`, `sr_amf`, `frc_amf`, `vsrc_amf`
- `d3d11va` hardware acceleration support

Independent AMF encoding was successful.

The Media Server was then verified to launch an HLS FFmpeg process whose video encoder was `h264_amf`. Therefore the application is genuinely using AMF, not merely advertising support.

### Critical GPU discovery

The machine has two AMD GPUs:

- Windows Task Manager GPU 0: Radeon RX 560X Series (discrete)
- Windows Task Manager GPU 1: AMD Radeon(TM) Vega 8 Graphics (integrated)

The standalone FFmpeg D3D11 test established that **FFmpeg D3D11 adapter index `1` selects the RX 560X**. This was confirmed by watching Task Manager: the RX 560X utilization jumped when the command used `d3d11va=dx11:1`.

Therefore the next code change should bind AMF to D3D11 adapter 1:

```text
-init_hw_device d3d11va=dx11:1
-init_hw_device amf=amf@dx11
-filter_hw_device amf
```

The existing HLS logic already gives AMF priority over VAAPI when `MEDIA_SERVER_ENABLE_AMF=1`. The missing part is explicit adapter binding.

## Current player issue

The playback page contains a transcoding pill:

```text
#shellTranscodePill
#stpDot
#stpText
```

The pill currently blinks repeatedly during playback. The working hypothesis is one of:

1. status polling alternates between present/absent and repeatedly changes `display`;
2. the polling code replaces the DOM element repeatedly;
3. a CSS pulse animation is restarted on every status update.

Do not guess. Diagnose in DevTools first. Suggested console probe:

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

Then inspect Network → Fetch/XHR for recurring transcode/progress/status requests.

## Previously completed fixes

### Local subtitles

Local `.srt` subtitle playback works. The subtitle route uses `/subtitles/<path:filename>` and a `name` query parameter to disambiguate local subtitle filenames. The HTTP endpoint was verified to return `200 text/vtt`.

Incorrect automatic OpenSubtitles behavior is parked for later.

### Seek-bar elapsed-time behavior

A previous playback bug involved the elapsed time appearing to pause above the seek bar while the movie continued playing. Treat that as a previously investigated player issue and avoid unrelated player rewrites while debugging the current status pill.

### Hold-to-speed-up

The request to remove hold-click speed acceleration while retaining the normal speed dropdown is parked. Do not touch `templates/player.html` for that request unless explicitly resumed. A previous formatted player edit caused a Jinja/player regression and was reverted.

## Production / remote access

`run_production.py` uses Waitress with a default of 8 threads and port 8000.

The current Windows deployment is not yet fully automatic. The remaining deployment task is to arrange reliable Windows startup for Waitress plus cloudflared, while keeping port 8000 bound to localhost where appropriate.

Cloudflare named tunnel:

```text
Name:       media-server
ID:         cfd34bc3-8aee-4afa-9c7a-42bbdc10b57f
Hostname:   media.anisparvez.in
Origin:     http://127.0.0.1:8000
```

Never store the tunnel token/credential in the repository.

## Immediate next session plan

1. On `gpu-amf-transcoding`, implement explicit D3D11 adapter 1 → AMF binding in the HLS FFmpeg command construction.
2. Run `python -m py_compile app/config.py app/services/transcode_service.py`.
3. Restart the Media Server.
4. Start the HEVC movie from `C:\Flicks`.
5. Confirm `h264_amf` remains the encoder and the RX 560X, not Vega 8, receives the heavy workload.
6. Check `git diff` and commit only the intended GPU-selection change.
7. Diagnose the blinking `#shellTranscodePill` using DevTools before changing player JavaScript/CSS.
8. Run the relevant test suite.
9. Review the complete branch diff against `testing`.
10. Merge only after the above checks pass.

## Safety rules for agents

- Preserve `testing` as the known-good baseline until explicitly approved for merge.
- Do not force-push.
- Do not rewrite unrelated player code.
- Do not add the local untracked `start_media_server.ps1` unless explicitly requested.
- Never expose TMDb tokens, Cloudflare tunnel tokens/credentials, passwords, or other secrets.
- Prefer small, isolated commits for each logical change.
