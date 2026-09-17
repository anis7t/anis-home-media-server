# Development Status / Session Handoff

Last updated: 2026-09-18
Repository: `anis7t/media-server`
Active Working branch: `feat/unified-header-navigation`
Clean Base branch: `feat/storage-retention-cache-purge`

## 1. Branch Architecture & Environment State

- **Branch Structure:**
  - `feat/storage-retention-cache-purge` (at `9cf8d21`): Pure backend engine branch containing storage retention policies, dual-drive tiering (`C:` fast NVMe SSD vs `D:\Flicks` mass storage), cross-drive cache/subtitle resilience, and multi-chunk HLS discontinuity alignment.
  - `feat/unified-header-navigation` (at `6c6e6c6`): Pure frontend & UX branch containing the frosted obsidian navigation redesign, 3D play brand identity, responsive swipeable mobile action rails, desktop search bar density polish, universal customizable select styling (`appearance: base-select`), and Chromium Hls.js precedence.
- **Environment:** Windows 11 Home / Workstation
- **Tested Hardware:** AMD Ryzen 5 3550H, 16 GB RAM
- **Discrete GPU:** AMD Radeon RX 560X (4GB VRAM) — Task Manager GPU 0 / FFmpeg `dx11:1`
- **Integrated GPU:** AMD Radeon Vega 8 Graphics — Task Manager GPU 1 / FFmpeg `dx11:0`
- **Python:** 3.14.3 (`C:\MediaServer\venv`)
- **FFmpeg:** 9.0.1 essentials build with AMF & D3D11va
- **cloudflared:** 2026.9.1 (`C:\Cloudflared\bin\cloudflared.exe`)

```text
Project:       C:\MediaServer
Media root:    C:\Flicks
Upload root:   D:\Flicks\.uploads -> D:\Flicks (215+ GB storage pool on D:)
Archive root:  D:\Flicks\.archive (215+ GB free storage pool on D:)
Transcode:     C:\MediaServer\cache\hls (fast NVMe SSD generation & delivery)
Previews:      C:\MediaServer\cache\previews (seek thumbnail frame cache)
Database:      C:\MediaServer\media.db
Venv:          C:\MediaServer\venv
```

---

## 2. Completed Architecture & Capabilities

### Dynamic Multi-GPU Transcoding Engine
- Implemented `app/services/gpu_service.py` and `app/services/chunk_transcode_service.py`.
- Both GPUs (Radeon RX 560X and Vega 8) transcode independent, keyframe-aligned segments of the same source file concurrently.
- Hardware engine utilization for all engaged GPUs is dynamically polled via Windows Performance Counters and PyNVML, displayed in the System Telemetry HUD and `/api/system/stats`.
- Transcode polling cadence optimized to 1 second for smooth progress bars, speed, and smoothed ETA calculations.

### Multi-Chunk HLS Discontinuity Alignment & Seeking Stabilization
- **Monotonic Presentation Timestamps:** Removed `-avoid_negative_ts make_zero` in chunk encoders, enforcing `-output_ts_offset <start_time>` corresponding to timeline positions to prevent PTS resets.
- **RFC 8216 `#EXT-X-DISCONTINUITY` Boundaries:** Scheduler automatically injects discontinuity tags at chunk transition points in `_update_master_playlist()` and runs `reconcile_hls_playlist_discontinuities()` on disk caches.
- **Non-Destructive Seek Recovery:** Preserves target seek timestamps during buffer gap recovery, eliminating `0:00` player timeline resets.
- **Chromium Hls.js Precedence:** Prioritizes `window.Hls && Hls.isSupported()` over native `canPlayType` before falling back, preventing Windows Chromium browsers from attempting native Safari-style playback which cannot demux multi-chunk offsets.

### Dual-Drive Storage Tiering & Headroom Prioritization
- **Headroom Optimization:** Preserves primary fast NVMe SSD (`C:`) for OS, SQLite (`media.db`), transcode scratch, seek thumbnails (`cache/previews`), and completed multi-GPU HLS caches (`cache/hls`).
- **Secondary Mass Storage (`D:`):** Offloads multi-gigabyte raw video files (`D:\Flicks`), resumable upload staging (`D:\Flicks\.uploads`), and cold source archives (`D:\Flicks\.archive`).
- **Dynamic Multi-Root Discovery:** `config.get_media_roots()` returns all active storage roots. All routing, authorization, and media scanning procedures validate against all configured roots.
- **Deterministic Cache Continuity:** `hls_cache_dir()` and `preview_dir()` compute relative paths across all active roots, ensuring media files moved or archived between drives retain their deterministic cache keys and active streams.
- **Cross-Root Subtitle Mirror Discovery:** Resolves sidecar `.srt`/`.vtt` files across mirror subdirectories in any active drive root (stripping `.archive` subpaths).

