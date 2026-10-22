# Implementation Plan — Phase 9: Client Media Capability Probing, Offline Pre-Transcoding Architecture & 100% Playback Gating

**Document Date:** 2026-10-18  
**Phase:** Phase 9 (Media Playback Hardening & Offline Pre-Transcoding)  
**Branch:** `feat/phase-9-pre-transcode-capabilities`  
**Governing Rules:** `AGENTS.md` §0.1, §0.2, §5; `GEMINI.md` §0, §1, §3, §4, §15  
**Target Backend:** Rust / Axum (`:8000`) & PostgreSQL 18.4 (`:5432`)  
**Frontends:** React Web Player (`web/`) & Flutter TV/Mobile (`flutter_client/`)  

---

## 1. Executive Summary & Problem Statement

### The Problem:
1. **Layman Browser Incompatibility & Silent Direct Play Failure**:
   - Modern movie libraries contain rich high-efficiency media: Matroska containers (`.mkv`), 10-bit HEVC (H.265 Main 10), and multichannel Dolby Digital Plus (`eac3`) audio (e.g. *Ghost in the Cell*).
   - Desktop web browsers (Google Chrome, Mozilla Firefox, Safari) **cannot natively demux `.mkv` files** in HTML5 `<video src="/media/...">` and **lack software decoders for Dolby Digital Plus (`eac3`) audio** due to licensing costs.
   - When a layman user opens the web player and clicks "Direct Play", the browser's video engine silently deadlocks at `0:00` with an infinite loading spinner. Laymen have no way of knowing their browser cannot demux the container or decode the audio.
   - Conversely, Android TV and Fire TV devices (ExoPlayer) *do* support native MKV demuxing and hardware HEVC decoding. A static, blunt rule across all devices either breaks the web or unnecessarily forces transcoding on Android TV.

2. **The "On-Demand Transcoding" User Experience Flaw**:
   - Currently, selecting a non-cached resolution during playback triggers an on-demand transcode.
   - The transcode worker always encodes **sequentially from Chunk 0 (0:00)**.
   - If a user is already 30 minutes into a movie, selecting an on-demand quality forces them to wait for chunks 0 through 29 to encode on the GPUs before their current scene even begins.
   - On top of this, the web player enforces a **100% Transcode Gate** (`isPlaybackReady = percent >= 100`), which locks the screen behind an overlay card until the *entire movie* finishes (20–30 minutes). Mid-stream on-demand transcoding is therefore an anti-pattern for full-length feature films.

### The Objective:
Transition the media server from an **on-demand mid-stream transcode model** to an **offline pre-transcoding architecture**, paired with **client-side media capability detection** and a **strict 100% completion lock**:
1. **Dynamic Client Capability Probing (`navigator.mediaCapabilities`)**: The browser queries its own hardware and codec decoders before rendering options. If a container or codec is unsupported by that specific browser, "Direct Play" is automatically hidden or disabled with a clear layman explanation.
2. **Offline Pre-Transcoding**: Newly discovered media (and admin-selected titles) are pre-transcoded into baseline Fragmented MP4 (`fMP4`) HLS ahead of time by background workers during idle hours.
3. **Strict 100% Completion Gate**: Playback is strictly forbidden until the chosen transcode tier is 100% finished on disk, ensuring zero stalls, zero buffer crashes, and instant start.
4. **Ready-Only Quality Selectors**: The in-player quality picker only allows switching between qualities that are **already 100% cached on disk**.

---

## 2. Architecture & Design Principles

