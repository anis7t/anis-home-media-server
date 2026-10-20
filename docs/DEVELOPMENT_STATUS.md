# Development Status / Session Handoff

Last updated: 2026-10-05
Repository: `anis7t/media-server`
Active Working branch: `feat/flutter-production-player` (the branch bullets under
*Branch Structure* below are historical and describe the earlier
`feat/unified-header-navigation` / `feat/storage-retention-cache-purge` split)

## 1. Branch Architecture & Environment State

- **Branch Structure:**
  - `feat/storage-retention-cache-purge` (at `9cf8d21`): Pure backend engine branch containing storage retention policies, dual-drive tiering (`E:` fast SSD for runtime/cache/database vs `D:\Flicks` mass storage), cross-drive cache/subtitle resilience, and multi-chunk HLS discontinuity alignment.
  - `feat/unified-header-navigation` (at `6c6e6c6`): Pure frontend & UX branch containing the frosted obsidian navigation redesign, 3D play brand identity, responsive swipeable mobile action rails, desktop search bar density polish, universal customizable select styling (`appearance: base-select`), and Chromium Hls.js precedence.
- **Environment:** Windows 11 Home / Workstation
- **Tested Hardware:** AMD Ryzen 5 3550H, 16 GB RAM
- **Discrete GPU:** AMD Radeon RX 560X (4GB VRAM) — Task Manager GPU 0 / FFmpeg `dx11:1`
- **Integrated GPU:** AMD Radeon Vega 8 Graphics — Task Manager GPU 1 / FFmpeg `dx11:0`
- **Python:** 3.14.3 — **tooling only.** The venv (`E:\MediaServer\venv`) exists for the probe and
  release scripts; the server itself is native Rust and needs no Python. See `requirements.txt`.
- **FFmpeg:** 9.0.1 essentials build with AMF & D3D11va
- **Caddy:** `E:\MediaServer\bin\caddy_custom.exe` (Cloudflare DNS module) — the public ingress
- **Flutter:** 3.47.6 stable (`D:\src\flutter`), bundling **Dart 3.13.5**
- **Android SDK:** `D:\platform-tools-latest-windows` (see the misnomer note below); platform-tools 37.0.1, build-tools 36.0.0, platforms android-35/36, NDK 28.2.13676358, emulator 37.2.12
- **Node:** v25.7.0 · **npm:** 11.10.1 · **opencode:** 2.0.11

### The Flutter SDK carries a local patch — do not `--force` an upgrade

`D:\src\flutter` is **not** a pristine checkout. It has an uncommitted local change to
`packages/flutter_tools/lib/src/windows/visual_studio.dart` (+35 lines) that teaches
Flutter where to find the Windows 10 SDK when the registry does not list it. The
lookup order it adds is:

