# Flutter Video Player Parity Inventory

> **Document Status:** Active Reference  
> **Source Baseline:** Commit `bbf6c42` (Tag: `phase-2-complete`)  
> **Target Branch:** `feat/flutter-production-player`  
> **Reference Implementations:** `templates/player.html`, `static/css/seekbar-youtube.css`, `static/js/seekbar-youtube.js`, `app/routes/media.py`, `app/routes/api.py`, `app/routes/subtitles.py`

This document defines the comprehensive behavioral inventory comparing the validated Flask web player against the proposed Flutter production player implementation.

---

## 1. Feature Parity Matrix

| Feature / Behavior | Existing Web Implementation (`templates/player.html` / `seekbar-youtube.js`) | Proposed Flutter Equivalent (`lib/features/player/`) | Parity Status | Planned Phase |
| :--- | :--- | :--- | :---: | :---: |
| **Play / Pause** | `HTML5VideoElement.play()` / `.pause()`, `#play` & `#center` buttons, Space/K shortcuts | `PlayerControllerInterface.play()` / `pause()`, reactive state stream | Parity Planned | Phase 3A |
| **Direct MP4 Stream** | Native `<video src="/media/...">` with RFC 7233 byte-range | `MediaKitPlayerAdapter.open(directUrl, headers)` | Parity Planned | Phase 3A |
| **HLS Stream** | `hls.js` with dynamic event playlist (`/hls/.../playlist.m3u8`) | Native `libmpv` HLS demuxer via `MediaKitPlayerAdapter` | Parity Planned | Phase 3A |
| **Basic Seeking** | `<input id="seek" type="range">`, commit on pointerup | Custom slider / scrubber, commit on drag end via `controller.seek()` | Parity Planned | Phase 3A |
| **Volume & Mute** | `<input id="volume">`, `#mute` button, volume icon transitions | Discrete volume slider & mute toggle via `controller.setVolume()` | Parity Planned | Phase 3A |
| **Fullscreen** | Fullscreen API (`shell.requestFullscreen()`), 'f' key | Window manager / Flutter desktop fullscreen mode (`windowManager`) | Parity Planned | Phase 3A |
| **Loading / Error Overlay**| `#playerPreloader`, `#cacheStatus`, error handlers | Dedicated Flutter `PlayerLoadingIndicator` & `PlayerErrorCard` | Parity Planned | Phase 3A |
| **Responsive Player Layout**| CSS Grid `#shell` with absolute inset video canvas | `LayoutBuilder` / `AspectRatio` container with clamped controls overlay | Parity Planned | Phase 3A |
| **Timeline Scrubber** | YouTube-style multi-layer rail (rail, buffered, played, thumb) | Multi-layer CustomPainter / Stack seekbar with smooth interaction | Parity Planned | Phase 3B |
| **Current / Duration Time**| `#timeElapsed`, `#timeTotal` (clickable remaining time toggle) | Reactive `Text` widgets updating from `positionStream` / `durationStream` | Parity Planned | Phase 3B |
| **Buffered Range Fill** | `video.buffered` TimeRanges rendered as `<i>` segments | `player.stream.buffer` (or libmpv demuxer cache) if exposed by engine | Parity Planned | Phase 3B |
| **Seek Preview Thumbnail** | Edge-clamped hover/scrub preview card (`/seek-preview/...`) | `SeekPreviewCard` using Phase 2 `SeekPreviewController` | Parity Planned | Phase 3B |
| **Seek Preview Timestamp** | Dynamic timestamp above preview thumbnail | Formatted timestamp chip on `SeekPreviewCard` | Parity Planned | Phase 3B |
| **Seek Preview Debounce** | 35ms image debounce, image cache, stale URL suppression | Phase 2 `SeekPreviewController` (80ms debounce, sequence tagging) | Parity Planned | Phase 3B |
| **Discrete Relative Seeks** | `#skipBackBtn` (-10s), `#skipForwardBtn` (+10s), arrow keys (±5s) | Discrete seek buttons (-10s / +10s or ±5s / ±30s) + keyboard shortcuts | Parity Planned | Phase 3C |
| **Replay from Start** | `#restartBtn` (seeks to 0.08s to avoid demux gaps) | `ReplayButton` invoking `controller.seek(Duration.zero)` | Parity Planned | Phase 3C |
| **Playback Rate Menu** | `<select id="speed">` (0.75x, 1x, 1.25x, 1.5x, 2x) | Obsidian glass popover/dropdown menu (0.5x, 1.0x, 1.25x, 1.5x, 2.0x) | Parity Planned | Phase 3C |
| **Control Auto-Hide** | 2.5s timer during active playback; cancels on hover/pause | `PlayerControlsVisibilityManager` (2.5s timer, paused immunity) | Parity Planned | Phase 3C |
| **Visual HUD Feedback** | `#playerHud` toast ("▶ 1.25x Speed", "🔊 80%", etc.) | Animated `PlayerToastOverlay` for rate, volume, seek, and aspect actions | Parity Planned | Phase 3C |
| **Keyboard Shortcuts** | Space, K, J, L, Arrows, 0-9 (10-90%), M, F, N, A, < / > | Flutter `Focus` / `KeyboardListener` with matching keybindings | Parity Planned | Phase 3C |
| **Subtitle Discovery** | `/api/subtitles/<file>` + embedded text tracks | Native `player.state.tracks.subtitle` + `/api/subtitles` sidecars | Parity Planned | Phase 3D |
| **Subtitle Selection** | `#subTrackSelect`, `#ccBtn` toggle | Subtitle modal sheet / popover picker via `controller.setSubtitleTrack` | Parity Planned | Phase 3D |
| **Subtitle Styling** | Custom CSS `video::cue` (color, opacity, size, align, pos) | `SubtitleViewConfiguration` in `media_kit_video` / libmpv styling options | Parity Planned | Phase 3D |
| **Server Subtitle Upload** | `#playerSubFileInput` multipart POST to `/api/upload-subtitle` | File picker desktop dialog uploading to `/api/upload-subtitle` | Parity Planned | Phase 3D |
| **Audio Track Selection** | (Browser native limitation; only 1 track exposed via HTML5) | Native multi-track selection via `player.state.tracks.audio` | **Enhancement** | Phase 3D |
| **Checkpoint Resume** | GET `/api/progress?filename=...`, native `Media.start` | Query `/api/progress`, open with demux `startPosition` | Parity Planned | Phase 3E |
| **Progress Persistence** | POST `/api/progress` every 10s, on pause, and on pagehide | Periodic timer (10s) + pause + dispose posting to `/api/progress` | Parity Planned | Phase 3E |
| **Settings Persistence** | `localStorage` (`media_sub_settings`, `media_aspect_mode`) | `shared_preferences` storing volume, rate, aspect, subtitle prefs | Parity Planned | Phase 3E |
| **Aspect Ratio Modes** | Fit, Crop, Stretch, 16:9, 4:3, Original via CSS object-fit | `BoxFit` / custom container aspect clamping on `Video()` surface | Parity Planned | Phase 3E |
| **Stats for Nerds HUD** | `#nerdStatsHud` (resolution, dropped frames, buffer, codec) | Floating `NerdStatsOverlay` reading libmpv video/audio params & telemetry | Parity Planned | Phase 3F |
| **Transcoding Progress** | `#playerTranscodeCard` polling `/api/transcode-status` | Dynamic transcode banner polling `/api/transcode-status` for HLS jobs | Parity Planned | Phase 3F |
| **Picture-in-Picture** | `video.requestPictureInPicture()` | Desktop PiP / compact overlay mode where OS windowing permits | Deferred (Desktop) | Backlog |
| **Touch / Mobile Gestures**| Double-tap seek, vertical swipe volume/brightness | Touch gestures for mobile/tablet targets | Deferred (Desktop) | Backlog |

