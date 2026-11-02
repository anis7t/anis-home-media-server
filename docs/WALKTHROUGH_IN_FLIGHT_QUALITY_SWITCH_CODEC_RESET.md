# Walkthrough: In-Flight Quality Switch Codec Reset & Server Access Logging

## Summary of Changes
Resolved the in-flight quality switch playback freeze on Android when transitioning between Direct Play and non-direct transcoded streams (e.g. *Verity 2026 1080p WEB-DL HEVC x265 5.1 BONE.mkv*). Enabled persistent, structured server-side HTTP access logging in Caddy to trace client interactions.

---

## 1. Key Problem & Root Cause Resolution

### Problem
When watching a movie in Direct Play on Android, switching quality to 1080p HLS caused the playback to stay frozen at the current timestamp (~50m 28s) without buffering and without playing forward.

### Root Causes
1. **Hardware Decoder Codec Mismatch:** Direct Play used HEVC/H.265 in an MKV container, decoded by Android's hardware `MediaCodec` onto `libmpv`'s `SurfaceTexture`. 1080p HLS used H.264/AVC in fragmented MP4. Calling `player.open()` on an already-running player without an explicit `await player.stop()` failed to release the hardware decoder, locking up the surface on the format switch.
2. **Premature Seek Collision:** Calling `player.seek(startPosition)` immediately after `player.open()` while duration was still `0` or libmpv was in the middle of demuxing the 121-chunk HLS playlist interrupted the demuxer.
3. **Watchdog Fallback Trap:** When the playback position did not advance after 4s, the watchdog executed `setProperty('hwdec', 'no')`. On Android `libmpv`, dynamically toggling `hwdec` on an active stream without a reload does not recover a stalled `MediaCodec`.

---

## 2. Changes Implemented

### A. Server Access Logging (`Caddyfile`)
- Configured JSON access logging in `E:\MediaServer\Caddyfile` (and mirrored in `C:\MediaServer\Caddyfile` for compatibility) for `media.anisparvez.in`.
- Log path: `E:\MediaServer\logs\caddy_access.log` with automatic roll size of 10 MB and retention of 3 backup files.
- Verified live: Tested requests through Caddy; incoming HTTP requests with timestamp, status code, client IP, URI, and duration are now logged.

### B. Client Player Lifecycle (`flutter_client`)
- **Clean Hardware Decoder Teardown (`MediaKitPlayerAdapter.open`):**
  If the player is currently playing, has a non-zero position, or has media loaded in its playlist, `open()` explicitly executes `await player.stop()`. This flushes previous decoder buffers and tears down any active `MediaCodec` instance before the new format is initialized.
- **Native Timeline Anchoring:**
  `startPosition` is passed via `Media(url, start: startPosition)` and `setProperty('start', sec)` prior to open.
- **Eliminated Premature Seek & Added Duration-Guarded Verification:**
  Removed the immediate `player.seek(startPosition)` call right after `player.open()`. Added a one-time duration listener (`player.stream.duration.firstWhere((d) => d > Duration.zero)`) that only issues a corrective seek if the demuxed stream position drifts by more than 3 seconds after loading.
- **Watchdog Hardening:**
  Increased watchdog window to 8 seconds and added a `!player.state.buffering` guard so cellular network latency is not falsely treated as a hardware decoder lockup.

### C. Release 1.4.4 (versionCode 150)
- Built and published Android release 1.4.4 (`versionCode: 150`) via `scripts/release_android.py`.
- Verified manifest endpoint at `/api/app/update?channel=production`.

---

## 3. Verification & Test Results

### 1. Static Analysis
```powershell
flutter analyze
```
**Outcome:** `No issues found! (ran in 7.7s)` — 0 warnings, 0 errors.

### 2. Player Unit & Widget Tests
```powershell
flutter test test/features/player/
```
**Outcome:** All 121 tests passed cleanly (`+121 ~6: All tests passed!`).

### 3. Server-Side Access Logging Verification
Tested endpoint: `https://media.anisparvez.in/api/app/update?channel=production`  
Verified entry written to `E:\MediaServer\logs\caddy_access.log`:
```json
{
  "level": "info",
  "ts": 1793621546.8913581,
  "logger": "http.log.access.log0",
  "msg": "handled request",
  "request": {
    "client_ip": "192.168.1.1",
    "method": "GET",
    "host": "media.anisparvez.in",
    "uri": "/api/app/update?channel=production"
  },
  "status": 200,
  "duration": 0.0026742
}
```

### 4. Release Publication Verification
```powershell
curl.exe -s "http://127.0.0.1:8000/api/app/update?channel=production"
```
**Response:**
```json
{
  "apkUrl": "/api/app/download?channel=production",
  "channel": "production",
  "fileSizeBytes": 102627725,
  "gitCommit": "ba6f980",
  "mandatory": false,
  "minAndroidSdk": 24,
  "minSupportedVersionCode": 1,
  "packageId": "in.anisparvez.media_server_client",
  "releaseDate": "2026-11-02T12:11:30.327896+00:00",
  "releaseNotes": "In-flight quality switch codec reset and HLS timeline unfreeze",
  "sha256": "c80d4b941093e10919aa1abbc6ad0edf8ecc8000a0464fd80a7717d95b01fa8d",
  "targetAndroidSdk": 36,
  "version": "1.4.4",
  "versionCode": 150
}
```
APK ready for download directly in the AHMS Android app.