### Post-Transcode Storage Retention & Safe Orphaned Cache Purge
- **Configurable Retention Policies:** User-configurable retention actions (`keep`, `archive`, `purge_cache`) persisted in SQLite settings.
- **Automated Orphaned Cache Auditing:** `audit_orphaned_caches()` reconciles `cache/hls/` and `cache/previews/` against active video files and in-flight transcode jobs.
- **Safe Orphaned Cache Purge:** `purge_orphaned_caches()` with bounded Windows file-lock retries, triggered automatically on server launch and via background worker every 2 hours. Reclaimed 57 orphaned cache directories.
- **Management UI:** Storage Retention & Cache Governance card on `/manage` with live storage pool telemetry, interactive policy selector, and clean orphaned caches modal (`#cleanOrphansModal`).

### Unified Frosted Obsidian Navigation Header & Brand Identity
- **Consistent Top Navigation:** Redesigned frosted obsidian glass header across all 5 pages (`/`, `/movie/<filename>`, `/player/<filename>`, `/manage`, `/devices`).
- **3D Glossy Play Brand Icon:** Vector SVG with radial crimson gradients, specular highlights, and ambient drop shadows, paired with two-tone typography (**Anis'** + **Media Library**) and tagline (**PLAY • ORGANIZE • ENJOY**).
- **Desktop & Mobile Search Density Polish:** Completely removed the redundant A-Z sort dropdown across both desktop and mobile views, prioritizing natural library browsing and direct search input filtering.
- **Home Page Content Hierarchy (Telemetry at Footer):** Repositioned the System Telemetry HUD (`#systemTelemetryCard`) to the bottom of the home page (strictly after "All Movies"), prioritizing user media rails while keeping technical stats accessible at the footer.
- **Mobile Player Controls Expansion & Dedicated Seekbar Spacing:** Restored primary controls (`↺` Restart, `▶`/`⏸` Play, `🔊` Mute, `1×` Speed, `CC ⚙` Subtitles/Settings, Aspect Ratio, Rotate Screen, PiP, Nerd Stats) on mobile inside a swipeable non-overflowing rail (`overflow-x: auto`), cleanly hid desktop-only controls (`#volume` and `#shortcutsBtn`), explicitly hid redundant `-10s`/`+10s` buttons on mobile in favor of seekbar/double-tap gestures, and eliminated the dead space between `.seek-time-row` and seekbar (`margin-bottom: -9px !important`).


### Universal Customizable `<select>` Popovers
- Implemented modern Customizable Select API using `appearance: base-select` and `select::picker(select)`.
- Replaced sharp, bright blue Windows system select menus with top-layer frosted obsidian glass popups (`rgba(18, 22, 32, 0.96)`, `backdrop-filter: blur(24px)`), rounded corners, brand red active highlights (`#e50914`), white checkmarks (`select option::checkmark`), and rotating chevrons (`select:open::picker-icon`).
- Applied universally across `/manage` storage retention policy, playback speed (`#speed`), and in-player subtitle settings modal dropdowns.

### Live Seek Hover Preview Thumbnails
- Implemented `app/services/preview_service.py` with fast keyframe extraction (`-ss` before `-i`) and server-side disk caching under `cache/previews/`.
- Integrated into YouTube-style seekbar with responsive viewport boundary clamping.

### Persistent Windows Services
- Registered `MediaServer` (Waitress WSGI on `127.0.0.1:8000`) as an automatic Windows Service using NSSM with crash auto-recovery and 10 MB log rotation.
- Registered `Cloudflared` as an automatic Windows Service for named tunnel routing (`media.anisparvez.in`).

---

## 3. Active Next Steps & Immediate Queue

1. **Production Concurrency Tuning & Benchmarking:**
   - Benchmark Waitress worker and thread pools against remote stream latency and Cloudflare tunnel limits.
   - Remote streaming capacity is primarily bounded by ISP upload bandwidth and network tunnel latency.

2. **Access Control & Authentication:**
   - Prepare lightweight authentication before wider public sharing beyond personal devices.

---

## 4. Verification & Testing

Before committing changes, execute:

```powershell
# Compile validation
python -m py_compile app/config.py app/services/transcode_service.py app/services/chunk_transcode_service.py app/services/gpu_service.py

# Automated Test Suite (164 tests)
.\venv\Scripts\python.exe -m pytest tests/
```

Manual verification checklist:
1. Direct MP4/AAC playback (*Oculus*, *Spider-Man*).
2. MKV/HEVC HLS playback (*The Odyssey*, *Moana*, *Coyote vs. Acme*).
3. Seek to `0:00` and arbitrary forward/backward timestamps without timeline freezing.
4. Hover seekbar displays frame preview thumbnails.
5. System Telemetry HUD reports active GPU engine utilization.
6. Storage Retention & Cache Governance card on `/manage` reports accurate cache and storage telemetry.
7. Expanded dropdown options display obsidian frosted glass popups with brand red highlights.
8. No horizontal or vertical layout overflow on desktop or mobile viewports.
