# Flutter Client — Phase Status & Handoff

> **Last updated:** 2026-09-25
> **Active branch:** `feat/flutter-production-player`
> **Source conversations:** `8478b150-1239-4291-9a25-9155d6f2ad87` (Phase 1 & 2 work), `995057c0-0007-447a-93e5-ea547828e71c` (Phase 2 fixes, Phase 3A/3B, Android native)
> **Purpose:** Persistent handoff document. Read this before touching the Flutter client.

---

## Phase Overview

| Phase | Title | Status |
|-------|-------|--------|
| 1 | Flutter Client Foundation | COMPLETE — committed (`5b0b1fa`, `eadb257`) |
| 2 | Video Player Proof-of-Concept | COMPLETE — all 6 stages verified on LAN & WAN (`f8e8c23`) |
| 3A | Production Player Core Architecture | COMPLETE — committed on `feat/flutter-production-player` |
| 3B | Android-First Timeline & Live Seek Preview | COMPLETE — committed (`2e95246`) |
| Android Native | Physical Device Engine (`libmpv.so`) | COMPLETE — Vivo I2217 (Android 16, SDK 36, NDK 28) |
| 3C | Audio & Subtitle Track Selectors, Speed & Controls Polish | COMPLETE — verified 58/58 tests, zero analyzer issues |
| 4 | Library Browsing & Media Ingestion UI | NEXT |

---

## Phase 3C — Audio & Subtitle Track Selectors, Playback Speed, & Controls Polish (DONE)

**Goal:** Deliver Android-first bottom sheets for track selection, variable playback rate, transient HUD action feedback, and Android system navigation handling.

### Key Achievements:
- **`PlaybackSpeedSheet`:**
  - Obsidian glass modal bottom sheet supporting `0.5×`, `0.75×`, `1.0× (Normal)`, `1.25×`, `1.5×`, `2.0×`.
  - Accessible \(\ge 52\)dp touch targets with brand accent highlight and active checkmark.
- **`AudioTrackSheet` & `SubtitleTrackSheet`:**
  - `AudioTrackSheet`: Displays channels, audio codec, and language tags; seamlessly switches audio stream in real-time.
  - `SubtitleTrackSheet`: Supports turning subtitles Off, selecting embedded demuxed tracks, or sidecar WebVTT files discovered via `GET /api/subtitles/<path:filename>`. External sidecar tracks are marked with an `EXT` badge.
- **In-Player Action HUD (`PlayerHudToast`):**
  - Translucent floating HUD pill positioned above controls for immediate visual confirmation of player state changes (e.g. `1.25× Speed`, `Subtitles: English`, `Muted`, `+10 sec`).
- **Android System Back & Lifecycle Handling:**
  - Wrapped `PlayerScreen` in `PopScope(canPop: false)` with custom back handler.
  - Gracefully exits native fullscreen, cancels active auto-hide and HUD timers, aborts in-flight network tokens (`_subtitlesCancelToken`, `_previewCancelToken`), stops playback engine, and completes navigation.
- **Controls Overlay Polish & Transparency:**
  - Replaced opaque solid gradient with translucent soft gradient (`Colors.black.withValues(alpha: 0.50)` fading to `Colors.transparent`), preserving full visibility of video frames and subtitles behind controls.
  - Symmetrical equidistant seekbar vertical clearance: balanced vertical gap (~6dp) above and below the timeline track.
  - Dual-time anchors: Elapsed time anchored on the left, total runtime / remaining time anchored on the right (`MainAxisAlignment.spaceBetween`) with tap-to-toggle remaining time (`-remaining`).
  - Circular white scrubber thumb with elevation shadow matching web player aesthetic.
  - Added Replay `↺` button as the first control action, followed by Play/Pause `⏸`/`▶`, Mute `🔊`, Speed `1×`, Audio, and Subtitles.
  - Responsive mobile clamping: volume slider automatically hidden on compact widths (< 620dp) where physical hardware volume buttons handle audio, preserving button spacing.
  - Keyboard shortcuts mapped for desktop: `Home` / `0` (Restart), `C` (Subtitles), `Up` / `Down` (Volume ±5%), `Left` / `Right` / `J` / `L` (±10s Seek), `Space` / `K` (Play/Pause), `M` (Mute), `F` / `Escape` (Fullscreen).
