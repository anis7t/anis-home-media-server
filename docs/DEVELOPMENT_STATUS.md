# Development Status / Session Handoff

Last updated: 2026-09-15.

## Git state

- Known-good baseline: `4ce82dad2775d816b84dd6767b8b252e6fcf639c` (`4ce82da`).
- `testing` is intentionally preserved at the baseline.
- Active feature branch: `gpu-amf-transcoding`.
- AMF implementation commit: `8b21b2b` — `Add AMD AMF transcoding support`.
- Documentation/dependency commits have been added after the AMF commit. Review the complete branch diff before merge.
- Never force-push or rewrite `testing`.

## Current Windows machine

```text
Project:       C:\MediaServer
Media root:    C:\Flicks
Database:      C:\MediaServer\media.db
Venv:          C:\MediaServer\venv
Python:        3.14.3
FFmpeg:        9.0.1 essentials build with AMD AMF
cloudflared:   C:\Cloudflared\cloudflared.exe 2026.9.1
```

`.env` contains the configured TMDb token and:

```text
MEDIA_SERVER_MEDIA_ROOT=C:\Flicks
MEDIA_SERVER_DATABASE=C:\MediaServer\media.db
MEDIA_SERVER_BASE_DIR=C:\MediaServer
MEDIA_SERVER_ENABLE_AMF=1
```

Never put the real token in Git or agent prompts.

## Dependencies

`requirements.txt` now explicitly includes:

- Flask
- requests
- gunicorn
- python-dotenv
- waitress

`python-dotenv` is imported by `app/config.py`; Waitress is imported by `run_production.py`.

## TMDb and media library

TMDb authentication has previously been validated. The scanner successfully indexed **The Odyssey (2026)** with TMDb ID `1368337`.

The current Windows media root contains a HEVC release of The Odyssey, so its HLS path requires video transcoding rather than H.264 video copy.

## AMD AMF

The installed FFmpeg supports `h264_amf`, `hevc_amf`, `av1_amf`, AMF filters, and D3D11 hardware support.

An independent `h264_amf` test succeeded. The actual Media Server HLS process was also inspected and confirmed to use `h264_amf`.

### GPU selection discovery

Windows Task Manager shows:

- GPU 0: Radeon RX 560X Series (discrete)
- GPU 1: AMD Radeon(TM) Vega 8 Graphics (integrated)

A direct FFmpeg test proved that D3D11 adapter index `1` selects the RX 560X:

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

Task Manager confirmed the RX 560X became active during that command.

### Pending AMF change

The current HLS code selects `h264_amf` but does not yet explicitly bind AMF to the D3D11 adapter. The next code change should add command-level device initialization equivalent to:

```text
-init_hw_device d3d11va=dx11:1
-init_hw_device amf=amf@dx11
-filter_hw_device amf
```

The existing HLS logic already gives AMF priority over VAAPI. Do not redesign the transcoding architecture.

After implementing this, test the real HEVC movie and verify RX 560X activity in Task Manager while confirming the FFmpeg process still reports `h264_amf`.

## Playback transcoding-indicator bug

The playback page has `#shellTranscodePill`, `#stpDot`, and `#stpText`. The transcoding indicator currently blinks repeatedly while the movie is playing, suggesting repeated show/hide operations, DOM replacement, or CSS animation restarts.

This has not been fixed.

First diagnostic:

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

Then inspect DevTools Network → Fetch/XHR for recurring transcode/status/progress requests. Diagnose before changing player code.

## Completed / parked work

### Local subtitles

Local `.srt`/`.vtt` playback is working. The subtitle route was changed to `/subtitles/<path:filename>` with a `name` query parameter to disambiguate local subtitle filenames. The endpoint was verified to return `200 text/vtt`.

Automatic OpenSubtitles behavior is parked.

### Hold-to-speed-up

The request to remove hold-click playback-speed acceleration while retaining the normal speed dropdown is parked. Do not modify `templates/player.html` for this unless explicitly resumed. A prior formatted player edit caused a Jinja/player regression and was reverted.

## Production / remote access

`run_production.py` uses Waitress, default port 8000 and 8 threads.

The named Cloudflare tunnel is:

```text
Name:       media-server
ID:         cfd34bc3-8aee-4afa-9c7a-42bbdc10b57f
Hostname:   media.anisparvez.in
Origin:     http://127.0.0.1:8000
```

Windows automatic startup for Waitress + cloudflared is not finished.

The historical Kali/CGNAT tunnel setup is documented in `docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md`.

## Immediate next session

1. Pull the latest `gpu-amf-transcoding` branch.
2. Check `git status` and confirm the branch.
3. Implement explicit D3D11 adapter 1 → AMF binding.
4. Run `python -m py_compile app/config.py app/services/transcode_service.py`.
5. Restart the server.
6. Play the HEVC movie from `C:\Flicks`.
7. Confirm `h264_amf` and RX 560X activity; Vega 8 should not be the heavy encoder workload.
8. Inspect the blinking `#shellTranscodePill` using DevTools.
9. Run the relevant tests.
10. Review `git diff testing...gpu-amf-transcoding` and merge only after all checks pass.

## Agent safety rules

- Preserve `testing` as the known-good baseline.
- Do not force-push.
- Do not expose TMDb tokens or Cloudflare credentials.
- Do not commit `.env`.
- Do not add local `start_media_server.ps1` accidentally.
- Avoid broad player rewrites.
- Use small commits for logically separate changes.