```
┌────────────────────────────────────────────────────────────────────────┐
│                        CLIENT CAPABILITY ENGINE                        │
│                     (navigator.mediaCapabilities)                      │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
           ┌────────────────────────┴────────────────────────┐
           ▼                                                 ▼
   [Android TV / Fire TV]                           [Desktop Web Browser]
   - Container: MKV supported                       - Container: MKV unsupported
   - Video: HEVC HW supported                       - Audio: EAC3 unsupported (Chrome)
   - Audio: EAC3 HW passthrough                     - Video: HEVC requires OS extension
           │                                                 │
           ▼                                                 ▼
┌───────────────────────┐                         ┌───────────────────────┐
│ Direct Play UNLOCKED  │                         │ Direct Play DISABLED  │
│ (Zero Server CPU/GPU) │                         │ (Clean Layman Badge)  │
└───────────────────────┘                         └───────────┬───────────┘
                                                              │
                                                              ▼
                                                  ┌───────────────────────┐
                                                  │ Adaptive Stream Only  │
                                                  │ (1080p/720p fMP4/AAC) │
                                                  └───────────┬───────────┘
                                                              │
                                                              ▼
                                                  ┌───────────────────────┐
                                                  │  100% Completion Gate │
                                                  │  - 100% Ready: PLAY   │
                                                  │  - <100%: TranscodeGate│
                                                  └───────────────────────┘
```

### Pillar I: Native Client Media Capability Probing
Instead of server-side user-agent parsing or blunt extension checks, the React frontend directly invokes the W3C standard `navigator.mediaCapabilities.decodingInfo()`:
- **Video Probe:** `{ contentType: 'video/x-matroska; codecs="hvc1.1.6.L93.B0"' }` (or `avc1`, `vp09`).
- **Audio Probe:** `{ contentType: 'audio/x-matroska; codecs="ec-3"' }` (or `mp4a.40.2`, `ac-3`).
- **Fallback Probe:** `HTMLMediaElement.canPlayType(...)` for legacy browsers.
- **Verdict Mapping:**
  - `supported: true` $\rightarrow$ Direct Play enabled.
  - `supported: false` $\rightarrow$ Direct Play disabled; tooltip shows specific reason: *"Your browser cannot decode MKV/Dolby Digital Plus directly. Adaptive Stream will be used."*

### Pillar II: Per-Tier Readiness Gating
The Rust API (`/api/media-info/{path}`) will inspect each tier in the `quality_ladder` and return an explicit `is_ready` boolean:
```json
{
  "direct_play": false,
  "needs_transcode": true,
  "quality_ladder": [
    { "quality": "source", "label": "Direct Play (Source)", "is_ready": false, "reason": "Requires MKV demuxer" },
    { "quality": "1080p", "label": "1080p (FHD)", "is_ready": true, "status": "ready" },
    { "quality": "720p", "label": "720p (HD)", "is_ready": true, "status": "ready" },
    { "quality": "2160p", "label": "4K (2160p)", "is_ready": false, "status": "not_transcoded" }
  ]
}
```
- In the player, qualities where `is_ready: false` are rendered as disabled with a tag `(Not Pre-Transcoded)`.
- Users can switch instantaneously between ready tiers with zero buffering and zero transcode delays.

### Pillar III: Background Pre-Transcoding Queue
- Transition the autonomous background worker (`transcode_worker.rs`) and scheduler (`transcode_sweeper.rs`) from an on-demand trigger to an **offline pre-transcode engine**:
  - Automatically identifies raw library videos that require transcoding and lack a completed baseline tier (e.g. 1080p).
  - Enqueues jobs in PostgreSQL `transcode_jobs` with standard priority (priority 0).
  - Encodes during system idle periods on the dual AMD GPUs (Radeon RX 560X + Vega 8).
  - Upon 100% completion, writes the final RFC 8216 master playlist with `#EXT-X-ENDLIST` and marks the database record `completed`.

### Pillar IV: Operator Management UI (`/manage` & `/movie/*`)
- Add a **⚡ Pre-Transcode** button on each movie's detail page and in the `/manage` inventory table.
- Display a dedicated **Transcode Readiness Badge** in library views:
  - 🟢 **Stream Ready** (100% pre-transcoded fMP4 available)
  - 🔵 **Direct Play** (Native MP4/WebM supported on all devices)
  - 🟡 **Transcoding (X%)** (Currently processing in background)
  - ⚪ **Raw Source** (Requires pre-transcode for web browsers)
- Add a one-click batch trigger: **"Pre-Transcode All Pending Movies"** on `/manage`.