- **Direct-to-Player Intent Routing & Dynamic Server Resolution:**
  - Implemented `getInitialRoute()` and `getDartEntrypointArgs()` overrides in `MainActivity.kt` and `--route`, `--server`, and `--media-url` argument parsers in `lib/main.dart`.
  - Added dynamic fallback resolution in `PlayerScreen`: when cold-booting directly into `/player`, localhost fallback URLs are automatically rewritten to the saved active server URL from `SettingsService` or connection state (`http://192.168.1.16:8000`), resolving connection refused errors on physical devices.
  - Enables instant 1-second cold boot directly into live video playback (`adb shell am start -n in.anisparvez.media_server_client/.MainActivity --es route "/player"`) bypassing intermediate manual connection screens.
- **Automated Validation:**
  - `flutter test`: 58/58 tests passed across unit, widget, and live integration suites.
  - `flutter analyze lib test`: 0 issues found.
  - Verified live on physical hardware (Vivo I2217, Android 16) with instant intent routing and live video playback.

---

## Next Up — Phase 4 (Library Browsing & Media Ingestion UI)

- Home / Library movie browsing grids with cached posters and media metadata badges.
- Search and sorting filters (Alphabetical, Recently Added, Watch Progress).
- Movie details sheet / screen with TMDb synopsis, cast rail, and stream options.


---

## Phase 1 — Flutter Client Foundation (DONE)

Committed on `feat/flutter-player-poc`:

```
eadb257  feat: initialize Flutter media client with connection screen,
               media player POC, and core architecture
5b0b1fa  feat: add Flutter client foundation
```

### What was built

- `flutter_client/` — standalone Flutter project (Windows desktop target)
- `lib/core/` — shared utilities, device identity, server config
- `lib/features/connection/` — server connection screen + live registration
- `lib/features/player_poc/` — player POC feature (see Phase 2)
- `flutter_client/test/` — 24 passing unit + integration tests
- `pubspec.yaml` — `media_kit` + `media_kit_video` + `media_kit_libs_windows_video`

### Verified at sign-off

- `flutter doctor -v` — Windows toolchain green
- `flutter analyze` — zero issues
- 24/24 `flutter test` pass (including live server HTTP contract tests)
- Live server connection from Flutter app to `http://192.168.1.16:8000` confirmed

---

## Phase 2 — Video Player Proof-of-Concept (IN PROGRESS)

**Goal:** Technical validation only — not a production player. Proves that
`media_kit`/libmpv can handle all server media types and network topologies
before any production UI is built.

### Architecture

```
PlayerPocScreen  (UI harness + automated test battery)
    |
PlayerControllerInterface  (pure abstract contract)
    |
MediaKitPlayerAdapter  (wraps media_kit Player + VideoController)
    |
media_kit / libmpv
    |
Media Server  (RFC 7233 range, HLS, seek-preview, device auth)
```

### Key files

| File | Role |
|------|------|
| `flutter_client/lib/features/player_poc/domain/player_controller_interface.dart` | Abstract player contract |
| `flutter_client/lib/features/player_poc/infrastructure/media_kit_player_adapter.dart` | media_kit implementation |
| `flutter_client/lib/features/player_poc/presentation/player_poc_screen.dart` | Harness UI + automated test battery |
| `flutter_client/tool/wan_player_probe.dart` | Standalone CLI WAN probe (headless) |
| `flutter_client/tool/runtime_player_validator.dart` | Runtime validator tool |

### Test candidates (real library media)

| # | Candidate | Route type | Filename |
|---|-----------|------------|----------|
| 1 | Batman Knightfall Pt 1 2026 | Direct MP4 | `Batman Knightfall Part 1 2026 1080p WEBRip x264 AAC5 1-[YTS GG - YTS BZ].mp4` |
| 2 | Spider-Man: Brand New Day 2026 | HLS / multi-GPU | `Spider-Man- Brand New Day 2026.1080p.HQ Pre.Multi.AAC 2.0.x264.mkv` |
| 3 | Lust Stories 3 2026 | HLS + external SRT | `Lust Stories 3 2026.1080p.NF.WEB-DL.Multi.DD+ 5.1.x264-KIN.mkv` |
| 4 | I Want Your Sex 2026 | HLS + HEVC 10-bit + EAC3 | `I.Want.Your.Sex.2026.1080p.WEBRip.10Bit.DDP5.1.x265-NeoNoir.mkv` |

### Stage status

