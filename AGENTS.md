# Agent Instructions — Anis' Media Server

## 1. Project identity and source of truth

- Repository: `anis7t/media-server`
- Local project name historically used by the user: `media-server-1`
- Framework: **Flask**, not Django.
- The application is modularized under `app/` with routes, services, utilities, configuration, and database layers.
- Root `app.py` is intentionally a lightweight executable entry point; `app/__init__.py` owns the application factory and compatibility exports.
- `docs/PROJECT_STATUS.md` is the primary current handoff: it records completed work, known bugs, platform requirements, testing requirements, and the immediate work queue. Read it before substantial changes.
- `docs/DEVELOPMENT_STATUS.md` and `docs/WINDOWS_SETUP.md` contain the detailed current Windows/AMF state. `docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md` contains the remote-access history and named-tunnel configuration.
- `docs/MULTI_GPU_CHUNKED_TRANSCODING_PROPOSAL.md` is the design reference for the proposed dynamic multi-GPU chunked transcoding architecture. It is **proposal-only** until benchmarks and capability tests justify implementation.

## 2. Current architecture

```text
Browser
  -> Flask routes / API
  -> services
     -> SQLite
     -> local media/artwork/subtitle storage
     -> FFmpeg/FFprobe
     -> TMDb API

Optional remote path:
Browser -> https://media.anisparvez.in
        -> Cloudflare named tunnel: media-server
        -> http://127.0.0.1:8000
        -> production WSGI server
```

Important modules:

- `app/config.py` — environment-driven paths and runtime settings.
- `app/db.py` — SQLite/schema/migrations.
- `app/routes/pages.py` — HTML pages.
- `app/routes/api.py` — API/device/playback endpoints.
- `app/routes/media.py` — byte-range media delivery.
- `app/routes/subtitles.py` — local subtitle/WebVTT delivery.
- `app/routes/upload.py` — resumable uploads.
- `app/services/media_service.py` — media probing/path operations.
- `app/services/media_resolver.py` — multi-source/forensic media identification.
- `app/services/scanner_service.py` — library ingestion.
- `app/services/tmdb_service.py` — TMDb integration.
- `app/services/transcode_service.py` — FFmpeg/HLS transcoding, cache/resume/cleanup.
- `app/services/subtitles_service.py` — subtitle processing.
- `app/services/device_service.py` — device telemetry/heartbeats/history.
- `app/services/worker_service.py` — background work coordination.
- `app/services/system_service.py` — system telemetry/status.

## 3. Completed capabilities

The current project includes:

- Direct MP4/M4V/WebM byte-range playback.
- On-demand HLS transcoding for incompatible media such as MKV/HEVC.
- HLS cache reuse/resume and transcode progress reporting.
- TMDb metadata ingestion and poster/backdrop caching.
- Multi-source/forensic media resolution and safer handling of anonymous filenames.
- Resumable/chunked uploads with smoothed transfer speed and ETA.
- Local `.srt`/`.vtt` subtitles and WebVTT conversion.
- Dual-axis subtitle positioning: horizontal alignment plus lowered/bottom/raised/middle/top vertical positions.
- Responsive media library and management/purge flows.
- Device telemetry dashboard with client hints, make/model/OS decoding, network-path detection, last-seen/active state, rename/remove/history.
- Stats-for-Nerds playback telemetry.
- Modern player controls, gestures, fullscreen/PiP support and YouTube-style seek-bar behavior.
- Mobile viewport/overflow protections and page transitions with reduced-motion handling.
- Linux production deployment using Gunicorn/gthread.
- Windows production deployment using Waitress.
- Cloudflare named-tunnel remote access compatible with CGNAT.

## 4. Known unresolved issues — do not treat as fixed

### Highest priority

1. **Playback transcoding pill blinks repeatedly.** The `#shellTranscodePill` / `#stpDot` / `#stpText` indicator currently blinks during playback. Diagnose with DevTools before changing player code. Determine whether polling state toggles, DOM replacement, or CSS animation restart is responsible.

2. **Windows AMD AMF needs explicit GPU adapter binding.** The tested Windows host has Radeon RX 560X discrete + Vega 8 integrated graphics. FFmpeg D3D11 adapter `1` was independently verified to select the RX 560X. The AMF HLS command must be updated/tested with:
   ```text
   -init_hw_device d3d11va=dx11:1
   -init_hw_device amf=amf@dx11
   -filter_hw_device amf
   ```
   Do not assume Windows Task Manager GPU numbers equal FFmpeg adapter numbers.