---

## 2. Detailed Behavioral Specifications

### 2.1 Playback & Engine Invariants
1. **Engine Decoupling:** Presentation widgets must never interact directly with `Player` or `VideoController`. All interactions pass through `PlayerControllerInterface`.
2. **Monotonic PTS & Chunk Boundaries:** HLS streams utilize monotonic timestamp offsets. As demonstrated in Phase 2, `media_kit`/`libmpv` plays through dynamic multi-GPU chunk transitions seamlessly.
3. **Demux-Time Resume:** Resuming playback from a saved checkpoint MUST pass `start: startPosition` into `Media(...)` rather than issuing an immediate post-open `seek()`, eliminating seek divergence and demux stalls.
4. **Gap Avoidance:** When restarting playback from the beginning, seek to `0.08s` or the start of the first buffered packet if initial demuxer packets are offset.

### 2.2 Timeline & Seek Preview Invariants
1. **Debounce & Race-Safe Supersession:** As verified in Phase 2 Criterion 15, seek preview frame fetching must remain completely decoupled from video playback state.
2. **Supersession Rule:** If preview requests occur in sequence \(A \to B \to C \to D\), request \(D\) takes precedence, and any delayed arrival of \(A\), \(B\), or \(C\) is discarded.
3. **Decoupled Scrubbing:** Moving or dragging the seekbar slider updates the visual time display and preview card without synchronously commanding video seeks. The video seek is committed only on pointer release.