| Stage | Description | LAN Status | WAN Status |
|-------|-------------|------------|------------|
| 2A | Direct MP4 playback (Batman) | PASS | PASS |
| 2B | HLS multi-GPU stream (Spider-Man) | PASS | PASS |
| 2C | Seeking + checkpoint resume | FIXED (commit `f8e8c23`) | FIXED (commit `f8e8c23`) |
| 2D | Subtitles + HEVC 10-bit | PASS | PASS |
| 2E | Seek-preview frame scrubbing | PASS | PASS |
| 2F | Full WAN acceptance report | pending final battery verification | pending final battery verification |

### Fixes applied

#### Fix 1: Polling loops replacing fixed delays (commit `6de915a`)
Replaced every fixed `Future.delayed()` in the battery runners with `_waitFor()` polling helper (300ms intervals with WAN-safe timeouts). Fixed 2B, 2D, 2E across WAN.

#### Fix 2: Native `Media.start` for libmpv checkpoint resume (commit `f8e8c23`)
**Root Cause for 2C Failure on both LAN and WAN:**
In `MediaKitPlayerAdapter.open()`, `Media` was instantiated without its native `start` parameter (`Media(url, httpHeaders: headers)`). Then `player.seek(startPosition)` was called immediately after `player.open(media, play: false)`. Because libmpv had not yet finished asynchronously parsing the demuxer/stream when `seek()` fired, the seek command was discarded by mpv, causing playback to always begin at `0:00` instead of `305s`. As a result, `_position > 290s` timed out after 30 seconds (reaching only ~30s), failing Stage 2C with a ~275s delta.

**Resolution:**
1. Passed `start: startPosition` directly into `Media(..., start: ...)` in `MediaKitPlayerAdapter.open()`. libmpv natively configures `--start=<seconds>` at container demux time, achieving 0ms seek divergence on reopen.
2. Removed redundant premature `player.seek()` on uninitialized streams in `open()`.
3. In `_runStage2C()`, reset `_position = Duration.zero` synchronously on `stop()` to eliminate any stale timestamp reads before reopening at checkpoint.
4. Verified with standalone libmpv diagnostic probe (`seek_resume_probe`): `Media(start: 305s)` converged to exactly 305s with 0ms delta instantly.

### NEXT ACTION — live battery verification

Run the app to verify 2A through 2E all pass:
```powershell
cd C:\MediaServer\flutter_client
& "D:\src\flutter\bin\flutter.bat" run -d windows --release
```

---

## Stage 2F — WAN Validation & Acceptance Report (COMPLETED)

**Date of Verification:** 2026-09-24  
**Test Environment:** Windows 11 x64, Flutter 3.x, `media_kit` + `libmpv-2.dll` (Direct3D 11 backend), Waitress WSGI on `127.0.0.1:8000` (LAN) + Cloudflare Named Tunnel on `https://media.anisparvez.in` (WAN).

### Test Battery Execution Summary

| Stage | Scenario & Asset | LAN Result | WAN Result | Empirical Evidence / Notes |
|-------|------------------|------------|------------|----------------------------|
| **2A** | Direct MP4: Batman Knightfall (1080p, AAC 5.1, RFC 7233) | **PASS** | **PASS** | LAN startup <800ms; WAN startup ~4.1s (buffer ~3.0s, decode at 4.1s). Smooth 1080p playback. |
| **2B** | HLS Multi-GPU: Spider-Man (chunked HLS, monotonic PTS) | **PASS** | **PASS** | Initial stream startup ~7.1s on WAN; bounded runtime test proved continuous playback crossing the 60.0s chunk boundary into Chunk 1 past 68s without stall. |
| **2C** | Seeking & Resume: 0:00 seek, 300s seek, 305s resume | **PASS** | **PASS** | 0:00 settled in <300ms; 300s seek settled in ~275ms; native `Media.start` resume delta 0ms. |
| **2D-sub** | Subtitles: Lust Stories 3 with external sidecar `.srt` | **PASS** | **PASS** | Discovers sidecar English WebVTT/SRT; track switching verified; text cue rendering verified at 152s ("Happy anniversary to you."). |
| **2D-hevc**| Difficult Codecs: I Want Your Sex (HEVC 10-bit, E-AC-3 5.1) | **PASS** | **PASS** | HEVC codec and E-AC-3 5.1 (6-channel, 48kHz) decode cleanly; playback advances smoothly without decode error. |
| **2E** | Seek-Preview Sandbox: Rapid frame thumbnail scrubbing | **PASS** | **PASS** | Frame fetching decoupled from video player; burst debouncing (A->B->C->D) and out-of-order rejection verified. |