1. the `WindowsSdkDir` environment variable (set to `D:\WindowsKits\10\`)
2. `HKEY_CURRENT_USER\SOFTWARE\Microsoft\Microsoft SDKs\Windows\v10.0`
3. the hardcoded fallbacks `D:\WindowsKits\10` and `C:\Program Files (x86)\Windows Kits\10`

Without it, `flutter doctor` reports `[!] Unable to locate a Windows 10 SDK` and the
Windows desktop target cannot be built.

**`flutter upgrade --force` erases this silently.** The safe sequence is:

```powershell
git -C D:\src\flutter diff -- packages/flutter_tools/lib/src/windows/visual_studio.dart `
     > E:\MediaServer\docs\flutter-winsdk-location-patch.diff     # back it up FIRST
git -C D:\src\flutter stash push -- packages/flutter_tools/lib/src/windows/visual_studio.dart
flutter upgrade
git -C D:\src\flutter stash pop
Remove-Item D:\src\flutter\bin\cache\flutter_tools.stamp          # force tool rebuild
flutter doctor                                                   # expect [√] Visual Studio
```

The `flutter_tools.stamp` deletion is **not optional**. `stash pop` restores the
source with a *newer* mtime than the compiled tool snapshot, and `flutter doctor` will
otherwise keep reporting the SDK as missing even though the patch is back — which looks
exactly like the upgrade having broken the Windows build. Deleting the stamp makes
`flutter` rebuild `flutter_tools` from the patched source.

A copy of the patch is committed at `docs/flutter-winsdk-location-patch.diff`.

### `D:\platform-tools-latest-windows` is not just platform-tools

The directory name is misleading: it is a **complete Android SDK** (build-tools, NDK,
platforms, emulator, system-images, cmdline-tools, cmake). `ANDROID_HOME` and
`ANDROID_SDK_ROOT` both point at it, as does `sdk.dir` in
`flutter_client\android\local.properties`.

**There are six `adb.exe` copies on this machine and two are on `PATH`:**

| Path | Version | Role |
| --- | --- | --- |
| `D:\platform-tools-latest-windows\platform-tools\adb.exe` | 37.0.1-15733141 | The SDK copy. First on `PATH`; referenced by the env vars and Flutter. |
| `C:\Users\anis7\AppData\Local\Microsoft\WinGet\Packages\Genymobile.scrcpy_…\adb.exe` | 37.0.0-14910828 | Bundled inside scrcpy v4.1. Second on `PATH`. |

Four further copies sit off-`PATH` and are stale: `D:\ChangZhi\LDPlayer\` (2021),
`D:\Current Download\scrcpy-win64-v1.24\` (2022), `D:\New folder (4)\` (2019),
`D:\RFO-BASIC! Quick APK\tools\` (2014).

This matters because the adb **server** on tcp:5037 is owned by whichever client
started it. The two `PATH` copies differ, so launching scrcpy's bundled client against
a server the SDK copy started forces a version-mismatch restart — the usual
"device offline" symptom. `flutter doctor` flags it as
`! Multiple adb binaries found`.

```text
Project:       E:\MediaServer
Media root:    D:\Flicks
Upload root:   D:\Flicks\.uploads -> D:\Flicks (high-capacity storage pool on D:)
Archive root:  D:\Flicks\.archive (cold source retention on D:)
Deleted root:  D:\Flicks\.deleted (deleted-source staging on D:)
Transcode:     E:\MediaServer\cache\hls (fast SSD generation & delivery)
Previews:      E:\MediaServer\cache\previews (seek thumbnail frame cache)
Database:      PostgreSQL 18.4 - media_server @ 127.0.0.1:5432 (data E:\pgdata)
Backups:       E:\MediaServer\backups\postgres (pg_dump -Fc; see docs/BACKUP_AND_RESTORE.md)
Test database: media_server_test (created by rust/src/test_support.rs - never use production)
Storage pool:  D: + E: aggregated (per-drive breakdown in /api/system-status)
Note:          C: is not used by this project.
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
- **Headroom Optimization:** Preserves the primary fast SSD `E:` (`E:\MediaServer`) for the application and runtime, the PostgreSQL data directory (`E:\pgdata`), transcode scratch, seek thumbnails (`cache\previews`), and completed multi-GPU HLS caches (`cache\hls`).
- **Secondary Mass Storage (`D:`):** Offloads multi-gigabyte raw video files (`D:\Flicks`), resumable upload staging (`D:\Flicks\.uploads`), cold source archives (`D:\Flicks\.archive`), and deleted-source staging (`D:\Flicks\.deleted`).
- **Dynamic Multi-Root Discovery:** `config.get_media_roots()` returns all active storage roots. All routing, authorization, and media scanning procedures validate against all configured roots.
- **Deterministic Cache Continuity:** `hls_cache_dir()` and `preview_dir()` compute relative paths across all active roots, ensuring media files moved or archived between drives retain their deterministic cache keys and active streams.
- **Cross-Root Subtitle Mirror Discovery:** Resolves sidecar `.srt`/`.vtt` files across mirror subdirectories in any active drive root (stripping `.archive` subpaths).

### Post-Transcode Storage Retention & Safe Orphaned Cache Purge
- **Configurable Retention Policies:** User-configurable retention actions (`keep`, `archive`, `delete_source`) persisted in SQLite settings.
- **Zero-Byte Corruption Fix (2026-09-20):** Fixed critical bug where `delete_source` policy truncated source files to 0 bytes, causing infinite re-transcoding loops that overwrote valid HLS caches.
  - Changed `apply_post_transcode_policy()` to **move source files to `.deleted` staging area** (`D:\Flicks\.deleted`) instead of truncating
  - Added defensive size check in `is_video()` (`p.stat().st_size > 0`) to prevent zero-byte files from being discovered
  - Source files now recoverable from staging until manual cleanup
- **HLS Cache Preservation Fix (2026-09-20):** Fixed `_is_hls_truly_complete()` to treat any playlist with `#EXT-X-ENDLIST` as complete (ENDLIST is the authoritative FFmpeg completion signal). Previously, caches with ENDLIST but EXTINF duration sums < 90% of source duration were incorrectly flagged incomplete and purged by cache maintenance. This prevented accidental loss of valid completed transcodes.
- **Automated Orphaned Cache Auditing:** `audit_orphaned_caches()` reconciles `cache/hls/` and `cache/previews/` against active video files and in-flight transcode jobs.
- **Safe Orphaned Cache Purge:** `purge_orphaned_caches()` with bounded Windows file-lock retries, triggered automatically on server launch and via background worker every 2 hours. Reclaimed 57 orphaned cache directories.
- **Management UI:** Storage Retention & Cache Governance card on `/manage` with live storage pool telemetry, interactive policy selector, and clean orphaned caches modal (`#cleanOrphansModal`).

### Unified Frosted Obsidian Navigation Header & Brand Identity
- **Consistent Top Navigation:** Redesigned frosted obsidian glass header across all 5 pages (`/`, `/movie/<filename>`, `/player/<filename>`, `/manage`, `/devices`).
- **3D Glossy Play Brand Icon:** Vector SVG with radial crimson gradients, specular highlights, and ambient drop shadows, paired with two-tone typography (**Anis'** + **Home Media Server**) and tagline (**PLAY • ORGANIZE • ENJOY**).
- **Desktop & Mobile Search Density Polish:** Completely removed the redundant A-Z sort dropdown across both desktop and mobile views, prioritizing natural library browsing and direct search input filtering.
- **Home Page Content Hierarchy (Telemetry at Footer):** Repositioned the System Telemetry HUD (`#systemTelemetryCard`) to the bottom of the home page (strictly after "All Movies"), prioritizing user media rails while keeping technical stats accessible at the footer.
- **Mobile Player Controls Expansion & Dedicated Seekbar Spacing:** Restored primary controls (`↺` Restart, `▶`/`⏸` Play, `🔊` Mute, `1×` Speed, `CC ⚙` Subtitles/Settings, Aspect Ratio, Rotate Screen, PiP, Nerd Stats) on mobile inside a swipeable non-overflowing rail (`overflow-x: auto`), cleanly hid desktop-only controls (`#volume` and `#shortcutsBtn`), explicitly hid redundant `-10s`/`+10s` buttons on mobile in favor of seekbar/double-tap gestures, and eliminated the dead space between `.seek-time-row` and seekbar (`margin-bottom: -9px !important`).
- **Interactive User Manual & Footer "How to use":** Added `/manual` route with obsidian glass feature guide, category navigation pills, shortcut tables, and unified footer link across all pages. Created `docs/MANUAL.md`.


### Universal Customizable `<select>` Popovers
- Implemented modern Customizable Select API using `appearance: base-select` and `select::picker(select)`.
- Replaced sharp, bright blue Windows system select menus with top-layer frosted obsidian glass popups (`rgba(18, 22, 32, 0.96)`, `backdrop-filter: blur(24px)`), rounded corners, brand red active highlights (`#e50914`), white checkmarks (`select option::checkmark`), and rotating chevrons (`select:open::picker-icon`).
- Applied universally across `/manage` storage retention policy, playback speed (`#speed`), and in-player subtitle settings modal dropdowns.

### Live Seek Hover Preview Thumbnails
- Implemented `app/services/preview_service.py` with fast keyframe extraction (`-ss` before `-i`) and server-side disk caching under `cache/previews/`.
- Integrated into YouTube-style seekbar with responsive viewport boundary clamping.

### Persistent Windows Services
- `MediaServerRust` — the native Rust Axum backend on `0.0.0.0:8000`, serving the React 19 SPA and every `/api/*`, `/media/*`, `/hls/*`, `/subtitles/*`, `/auth/*` route. Automatic Windows Service via NSSM, with crash auto-recovery and log rotation.
- `MediaServerCaddy` — the reverse proxy and TLS terminator on ports 80/443, fronting `127.0.0.1:8000` with a Let's Encrypt certificate. Automatic Windows Service via NSSM.
- `MediaServerPG` — PostgreSQL 18.4 on port 5432, running as `NetworkService` with restart-x3 recovery actions. Binaries at `C:\postgres`, data at `E:\pgdata`.

NSSM itself lives at `C:\MediaServer\bin\nssm.exe` and the PostgreSQL binaries at `C:\postgres`, so both survive the `E:` volume being absent — the `E:` glitch of 2026-10-16 took all three services down before that relocation.

The legacy `MediaServer` (Waitress / Flask) and `Cloudflared` services have been **decommissioned and removed**. The backend is 100% native Rust and the frontend is a 100% React SPA.

### QR Device Sign-In (OTT Activation Flow)
- Six native endpoints under `/api/auth/qr/*` (`create`, `lookup`, `wait` [SSE], `status`, `confirm`, `finalize`) backed by the `device_pair_sessions` table, plus a `/remotelogin` page for the phone and a `<QrSignInPanel>` on `/account` for the TV or browser.
- Every security token (the 5-character pair code, the `qr_id`, session tokens, device tokens, the OAuth `state`/`nonce`, the PKCE verifier) is drawn from the operating system's CSPRNG via `getrandom`, and **fails closed** if the random source is unavailable.
- The pair code carries **25 bits** of entropy (5 characters from a 32-symbol unambiguous charset). The original implementation collapsed to 32 possible codes because all five characters were derived from the low bits of one LCG state word — see [`docs/QR_SIGNIN_WALKTHROUGH.md`](QR_SIGNIN_WALKTHROUGH.md) §4.1.
- The pair code and the full `qr_id` are **never logged**; only a 12-hex-character reference is.

---

## 3. Active Next Steps & Immediate Queue

1. **Close the public `:8000` origin forward:**
   - The router forwards 443, 80 **and 8000** to the host, so `http://122.163.124.18:8000/health` answers 200 from the internet, bypassing Caddy and TLS entirely. Port 8000 should not be forwarded.
2. **Add `Secure` to the session cookie:**
   - Pre-existing and codebase-wide — `auth.rs:345,405,424,467` and `qr_auth.rs:345` are all identical. Do this *after* the forward above, or LAN clients break.
3. **Pin a public base URL:**
   - `get_base_url` in `qr_auth.rs` trusts the `Host` and `X-Forwarded-Proto` request headers, so the emitted `qr_url` is host-header-injectable and defaults to `https` even on a plain-HTTP origin. Add `PUBLIC_BASE_URL` to `AppConfig`.
4. **Bind `/finalize` to the waiting device:**
   - It is unauthenticated and keyed only on the `qr_id`. A per-session secret issued at create time would close it.
5. **Rate-limit the QR endpoints and cap concurrent SSE connections:**
   - `GET /api/auth/qr/{id}/wait` spawns a task plus a PostgreSQL query every 3 seconds per connection, with no auth and no cap, on a publicly reachable endpoint.
6. **Drop the plaintext `code` column** from `device_pair_sessions`; only `code_hash` is needed for lookup. Needs an `ALTER` on the live table.
7. **Fix the stale `vite.config.ts` dev proxy** — it still points `/api` at the decommissioned Flask `:8000`, so `npm run dev` fails for every API call.

---

## 4. Verification & Testing

Before committing changes, execute:

```powershell
# Rust backend: unit + integration tests (26 targets, 108 unit tests)
cd E:\MediaServer\rust
cmd /c "e:\MediaServer\scripts\cargo.bat test --no-fail-fast -- --test-threads=1"

# React frontend: unit tests, typecheck, production build
cd E:\MediaServer\web
npm run test
npm run typecheck
npm run build

# Live client contract probe (22 endpoints)
python scripts\probe_android_api.py
```

### Test database isolation — do not skip this

**The Rust integration suite must never touch the production database.**
`AppConfig::from_env()` falls back to `postgresql://postgres:postgres@127.0.0.1:5432/media_server`
when `MEDIA_SERVER_DATABASE_URL` is unset, and on this host it *is* unset. A test built on
`from_env()` therefore writes to the live catalog.

Use `media_server_api::test_support::test_config().await` instead. It provisions a dedicated
`media_server_test` database (override with `MEDIA_SERVER_TEST_DATABASE_URL`), redirects the cache
directory to a temp path, and leaves the media roots alone so file-based contracts still work.
`seed_real_media_row()` / `remove_seeded_media_row()` seed and remove a catalog row for a real,
probeable media file when a test needs one.

A test that inserts rows must use `ON CONFLICT … DO UPDATE` **and** purge at setup **and** have an
explicit `async fn teardown()`. `Drop` cannot clean a database — it is synchronous, the database
calls are async — and the test should assert the residue count is zero rather than trusting the
hook. Do not assert against production data: a test that hardcodes a library title breaks when
that title is removed.

Manual verification checklist:
1. Direct MP4/AAC playback (*Oculus*, *Spider-Man*).
2. MKV/HEVC HLS playback (*The Odyssey*, *Moana*, *Coyote vs. Acme*).
3. Seek to `0:00` and arbitrary forward/backward timestamps without timeline freezing.
4. Hover seekbar displays frame preview thumbnails.
5. System Telemetry HUD reports active GPU engine utilization.
6. Storage Retention & Cache Governance card on `/manage` reports accurate cache and storage telemetry.
7. Expanded dropdown options display obsidian frosted glass popups with brand red highlights.
8. No horizontal or vertical layout overflow on desktop or mobile viewports.
9. **QR sign-in on a camera-less device:** `/account` shows the QR panel when unauthenticated, the code rotates after 2 minutes, and a phone at `/remotelogin` can complete the pairing and name the device.
10. **Pair-code entropy:** creating 200 pairing sessions must yield ≥ 190 distinct codes, and the service log must contain neither the code nor a full `qr_id`.