---

## 3. Slices & Execution Plan

### Slice 9A: Native Client Capability Probe & Layman UI Adaptation
- **Frontend Core (`web/src/lib/capabilities/mediaCapabilities.ts`)**:
  - Implement `probeMediaCapabilities(container, videoCodec, audioCodec)` using `navigator.mediaCapabilities.decodingInfo()` and `canPlayType`.
  - Cache capability results in memory/session to prevent redundant async evaluations.
- **Quality Selector Modernization (`QualitySelectorModal.tsx`)**:
  - If the capability probe reports `canDirectPlay === false`, disable or hide "Direct Play (Source)".
  - Display layman-friendly explanation badge: `❌ Unsupported on this browser (MKV / Dolby Audio)`.
  - Default the active selection to the highest **100% ready** adaptive stream.
- **Player Viewport Integration (`PlayerPage.tsx`)**:
  - Automatically guard direct play routes against unsupported containers on web.
  - If a user deep-links directly with `?mode=direct` on an unsupported file, smoothly re-route to the 100% ready adaptive stream and display a transient HUD notice: *"Switched to Adaptive Stream: Your browser cannot direct play MKV/E-AC-3."*

### Slice 9B: Rust API Per-Tier Readiness & Strict 100% Gate Hardening
- **Rust Backend (`rust/src/routes/media_info.rs` & `rust/src/services/hls_service.rs`)**:
  - Enhance `build_quality_ladder` to check for complete `playlist.m3u8` with `#EXT-X-ENDLIST` in each quality subdirectory (`/2160p`, `/1440p`, `/1080p`, `/720p`, `/480p`, `/360p`).
  - Set `is_ready: true` only if the manifest is 100% finalized.
- **Strict 100% Gate Hardening (`PlayerPage.tsx` & `TranscodeGate.tsx`)**:
  - Audit and lock all media loading paths: `<video>` element must never mount or load a stream unless `isPlaybackReady === true` (either client-verified Direct Play OR 100% verified HLS with `#EXT-X-ENDLIST`).
  - Ensure `<TranscodeGate>` cleanly reflects real-time background progress when a pre-transcode is active.

### Slice 9C: Background Pre-Transcoding Queue & Automated Ingestion
- **Rust Worker Enhancement (`rust/src/services/transcode_worker.rs` & `scan_service.rs`)**:
  - When the background scanner discovers an untranscoded movie (or upon server startup), automatically evaluate if it requires transcoding for web.
  - If so, insert a pre-transcode job for the baseline target resolution (default `1080p`) into `transcode_jobs` table.
  - Transcode worker claims jobs sequentially and encodes using the dual AMD GPUs.
- **Database Schema**:
  - Add `target_quality` column or metadata field to `transcode_jobs` table to cleanly track multi-quality jobs.

### Slice 9D: Library Management Tooling (`/manage` & Movie Details)
- **Movie Details (`web/src/features/library/MovieDetails.tsx`)**:
  - Display transcode status and available qualities with 🟢 Ready tags.
  - Add admin **⚡ Pre-Transcode** button allowing the user to trigger pre-transcoding for any resolution (1080p, 4K, 720p) directly from the movie page.
- **Inventory Management (`web/src/features/manage/components/InventoryList.tsx`)**:
  - Add stream readiness filter: *All*, *Stream Ready*, *Direct Play Only*, *Needs Pre-transcode*.
  - Add batch action: **"Pre-Transcode Library"** triggering baseline 1080p generation for all pending titles.

### Slice 9E: Comprehensive Multi-Browser Verification Battery
- **Verification Matrix**:
  1. **Google Chrome (Desktop)**:
     - Verify capability probe correctly detects `.mkv` + `eac3` (*Ghost in the Cell*) as unsupported.
     - Verify "Direct Play" is disabled with layman warning badge.
     - Verify player smoothly defaults to pre-transcoded 1080p fMP4.
  2. **Microsoft Edge (Desktop)**:
     - Verify capability probe runs and tests system Media Foundation capabilities.
  3. **Android TV / Fire TV Client**:
     - Verify ExoPlayer continues to direct play `.mkv` with zero server transcode.
  4. **Strict Gate Integrity**:
     - Verify that non-100% files are strictly held behind `<TranscodeGate>` and never freeze at `0:00`.