---

### The 16 Acceptance Criteria (Evidence-Based Audit)

| # | Acceptance Criterion | Result | Evidence / Notes |
|---|----------------------|:------:|------------------|
| 1 | Direct MP4 playback starts within acceptable latency on LAN | **PASS** | First frame decode in <800ms over local HTTP byte-range stream. |
| 2 | Direct MP4 playback starts within acceptable latency on WAN | **PASS** | Stream buffering and decode completes in ~4.1s through Cloudflare tunnel. |
| 3 | HLS stream plays across chunk boundaries without stalling | **PASS** | Runtime test opened Spider-Man at 52s, crossed the 60.0s boundary into Chunk 1, and continued playing past 68s with continuous position progression (`Buffering: false`). Seamless playback demonstrated; PTS was not independently measured at bitstream level. |
| 4 | HLS stream plays on WAN | **PASS** | Master playlist and chunked TS segments load and play cleanly over WAN (~7.1s initial startup). |
| 5 | Seeking to `0:00` works without freeze | **PASS** | Instant seek to zero, settling in <300ms without freezing or resetting to idle. |
| 6 | Seeking to arbitrary position works | **PASS** | 300s forward seek settles accurately (delta ~275ms) via byte-range requests. |
| 7 | Resume convergence within tolerance (<5s delta) | **PASS** | Native `Media(start: Duration)` demux-time seek converges with 0ms error delta. |
| 8 | Playback speed adjustment (0.5x–2.0x) works | **PASS** | `MediaKitPlayerAdapter.setRate()` verified across 0.5x, 1.0x, 1.25x, 1.5x, 2.0x without pitch distortion. |
| 9 | External SRT subtitle track is discovered | **PASS** | Server endpoint delivers sidecar `.srt`, parsed into `PlayerTrackInfo`. |
| 10 | Subtitle track selection renders correctly | **PARTIALLY TESTED** | Track selection attaches to `libmpv`; cue display verified via probe at 152s (`"Happy anniversary to you."`), but not visible at 0:00 in standard battery because dialogue in the asset does not begin until 152.6s. |
| 11 | HEVC 10-bit decodes correctly | **PARTIALLY TESTED** | `tracks.video.first.codec == 'hevc'` verified and decodes cleanly without error; hardware acceleration and 10-bit pipeline not independently measured. |
| 12 | E-AC-3 5.1 multichannel audio plays | **PASS** | `tracks.audio.first.codec == 'eac3'`, `audioParams.channelCount == 6`, and `channels == '5.1(side)'` verified by decoder output params. |
| 13 | `X-Device-Id` header is sent and accepted by server | **PASS** | All HTTP requests inject `X-Device-Id: dev_<hex>` header; verified by integration test. |
| 14 | Seek-preview metadata endpoint delivers frames | **PASS** | `/api/seek-preview-meta/<file>` delivers valid JSON frame count and interval. |
| 15 | Rapid seek-preview scrub is independent of video player state | **PASS** | Rapid burst debouncing (A -> B -> C -> D), out-of-order response rejection, and decoupled operation from video player state verified via automated test suite and UI harness. |
| 16 | No architectural blocker prevents production player implementation | **PASS** | `PlayerControllerInterface` abstraction cleanly encapsulates `media_kit`/libmpv. |

---

### Acceptance Criteria Counts

- **PASS:** 14 criteria (1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15, 16)
- **PARTIALLY TESTED (viable with unverified edge details):** 2 criteria (10, 11)
- **NOT TESTED:** 0 criteria
- **FAIL:** 0 criteria
- **Total:** 16 criteria

---

### Architectural Verdict

**VERDICT: GO**

With Criterion 3 (HLS chunk-boundary playback transition across 60s) and Criterion 15 (seek-preview debounce, race-condition and stale-frame suppression) empirically verified and passing, and with no newly discovered blockers, the architectural verdict is **GO**.

The `media_kit`/`libmpv` player stack on Windows desktop is fully viable for production player development (Phase 3). Phase 3 will commence only upon explicit user approval.

---

## Running the app

```powershell
cd C:\MediaServer\flutter_client
# Release (production-like performance)
& "D:\src\flutter\bin\flutter.bat" run -d windows --release
# Debug (hot-reload available for development)
& "D:\src\flutter\bin\flutter.bat" run -d windows
```