3. **Windows automatic startup is incomplete.** Waitress and cloudflared work manually. Final deployment needs reliable boot/startup, restart-on-failure, and no interactive terminal dependency.

### Parked/deferred

4. **Hold-to-speed-up playback gesture:** remove hold-click/press acceleration while retaining the normal speed dropdown. This is parked. A previous formatted player edit caused a Jinja/player regression and was reverted. Do not touch it unless explicitly resumed.

5. **Automatic OpenSubtitles behavior:** local subtitles work; incorrect automatic OpenSubtitles behavior is parked.

6. **Authentication/access control:** the stable Cloudflare hostname is not authentication. Add access control before wider public sharing.

7. **Cloudflare media-delivery architecture:** review current Cloudflare service-specific video/large-file policies before treating the public tunnel/CDN path as a scalable personal-media distribution system.

8. **Production concurrency tuning:** Linux currently uses one Gunicorn gthread worker with eight threads in the documented baseline. Benchmark any change; remote capacity is primarily constrained by ISP upload bandwidth and tunnel/network latency.

9. **Permanent media purge is cross-platform fragile and can leave cache artifacts.** See GitHub Issue #7. The Windows purge path can fail with `signal.SIGKILL`; the purge pipeline must be made failure-tolerant and the ~1 GB residual transcode-cache case must be reconciled with actual cache contents.

### Investigations / enhancements

10. **Dynamic multi-GPU chunked transcoding proposal.** See GitHub Issue #8 and `docs/MULTI_GPU_CHUNKED_TRANSCODING_PROPOSAL.md`. The target host has a discrete RTX 560X/RX 560X-class adapter plus AMD Radeon Vega 8, with the discrete GPU observed near 97% utilization while Vega 8 is nearly idle. The preferred idea is not to split one frame across GPUs; it is to treat each GPU as an independent FFmpeg worker and dynamically assign larger, keyframe-aware chunks of the same source to different workers. This remains **proposal/investigation only** until hardware capability discovery and benchmarks demonstrate a real benefit.

## 5. Platform/dependency rules

### Linux/Kali

- Python 3.10+; current development uses Python 3.14.x.
- `python3 -m venv`, `pip`, Git.
- FFmpeg and FFprobe on `PATH`.
- Production: Gunicorn/gthread; systemd is recommended.
- Remote access: cloudflared named tunnel when required.
- Keep origin on `127.0.0.1:8000` when Cloudflare is the public front end.

### Windows

- Windows 10/11 or supported Windows Server.
- Python 3.10+; current tested host uses Python 3.14.3.
- PowerShell, Git, FFmpeg and FFprobe.
- Production WSGI: **Waitress**, not Gunicorn.
- Optional remote access: `cloudflared.exe`.
- For AMD AMF, verify actual FFmpeg AMF/D3D11 support and bind the intended adapter explicitly after testing on the target machine.

### Python requirements

`requirements.txt` is cross-platform. It contains Flask, requests, python-dotenv, and Waitress; Gunicorn is installed only on non-Windows platforms via a Python environment marker.

Do not add platform-specific system binaries to `requirements.txt`. FFmpeg/FFprobe and cloudflared are host-level dependencies.

## 6. Security and secrets

Never commit or expose:

- `.env`
- `TMDB_API_TOKEN`
- Cloudflare tunnel credential/token material
- passwords, private keys or other secrets

The named tunnel is:

```text
Name:     media-server
ID:       cfd34bc3-8aee-4afa-9c7a-42bbdc10b57f
Hostname: media.anisparvez.in
Origin:   http://127.0.0.1:8000
```

Tunnel credentials live outside the repository. Preserve that separation.

## 7. Player invariants

- Direct streams must remain isolated from transcoding status/polling logic.
- Seeking must not synchronously assign `currentTime` on every seek-bar drag event; commit on gesture completion.
- During scrubbing or browser seek, `timeupdate` must not snap the slider back to an old timestamp.
- Direct MP4/AAC seeking and MKV/HEVC HLS seeking must both remain functional.
- Preserve player container isolation and mobile viewport clamping.
- `templates/player.html` has a strict single-`<script>` invariant; external scripts must be dynamically injected from the existing script block.
- Do not perform broad player rewrites for narrow playback bugs.

## 8. Subtitle invariants

