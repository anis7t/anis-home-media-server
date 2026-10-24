# Phase 9: Client Media Capability Probing, Offline Pre-Transcoding Architecture & 100% Playback Gating — Final Walkthrough

**Phase:** Phase 9  
**Branch:** `feat/phase-9-pre-transcode-capabilities`  
**Status:** COMPLETE  
**Date:** 2026-10-18  

---

## 1. Executive Summary & Problem Resolution

### The Problem
During playback of *Ghost in the Cell* (a 4K 2160p Matroska `.mkv` container encoded in 10-bit HEVC with Dolby Digital Plus / `eac3` 5.1 audio), web browsers experienced catastrophic playback deadlocks:
1. **Direct Stream Failure**: Web browsers (Chrome, Edge, Firefox) do not natively demux Matroska (`.mkv`) containers or decode Dolby Digital Plus (`eac3`) streams via the standard HTML5 `<video src="/media/...">` pipeline. Attempting Direct Play caused the `<video>` element to freeze indefinitely at `0:00` with continuous aborted byte-range requests.
2. **On-Demand Mid-Stream Stall Trap**: Selecting a transcoding resolution mid-stream (e.g. 30 minutes into playback) triggered on-demand transcoding from frame 0. Because on-demand transcoding was sequential, the viewer was forced to wait for hundreds of megabytes to transcode before the playhead could advance. Furthermore, starting playback on an in-progress transcode risked timeline drift and desynchronization.
3. **Layman Direct Play Confusion**: Ordinary users had no visual indicator that their browser lacked hardware/codec support for `.mkv` or `eac3`, leaving them confused as to why Direct Play hung at `0:00`.

### The Structural Solution
Phase 9 eliminates on-demand mid-stream transcoding entirely in favor of an **offline pre-transcoding architecture**, accompanied by **browser media capability probing** and a **strict 100% playback gate**:
- **Client Capability Probing**: Automatically queries `navigator.mediaCapabilities.decodingInfo()` and `HTMLMediaElement.canPlayType()` for container and codec support (MKV, HEVC, EAC-3, AC-3, AAC).
- **Layman Protection (Option 2A)**: If a browser cannot decode the source container or codec, Direct Play is disabled in the quality modal with a `🔒` lock icon, an `Unsupported on this browser` badge, and a human-readable diagnostic explanation.
- **Strict 100% Gate**: Playback is hard-blocked until an adaptive fMP4 HLS transcode is 100% finished with `#EXT-X-ENDLIST`. The `<video>` element is never mounted for incomplete streams, completely preventing `0:00` deadlocks.
- **Source Resolution Baseline (Option 1C)**: Baseline pre-transcoding preserves native source resolution (up to 4K / 2160p) using the dual AMD GPU hardware pipeline (Radeon RX 560X + Vega 8).
- **Operator Tooling**: Direct pre-transcoding triggers from Movie Details (`⚡ Pre-Transcode Now`) and the Management Dashboard (`/manage` filter and row action).

---

## 2. Architecture & Deliverables by Slice

```
[ Browser Client ]
       │
       ▼
 1. W3C Media Capabilities Probe (decodingInfo + canPlayType)
       │
       ├── Supported (MP4/H.264/AAC) ──────► Direct Play (Zero-Copy RFC 7233 Range)
       │
       └── Unsupported (MKV / HEVC / EAC3)
             │
             ├── Quality Modal: Option 2A Disabled Button [🔒 Unsupported on this browser]
             │
             └── Check HLS Cache (manifest contains #EXT-X-ENDLIST?)
                   │
                   ├── 100% Complete ───────► Mount <video> with fMP4 HLS Stream
                   │
                   └── Incomplete / Idle ───► <TranscodeGate> Hard Block
                                              [ Dual AMD GPU Progress HUD / Pre-Transcode Trigger ]
```

### Slice 9A: Client Media Capability Probing & Capability-Aware Quality Modal
- **`web/src/lib/capabilities/mediaCapabilities.ts`**:
  - Implements `probeClientMediaCapabilities(info: MediaProbeInfo)` using the W3C Media Capabilities API (`navigator.mediaCapabilities.decodingInfo()`) paired with `canPlayType` container checks.
  - Evaluates container constraints (`.mkv`, `.mp4`, `.webm`), video codecs (`hevc`, `h264`, `vp9`, `av1`), and audio codecs (`eac3`, `ac3`, `aac`, `opus`, `flac`).
  - In-memory capability caching avoids redundant W3C IPC queries during UI state changes.
- **`web/src/features/playback/QualitySelectorModal.tsx`**:
  - Implements **Option 2A**: Direct Play button is disabled when `canDirectPlay === false`.
  - Displays a warning badge: `Unsupported on this browser`, a lock icon `🔒`, and an explicit diagnostic reason (e.g. *"MKV container and Dolby Digital Plus audio are not natively demuxable in this browser"*).