### 2.3 Progress & State Persistence
1. **Endpoint Contract:**
   - Query: `GET /api/progress?filename=<encoded>` returns `{ "position": double, "duration": double }`.
   - Update: `POST /api/progress` with JSON `{ "filename": string, "position": double, "duration": double }`.
   - Headers: Must include `X-Device-Id: dev_<hex>`.
2. **Save Triggers:**
   - Every 10 seconds during active playback.
   - Immediately upon pause.
   - Immediately upon player disposal / exit.
   - When playback reaches the end of the video, post `position: 0` to clear completed resume checkpoints.

### 2.4 Subtitles & Audio Tracks
1. **Discovery:** Query `/api/subtitles/<path>` for server-side sidecar `.srt`/`.vtt` files and combine with libmpv native embedded subtitle tracks (`player.state.tracks.subtitle`).
2. **External Track Injection:** When selecting a sidecar subtitle, inject it into libmpv using `SubtitleTrack.uri(url, title: label)`.
3. **Cue Rendering Verification:** Subtitle cue visibility must be verified against actual dialogue timestamps (e.g. 152s on *Lust Stories 3*).
4. **Audio Track Selection:** libmpv automatically detects multi-track audio (e.g. Stereo, 5.1 EAC3). Flutter UI exposes human-readable audio track labels (`language`, `title`, `channels`).

### 2.5 Keyboard & Desktop Shortcuts
- <kbd>Space</kbd> / <kbd>K</kbd>: Play / Pause toggle
- <kbd>Home</kbd> / <kbd>0</kbd>: Replay from beginning
- <kbd>←</kbd> / <kbd>→</kbd>: Seek ±5 seconds
- <kbd>J</kbd> / <kbd>L</kbd>: Seek ±10 seconds
- <kbd>1</kbd>–<kbd>9</kbd>: Seek to 10%–90% of timeline
- <kbd>↑</kbd> / <kbd>↓</kbd>: Volume ±5%
- <kbd>M</kbd>: Mute / Unmute toggle
- <kbd>F</kbd>: Fullscreen toggle
- <kbd>N</kbd>: Stats for Nerds HUD toggle
- <kbd>C</kbd>: Subtitles toggle
- <kbd><</kbd> / <kbd>></kbd>: Playback speed decrement / increment
- <kbd>Escape</kbd>: Close overlays / Exit fullscreen