libmpv-2.dll is bundled automatically by `media_kit_libs_windows_video` on build.
Expected path: `build\windows\x64\runner\Release\libmpv-2.dll`

---

---

## Phase 3 Strategic Pivot: Android-First, Desktop-Second

Before commencing Phase 3, the product strategy was refined:
1. **Primary Target Platform:** **Android** (touch interactions, physical mobile viewports, safe area insets, notch handling, gesture navigation, back handling).
2. **Secondary Target Platform:** **Windows/Desktop** (mouse hover, physical keyboard shortcuts, window resizing).
3. **Strict Backend Constraint:** Flask backend contracts must remain frozen (`/api/progress`, `/api/seek-preview-meta/<file>`, `/seek-preview/<file>/thumb_XXXXX.jpg`).

---

## Phase 3A — Production Player Architecture & Core UI (DONE)

**Goal:** Establish clean, decoupled production player feature architecture in `flutter_client/lib/features/player/`.

### Architecture & Key Components:
- **Domain Layer:**
  - `PlayerControllerInterface`: Pure abstract contract governing playback, rates, seeks, and track metadata.
  - `PlayerState`: Immutable state model exposing `playbackState`, `position`, `duration`, `buffered`, `rate`, `tracks`.
  - `SeekPreviewController`: Frame thumbnail lifecycle manager with sequence tracking and stale-frame suppression.
- **Infrastructure Layer:**
  - `ProductionPlayerController`: Wraps `MediaKitPlayerAdapter`, binds stream events, and coordinates playback session lifecycles.
- **Presentation Layer:**
  - `PlayerScreen`: Root player view managing wake locks, immersive fullscreen, and keyboard/touch routing.
  - `PlayerControlsOverlay`: Top bar (title, back, settings), center play/pause HUD, bottom controls rail.
  - `PlayerSurface`: Clamped video viewport rendering `Video` widget without layout overflow.
  - `PlayerLoadingIndicator`: Pulsing translucent loading spinner during demuxing/buffering.
  - `DoubleTapSeekDetector`: Left/right dual-zone double-tap gesture detector (±10s) with animated ripple feedback.

---

## Phase 3B — Android-First Timeline & Live Seek Preview (DONE — Commit `2e95246`)

**Goal:** Provide smooth touch scrubbing and live visual seek preview thumbnails without video stream interruption.

### Key Achievements:
- **`VideoTimelineBar`:**
  - Interactive touch slider with buffered range fill, current position track, and thumb pill.
  - Dragging/scrubbing decoupled from player `currentTime` (zero HTTP range flood during scrub).
  - Seek is committed strictly on `onSeekEnd` (finger lift / mouse release).
- **Live Frame Thumbnails (`SeekPreviewController`):**
  - Fetches metadata via `GET /api/seek-preview-meta/<path:filename>` (frame interval, total count).
  - Resolves individual JPEG thumbnails via `GET /seek-preview/<path:filename>/thumb_XXXXX.jpg`.
  - Debounces rapid scrubbing (30ms burst window) with atomic sequence counter discarding out-of-order stale images.
  - Floating preview card with smooth positioning clamped within screen boundaries; graceful fallback to formatted timestamp badge when thumbnails are unavailable.
- **Automated Validation:**
  - `flutter test`: 47 tests passed (including `runtime_player_3b_test.dart`, `seek_preview_race_debounce_test.dart`, `double_tap_seek_detector_test.dart`, `player_screen_test.dart`).

---

## Android Physical Device Setup & Native Engine Integration (DONE)

- **Device:** Vivo I2217 (Android 16, API 36) via wireless ADB (`192.168.1.6:40307`).
- **Toolchain:** Android SDK 36, NDK 28.2.13676358, JDK 17.
- **Issue Resolved:** `Cannot find libmpv.so. Please ensure it's presence in the APK.`
  - Added `media_kit_libs_android_video: ^1.3.8` to `flutter_client/pubspec.yaml`.
  - Verified `libmpv.so` is bundled into APK arm64-v8a native libraries.
  - `MediaKit.ensureInitialized()` initializes cleanly at runtime on Android 16.

---

## Next Up — Phase 3C (Audio & Subtitle Selectors)

- Modal bottom sheet for audio stream selection and subtitle tracks.
- Sidecar subtitle styling and elevation above controls.
- Playback speed selector dialog (0.5x to 2.0x).
- Android back gesture navigation handling.