- **`rust/src/routes/media_info.rs`**:
  - `build_quality_ladder()` accepts a `direct_play: bool` flag; strictly enforces `is_ready: direct_play` for `source`.
  - Serializes `"audio_codec"` alongside `"video_codec"` in `MediaInfoResponse` so clients know exact audio decoding requirements.
- **`docs/openapi.yaml` & `web/src/lib/api/schema.ts`**:
  - Added `audio_codec?: string` to OpenAPI and TypeScript schema contracts.

### Slice 9B: Strict 100% Pre-Transcode Playback Gate Hardening
- **`rust/src/routes/media_info.rs`**:
  - Hardened `is_hls_ready()`: removed legacy `min_coverage_ratio` partial transcode bypass.
  - Manifest validation strictly requires `#EXT-X-ENDLIST` in `playlist.m3u8` to mark any quality tier as ready.
- **`rust/src/services/transcode_worker.rs`**:
  - Implemented **Option 1C**: In `TranscodeWorker::process_job`, when `job.mode == "hls"`, targets the source file's native resolution up to 4K / 2160p (clamping to source width/height so no artificial upscaling occurs).
- **`web/src/features/playback/TranscodeGate.tsx`**:
  - Added support for `onQueuePreTranscode` and `diagnosticReason`.
  - Cleanly handles 3 status states:
    - `'building'`: Real-time dual AMD GPU progress HUD with ETA, frame rates, and segment counters.
    - `'partial'`: Incomplete transcode warning with button to restart/resume full transcode.
    - `'idle'`: `Pre-Transcode Required` badge with "Queue Baseline Pre-Transcode" action.
- **`web/src/features/playback/PlayerPage.tsx`**:
  - Hardened `<video>` element isolation: whenever `!isPlaybackReady`, the video element is strictly hidden (`display: none;` / `hidden`) and never loads a stream source URL, eliminating `0:00` lockups.

### Slice 9C: Automated Pre-Transcode Sweeper
- **`rust/src/services/transcode_sweeper.rs`**:
  - Updated `sweep_once()` to inspect media library files against completed tiered directories (`2160p/`, `1080p/`, etc.) using `HlsService::is_hls_complete()`.
  - Enqueues untranscoded titles into PostgreSQL `transcode_jobs` at `PRIORITY_BACKGROUND` (5), allowing user-requested operator jobs (`PRIORITY_USER_INTERACTIVE` = 100) to preempt them cleanly.

### Slice 9D: Operator Management UI on `/manage` & Movie Details
- **`web/src/features/media-details/MovieDetailsPage.tsx`**:
  - Replaced legacy text (*"First play builds a stream for this title — it will begin automatically"*) with a dedicated **Pre-Transcode Required** card.
  - Includes a prominent **⚡ Pre-Transcode Now** action button with active spinner and feedback states.
  - Displays stream readiness indicators:
    - 🟢 `Stream Ready (fMP4 Adaptive HLS Cached)`
    - 🔵 `Direct Stream Compatible (Zero-Copy Native Playback)`
    - 🟠 `Pre-Transcode Required (MKV / Non-Native)`
- **`web/src/features/manage/components/InventoryToolbar.tsx`**:
  - Added `'needs_transcode'` to `FilterCategory`.
  - Added `⚡ Needs Pre-Transcode` filter chip to immediately isolate all files awaiting pre-transcoding.
- **`web/src/features/manage/components/InventoryList.tsx`**:
  - Added `onPreTranscodeMovie` prop and row action button: **⚡ Pre-Transcode**.
  - Replaced legacy `⚙ On-Demand Transcode` status badge with `⚡ Pre-Transcode Required`.
- **`web/src/features/manage/ManagePage.tsx`**:
  - Wired `handlePreTranscodeMovie()` with toast notification feedback and live audit reload.

---

## 3. Browser Codec & Chrome Flags Technical Analysis

As requested in the user query regarding hardware acceleration and Chrome flags:

### Why Browsers Fail to Demux MKV and EAC3
1. **Container Demuxing**: Chromium's HTML5 media engine does not include a generic Matroska container demuxer for `<video src="...">`. Chromium only parses Matroska structures in the context of WebM (`video/webm`), which is restricted to VP8, VP9, AV1, Vorbis, and Opus. Standard MKV files wrapping H.264 or HEVC with Dolby audio return `""` (empty string / unsupported) from `canPlayType('video/x-matroska')`.
2. **Dolby Digital Plus (E-AC-3 / `ec-3`) Audio**: Neither Chromium nor Firefox ship open-source Dolby Digital Plus decoders due to patent licensing fees. On Windows, decoding EAC-3 requires passthrough or Microsoft Media Foundation (MF) platform audio decoders.