---

## 4. Scope

### What Changes:
- Client-side capability probing in `web/src/lib/capabilities/mediaCapabilities.ts`.
- Quality modal and player gating in `QualitySelectorModal.tsx` and `PlayerPage.tsx`.
- Rust API media info ladder in `rust/src/routes/media_info.rs` and `hls_service.rs`.
- Automated pre-transcoding ingestion in `rust/src/services/transcode_worker.rs` and `scan_service.rs`.
- Management UI triggers in `web/src/features/manage/` and movie details.

### What Deliberately Does NOT Change:
- Dual AMD GPU hardware encoding engine (`gpu_service.rs`, AMF VPP scaling) remains identical.
- Android / Fire TV client (`flutter_client/`) playback engine remains identical (keeps native MKV direct play).
- ISO BMFF Fragmented MP4 (`fMP4`) HLS packaging specification remains unchanged.
- PostgreSQL database connection pool and table structures remain backwards-compatible.

---

## 5. Exit Criteria

Phase 9 is complete when:
1. **Client Capability Probe**:
   - `probeMediaCapabilities()` accurately identifies browser container and codec limits across Chrome and Edge.
2. **Layman Direct Play Protection**:
   - For *Ghost in the Cell* (MKV / HEVC / EAC-3), Chrome Web Player automatically hides or disables Direct Play and presents a clear, human-readable reason.
3. **Strict 100% Gate**:
   - Zero playback attempts on incomplete streams. No spinning 0:00 locks or broken direct play attempts.
4. **Pre-Transcoding Operations**:
   - Admin can trigger **⚡ Pre-Transcode** from `/manage` and movie details.
   - Background worker processes queue autonomously on dual AMD GPUs.
   - Finished titles become 100% Stream Ready.
5. **Multi-Tier Automated Test Suites**:
   - Rust integration test suite passes 100% (`scripts/cargo.bat test`).
   - Web frontend Vitest suite passes 100% (`npm run test`).
   - Android client contract probe passes 22/22 endpoints.

---

## 6. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| **Browser Probe Async Latency** | Slight delay before modal opens if `decodingInfo` is slow. | Run capability probe once during initial movie metadata load (`/api/media-info`) and cache the result in component state. |
| **GPU Overload from Mass Pre-Transcoding** | Background worker starving interactive system response. | Worker runs with lowered Windows process priority (`BELOW_NORMAL_PRIORITY_CLASS`) and yields between chunks. |
| **Storage Exhaustion from Multiple Tiers** | Pre-transcoding multiple tiers could fill the SSD. | Default pre-transcode to a single baseline tier (e.g. 1080p). Higher tiers (e.g. 4K) only pre-transcode upon explicit user request. |

---

## 7. Open Decisions for User Confirmation

1. **Default Baseline Pre-Transcode Quality**:
   - **Option A (Recommended): 1080p (FHD)**. Encodes at high speed (~2.5x real time) with excellent visual quality and modest storage footprint (~2–4 GB per movie).
   - **Option B: 720p (HD)**. Super fast encoding and minimal storage (~1–2 GB), ideal for fast streaming.
   - **Option C: Match Source Resolution** (up to 4K). Maximum quality, but takes longer to pre-transcode and uses more disk space.

2. **Direct Play Button UI in Web Player when Unsupported**:
   - **Option A (Recommended): Disabled with Warning Badge**. Keep the button visible but grayed out with a lock icon and tooltip: *"❌ Unsupported on this browser (MKV / Dolby Digital Plus)"*. (Teaches the user why and avoids "missing button" confusion).
   - **Option B: Completely Hidden**. Omit the "Direct Play (Source)" option entirely from the modal when the browser cannot decode it.

---

*End of Implementation Plan.*