- Preserve both horizontal and vertical subtitle positioning.
- Preserve local `.srt`/`.vtt` playback.
- WebVTT timestamp parsing must support both `HH:MM:SS.mmm` and `MM:SS.mmm` formats.
- Keep subtitle cues clear of playback controls according to the documented elevation rules.

## 9. UI/HTML safety invariants

- Dynamic Jinja values must not be injected directly into inline JavaScript arguments. Use escaped `data-*` attributes and `dataset` reads.
- Guard potentially `None` values before Jinja containment tests.
- Preserve destructive modal outside-touch immunity.
- Preserve mobile `html`/`body` overflow clamping, `min-width: 0` on flexible/grid ancestors, and horizontal-rail gesture isolation.
- Preserve upload lifecycle behavior: abort control disappears after bytes are committed and post-upload ingestion uses a dynamic status indicator.

## 10. Device telemetry invariants

- Preserve Chromium high-entropy client-hint handling for model/platform version.
- Preserve heartbeat behavior and bounded active/offline thresholds.
- Do not fabricate hardware, network or location data when the browser/server cannot provide it.
- Keep telemetry collection behavior consistent with the application's privacy expectations.
- Future multi-GPU work must report adapters independently; do not collapse multiple GPUs into a single generic GPU value where per-device telemetry is available.

## 11. Git/change-management rules

- Protect known-good/testing baselines unless the user explicitly approves a merge/change.
- Prefer small, isolated commits.
- Never force-push or rewrite protected history.
- Before changes, inspect `git status`, current branch and recent commits.
- Do not add local machine-specific files such as `start_media_server.ps1` unless explicitly requested.
- If `.git/index` is truncated, use the documented non-destructive recovery `rm -f .git/index && git reset`; never use `git reset --hard` or `git clean` as a recovery shortcut.

## 12. Testing protocol

For Python changes:

```bash
python -m py_compile app/config.py app/services/transcode_service.py
python -m pytest tests/
```

For player/transcoding changes, verify at minimum:

- Direct MP4/AAC playback.
- MKV/HEVC HLS playback.
- Seek to `0:00` and arbitrary positions.
- Playback continues after seeking.
- Seek-bar elapsed-time display stays synchronized while playing.
- Subtitles remain correctly positioned.
- No mobile horizontal/vertical layout regression.
- Transcoding indicator reflects real backend state.

For Windows AMF changes:

1. Confirm FFmpeg exposes `h264_amf`.
2. Confirm D3D11 adapter selection on the real machine.
3. Transcode a real HEVC movie.
4. Confirm the process actually uses `h264_amf`.
5. Confirm the RX 560X, not Vega 8, performs the intended workload.
6. Run the relevant Python tests.

For future multi-GPU/chunked-transcoding work:

1. Read `docs/MULTI_GPU_CHUNKED_TRANSCODING_PROPOSAL.md` and GitHub Issues #7 and #8 before altering transcoding or worker architecture.
2. Enumerate actual GPU/FFmpeg capabilities before implementation.
3. Benchmark discrete-only, Vega-only, dual independent jobs, and chunked dual-GPU candidates.
4. Test chunk sizes empirically rather than hard-coding 4-second HLS segments as worker granularity.
5. Preserve keyframe alignment, timestamp continuity, audio synchronization, HLS ordering, resume semantics, and cache cleanup.
6. Never assume Task Manager GPU numbering equals FFmpeg adapter numbering.
7. Keep CPU-only and single-GPU fallback paths working.
8. Do not ship the feature solely because both GPUs show activity; require measurable throughput/startup benefit and valid playback.

For remote-access changes, preserve the CGNAT-compatible named-tunnel architecture unless the user explicitly requests a replacement.

## 13. Immediate priority order

1. Finish explicit RX 560X/FFmpeg D3D11 adapter binding on the AMF branch.
2. Validate AMF with a real HEVC movie and Task Manager.
3. Diagnose and fix the blinking playback transcoding pill.
4. Fix the cross-platform permanent-purge/SIGKILL and cache-cleanup issue (#7).
5. Run complete tests and player regression checks.
6. Finish Windows automatic Waitress + cloudflared startup.
7. Add authentication/access control before wider sharing.
8. Reassess Cloudflare media-delivery suitability/policies.
9. Benchmark the dynamic multi-GPU chunked transcoding proposal (#8) before implementation.
10. Only then resume parked player/OpenSubtitles work as explicitly requested.