### Chrome Flags Analysis
- **`chrome://flags/#enable-platform-hevc`**:
  Enables hardware-accelerated HEVC decoding if the host operating system provides an underlying MFT (Media Foundation Transform) decoder (e.g. Windows "HEVC Video Extensions" from the Microsoft Store).
- **`chrome://flags/#enable-media-foundation-service`**:
  Enables out-of-process Media Foundation audio and video decoding on Windows 10/11, allowing Chrome to tap into system Dolby AC-3/EAC-3 decoders where installed.
- **`chrome://flags/#hardware-accelerated-video-decode`**:
  Enables GPU-accelerated video decoding (AMD AMF / DX11VA).

### Why Phase 9 is the Superior Architectural Fix
Expecting users or family members to navigate `chrome://flags`, install specific OS codec extensions, or configure hardware acceleration is brittle and impractical. Phase 9 solves this structurally:
- If a browser *does* have hardware HEVC and audio support enabled, `probeClientMediaCapabilities` dynamically detects it via `navigator.mediaCapabilities.decodingInfo()` and permits Direct Play.
- If the browser does *not* support it, the UI gracefully locks Direct Play with an honest diagnostic reason and plays the pre-transcoded fragmented MP4 (`fMP4`) HLS stream seamlessly with zero configuration required.

---

## 4. Verification & Test Outcomes

### 1. Web Frontend Vitest Suite
```text
Test Files  27 passed (27)
     Tests  194 passed (194)
  Duration  30.81s
```
- Includes 17 tests in `MovieDetailsPage.test.tsx` (verifying pre-transcode card, stream readiness indicators, and queue actions).
- Includes 7 tests in `ManagePage.test.tsx` (verifying `⚡ Needs Pre-Transcode` filter chip and row action button).
- Includes 7 tests in `QualitySelectorModal.test.tsx` (verifying Option 2A disabled button and lock badge).
- Includes 23 tests in `PlayerPage.test.tsx` (verifying strict 100% gate and `<video>` isolation).
- Typecheck (`tsc -b`): Passed with 0 errors.
- Linter (`npm run lint`): Passed with 0 errors.
- Production Build (`npm run build`): Generated clean `web/dist/` bundle in 1.08s.

### 2. Rust Backend Test Suite
Executed via `scripts\cargo.bat test --manifest-path rust/Cargo.toml -- --test-threads=1`:
```text
test result: ok. 14 passed (hls_serving_test)
test result: ok. 15 passed (job_queue_test)
test result: ok.  9 passed (media_info_test)
test result: ok.  8 passed (poster_asset_test)
test result: ok.  9 passed (preview_test)
test result: ok.  1 passed (progress_contracts_test)
test result: ok.  5 passed (scan_test)
test result: ok.  5 passed (spa_serving_test)
test result: ok.  3 passed (storage_test)
test result: ok. 11 passed (streaming_range_test)
test result: ok. 16 passed (subtitles_test)
test result: ok. 10 passed (tmdb_artwork_test)
test result: ok.  5 passed (transcode_start_test)
```
- Total: **111 Rust tests executed, 111 passed, 0 failed**.

### 3. Client Contract Probes
- **Android TV / Fire TV Probe (`scripts/probe_android_api.py`)**:
  - All **22 of 22 endpoints responded with HTTP 200/400/404 per contract**.
  - Confirmed Android client maintains zero-copy Direct Play (`direct_play: True`, `needs_transcode: False`) for Matroska files, protecting Fire TV Stick 4K hardware decoding.
- **Phase 8 fMP4 Contract Probe (`scripts/probe_phase_8_contracts.py`)**:
  - Confirmed web client receives `direct_play: False`, `needs_transcode: True`, and quality ladder tiers.

---

## 5. Instructions for Persistent Service Update

Because the Rust service `MediaServerRust` is currently running and holding a lock on the binary `E:\MediaServer\rust\target\release\media-server-api.exe`, run the restarter script with Administrator privileges to compile the latest code and restart the service:

### Command to Execute:
Open an elevated PowerShell prompt or run:
```cmd
e:\MediaServer\scripts\restart_rust_service.bat
```
*(Alternatively, in an elevated PowerShell session:)*
```powershell
powershell -ExecutionPolicy Bypass -File E:\MediaServer\scripts\restart_rust_service.ps1
```

### What this script will do:
1. Stop the `MediaServerRust` Windows Service.
2. Wait for NSSM to completely release the file lock on `media-server-api.exe`.
3. Automatically execute `cargo build --release` with the new Phase 9 code.
4. Restart `MediaServerRust` and verify healthy API responses on port 8000.
