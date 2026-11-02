# Implementation Plan: In-Flight Quality Switch Codec Reset & Server Access Logging

## Context & Problem Statement
When streaming non-direct media (e.g. *Verity 2026 1080p WEB-DL HEVC x265 5.1 BONE.mkv*) in the Android Flutter app:
1. Seeking from the beginning on 1080p HLS works smoothly without buffering (confirmed in Release 1.4.2 after removing `#EXT-X-START:TIME-OFFSET=0`).
2. However, switching quality *in-flight* (e.g. from Direct Play to 1080p HLS) causes playback to freeze on the existing frame at the current timestamp (~50m 28s / 3028s) without buffering and without advancing.
3. Furthermore, exact client HTTP requests were not logged in `rust_api.log` because Axum's `tower_http` trace layer logs HTTP 200 at `DEBUG` (server configured at `INFO`), and Caddy lacked file-based access logging.

### Root Causes
- **Codec & Hardware Surface Collision:** Direct Play uses HEVC/H.265 in MKV decoded by Android's hardware `MediaCodec` onto `libmpv`'s `SurfaceTexture`. 1080p HLS uses H.264/AVC in fragmented MP4. Calling `player.open()` on an already-running player without an explicit `player.stop()` leaves the previous `MediaCodec` pipeline active, deadlocking the surface on the format change.
- **Premature Seek Collision:** Calling `player.seek(startPosition)` immediately after `player.open()` while duration is still 0 or the 121-chunk playlist is still demuxing sends an interrupt to libmpv's demuxer, halting playback.
- **Watchdog Fallback Trap:** After 4 seconds of stalled position, `setProperty('hwdec', 'no')` was executed dynamically on the running player, which mpv ignores without a stream reload.

---

## 1. Scope

### In Scope
1. **Server-Side Access Logging:**
   - Add structured JSON access logging to `E:\MediaServer\Caddyfile` for `media.anisparvez.in`, writing to `E:\MediaServer\logs\caddy_access.log` with automatic log rotation (10 MB, 3 files).
   - Gracefully reload Caddy configuration via `caddy reload`.
2. **Client Playback Engine Refactoring (`flutter_client`):**
   - In `MediaKitPlayerAdapter.open()`:
     - If the player is already playing or has media loaded, explicitly `await player.stop()` before opening the new stream. This flushes decoder queues and tears down active `MediaCodec` hardware pipelines cleanly.
     - Supply `startPosition` exclusively via `Media(url, start: startPosition)` and native `setProperty('start', ...)` before open.
     - Eliminate the premature `await player.seek(startPosition)` call right after `player.open()`.
     - Implement a duration-ready listener that verifies the stream has loaded its duration and timeline before applying any corrective seek if necessary.
     - Ensure the first-frame watchdog cancels cleanly on `stop()` and does not invoke deadlocked `setProperty('hwdec', 'no')` calls without reloading.
3. **Automated Testing & Release Packaging:**
   - Update unit and widget tests in `flutter_client/test/features/player/` to cover `player.stop()` invocation during quality switch.
   - Run `flutter analyze` and `flutter test`.
   - Build Release 1.4.4 (build 150) and publish via `scripts/release_android.py`.

### Deliberately Out of Scope
- Modifying backend transcode chunking logic or HLS segment packaging (verified working and healthy).
- Altering the React web player or Fire TV D-pad navigation structures.

---

## 2. Exit Criteria
- [ ] `E:\MediaServer\logs\caddy_access.log` actively logs incoming HTTP requests with timestamp, status code, URI, and remote client IP.
- [ ] `MediaKitPlayerAdapter` cleanly stops previous decoding sessions before opening a new media format.
- [ ] `flutter analyze` passes with 0 warnings or errors.
- [ ] All Flutter player tests pass cleanly.
- [ ] Release 1.4.4 (versionCode 150) APK built, hashed, and published to `web/dist/releases/production.json`.
- [ ] Remote client can switch from Direct Play to 1080p HLS in-flight and resume playback smoothly from the exact timestamp.

---

## 3. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| `player.stop()` causes a brief black frame during quality switch | Minor visual flash | The player UI maintains the title, HUD toast ("Quality: 1080p"), and seek bar position. A 200-300ms clean decoder re-init is vastly superior to a permanently frozen frame. |
| Caddy reload drops active TLS connections | Network interruption | `caddy reload` executes graceful, zero-downtime configuration swapping. Active connections drain naturally while new requests use the updated logging handler. |
| Stale start position applied on unrelated media opening | Incorrect playback start | `startPosition` is only passed when explicitly provided by the caller (e.g. quality switch or resume from history); standard playback begins at 0. |

---

## 4. Open Decisions
- None identified. Standardizing on `player.stop()` prior to format change and native `Media(start: ...)` is the recommended and supported pattern in `package:media_kit`.
