# Agent Instructions

## Read this first

This repository is a personal Flask media server. **The authoritative current-session handoff is `docs/DEVELOPMENT_STATUS.md`; the Windows environment is documented in `docs/WINDOWS_SETUP.md`. Read both before making changes.**

The project has been developed across Kali Linux and Windows. The current development workstation is Windows, while the historical Kali/Cloudflare setup remains documented in `docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md`.

## Current branch and Git safety

- Known-good baseline: `4ce82dad2775d816b84dd6767b8b252e6fcf639c` (`4ce82da`).
- `testing` is intentionally preserved at that baseline.
- Current feature branch: `gpu-amf-transcoding`.
- AMF support commit: `8b21b2b` — `Add AMD AMF transcoding support`.
- Do not merge the feature branch into `testing` until the pending GPU-selection test and player-status investigation are complete.
- Do not force-push or rewrite history unless explicitly requested.
- Keep changes small and logically separated.
- A local untracked `start_media_server.ps1` exists/has existed during Windows setup; do not add it accidentally.

Before editing:

```powershell
git status
git branch --show-current
git log --oneline -5
```

## Current Windows environment

```text
Project:       C:\MediaServer
Media root:    C:\Flicks
Database:      C:\MediaServer\media.db
Venv:          C:\MediaServer\venv
Python:        3.14.3
FFmpeg:        9.0.1 essentials build with AMD AMF
cloudflared:   C:\Cloudflared\cloudflared.exe (2026.9.1)
```

Current `.env` contains the media/database/base paths above and:

```text
MEDIA_SERVER_ENABLE_AMF=1
```

The TMDb bearer token is secret and must never appear in code, documentation, commits, prompts, screenshots, logs, or agent output.

## Python dependencies

`app/config.py` imports `python-dotenv`, and `run_production.py` imports `waitress`. These are runtime dependencies and should be represented in `requirements.txt`. Do not remove Gunicorn merely because the current Windows production runner is Waitress; Linux deployment compatibility remains relevant.

## AMD AMF status

FFmpeg exposes `h264_amf`, `hevc_amf`, `av1_amf`, and AMF/D3D11 support. An independent AMF encoding test succeeded.

The actual Media Server HLS process was also verified to use `h264_amf`.

The machine has two AMD GPUs. Windows Task Manager shows:

- GPU 0: Radeon RX 560X Series (discrete)
- GPU 1: AMD Radeon(TM) Vega 8 Graphics (integrated)

A standalone FFmpeg test proved that **D3D11 adapter index `1` selects the RX 560X**. The next AMF code change should therefore bind AMF through:

```text
-init_hw_device d3d11va=dx11:1
-init_hw_device amf=amf@dx11
-filter_hw_device amf
```

The existing HLS logic already gives AMF priority over VAAPI when enabled. Do not redesign the transcoding architecture; add explicit adapter binding and test it.

## Current player bug to investigate

The playback page's transcoding indicator (`#shellTranscodePill`) visibly blinks/reappears repeatedly during playback. This is not yet fixed.

Possible causes:

1. polling state alternates between present and absent;
2. the status update repeatedly replaces the DOM element;
3. a CSS pulse animation restarts on every update.

Diagnose before editing. Useful DevTools console probe:

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

Also inspect Network → Fetch/XHR for repeated transcode/status/progress calls.

## Do not regress the player

The request to remove hold-click playback-speed acceleration while retaining the normal speed dropdown is parked. Do not modify `templates/player.html` for that issue unless explicitly resumed.

A prior formatted player edit caused a Jinja/player regression and was reverted. Avoid broad player rewrites; make surgical changes only after identifying the exact cause.

## Subtitle status

Local `.srt`/`.vtt` playback is working. The local subtitle URL was fixed using a `name` query parameter to disambiguate subtitle filenames. The incorrect automatic OpenSubtitles behavior is parked for later.

## Windows production / Cloudflare

`run_production.py` uses Waitress, default port `8000`, default `8` threads. The long-term goal is reliable automatic startup of Waitress plus cloudflared on Windows; this is not finished.

Named Cloudflare tunnel:

```text
Name:       media-server
ID:         cfd34bc3-8aee-4afa-9c7a-42bbdc10b57f
Hostname:   media.anisparvez.in
Origin:     http://127.0.0.1:8000
```

The Cloudflare tunnel token/credential is secret. Never commit or reveal it. Prefer the application origin to bind to localhost when Cloudflare is the intended public entry point.

The historical Kali named-tunnel configuration and CGNAT rationale are in `docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md`.

## Immediate next-session sequence

1. Read `docs/DEVELOPMENT_STATUS.md` and `docs/WINDOWS_SETUP.md`.
2. Verify the working tree and branch.
3. Implement explicit D3D11 adapter 1 → AMF binding for HLS.
4. Run Python syntax checks/tests.
5. Restart the server and transcode the HEVC movie in `C:\Flicks`.
6. Verify `h264_amf` and RX 560X activity; Vega 8 should not be the heavy encoder workload.
7. Inspect and commit only the intended GPU-selection change.
8. Diagnose/fix the blinking transcoding indicator separately.
9. Run the relevant test suite.
10. Review the full diff against `testing`.
11. Merge only when all checks pass.

## Security

Never expose or commit:

- TMDb API/bearer tokens
- Cloudflare tunnel tokens or credential JSON
- passwords/session secrets
- local database contents if they contain sensitive information
- other private credentials

When documentation needs to refer to a secret, use `<secret>` rather than a real value.
