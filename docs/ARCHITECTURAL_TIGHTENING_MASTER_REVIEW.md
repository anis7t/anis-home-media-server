# Argon Architectural Tightening Directive — Master Review & Certification Dossier

**Branch:** `argon-review` (lightweight review snapshot < 15MB) / `feat/argon-architectural-revamp`  
**Stack:** 100% Rust Axum (:8000) + React 19 SPA + Flutter Mobile/Android TV + PostgreSQL 18.4  
**Status:** ✅ **All 4 Slices Completed, Hardware-Verified, and Multi-Pillar Certified**

---

## Executive Summary

This dossier synthesizes the complete execution of the **Argon Architectural Tightening Directive** across the `anis-home-media-server` repository. The directive targeted four critical areas of technical debt, architectural sprawl, and cross-client divergence:

1. **Slice 1 (Hygiene & Dead-Code Purge):** Cleaned root debris, deleted dead player proof-of-concept code, purged transient test captures, and consolidated verification tooling.
2. **Slice 2 (Rust Domain Modularization & GPU Governance):** Reorganized 29 services, 22 routes, and 12 models into 5 bounded domains, merged the scanner engine, instituted deterministic child process governance (`ProcessGuard`) and priority semaphores, and consolidated 34 individual test binaries into a unified integration test harness.
3. **Slice 3 (Flutter Client Clean Architecture & Asset Compression):** Standardized all 12 Flutter feature directories into canonical 3-layer Clean Architecture (`domain/`, `data/`, `presentation/`), untangled Settings UI from the app updater, unified catalog state consumption via Riverpod, and compressed brand intro audio from uncompressed WAV (541 KB) to 256k AAC M4A (104 KB, saving >81% per APK).
4. **Slice 4 (OpenAPI Contract Synchronization & Web Parity):** Synchronized the canonical `docs/openapi.yaml` specification with live backend response models, regenerated TypeScript definitions, eliminated historical spec drift in the React 19 SPA, and verified end-to-end parity with a dedicated 22-endpoint API probe suite.

---

## 1. Slice Index & Detailed Documentation

| Slice | Focus Area | Plan Document | Walkthrough & Proof | Primary Commit |
|---|---|---|---|---|
| **Slice 1** | Workspace Hygiene & Dead-Code Purge | [Slice 1 Plan](ARCHITECTURAL_TIGHTENING_SLICE_1_PLAN.md) | [Slice 1 Walkthrough](ARCHITECTURAL_TIGHTENING_SLICE_1_WALKTHROUGH.md) | [`06d7988`](https://github.com/anis7t/anis-home-media-server/commit/06d7988) |
| **Slice 2** | Rust Modularization, GPU Governance & Test Consolidation | [Slice 2 Plan](ARCHITECTURAL_TIGHTENING_SLICE_2_PLAN.md) | [Slice 2 Walkthrough](ARCHITECTURAL_TIGHTENING_SLICE_2_WALKTHROUGH.md) | [`13a80a1`](https://github.com/anis7t/anis-home-media-server/commit/13a80a1) |
| **Slice 3** | Flutter Clean Architecture & Intro Audio Compression | [Slice 3 Plan](ARCHITECTURAL_TIGHTENING_SLICE_3_PLAN.md) | [Slice 3 Walkthrough](ARCHITECTURAL_TIGHTENING_SLICE_3_WALKTHROUGH.md) | [`5c9e5f8`](https://github.com/anis7t/anis-home-media-server/commit/5c9e5f8) |
| **Slice 4** | OpenAPI Synchronization, Spec Drift & Cross-Client Parity | [Slice 4 Plan](ARCHITECTURAL_TIGHTENING_SLICE_4_PLAN.md) | [Slice 4 Walkthrough](ARCHITECTURAL_TIGHTENING_SLICE_4_WALKTHROUGH.md) | [`30fa6f4`](https://github.com/anis7t/anis-home-media-server/commit/30fa6f4) |

---

## 2. In-Depth Architectural Changes

### 2.1 Slice 1: Workspace Hygiene & Dead-Code Purge
* **Stray Root Cleanup:** Removed stray file `=` and editor artifact `.vscode/settings.json.bak`. Moved `remove_c_mediaserver_stub.cmd` and `run_scrcpy.bat` into `scripts/`.
* **Python Tooling:** Configured `pyrightconfig.json` to strictly scope analysis to `scripts/` and `tests/load/`.
* **Transient Web Captures:** Deleted `web/_prng_capture.*` and `web/_tofixed_capture.*` and updated `web/.gitignore` to ignore `_*_capture.*`.
* **Flutter PoC Elimination:** Completely deleted `flutter_client/lib/features/player_poc/` (`player_poc_screen.dart`, `media_kit_player_adapter.dart`, `player_controller_interface.dart`, `seek_preview_controller.dart`). Removed route `/player-poc` and `playerPoc` identifier from `flutter_client/lib/app/routes.dart`.
* **Golden Fixtures Relocation:** Relocated PRNG and toFixed golden fixtures into `flutter_client/test/features/intro/fixtures/` as persistent contract baselines.

### 2.2 Slice 2: Rust Domain Modularization, Subprocess Governance & Test Consolidation
* **5 Domain Namespaces:** Modularized flat module sprawl into bounded contexts:
  - `media_pipeline`: Range streaming, HLS transcoding, chunk transcode engine, probe service, GPU telemetry, worker pool, sweeper, seek previews, subtitles.
  - `casting`: Chromecast protocol, discovery, registry, transport, origin proxy, DLNA.
  - `catalog`: Movies catalog, posters/backdrops, scanner engine (`catalog/scanner/`), TMDb metadata, playback progress.
  - `identity`: Auth & session validation, Google OAuth, QR sign-in, connected devices, admin mutation audit logging.
  - `ops`: Storage pool telemetry & purge, system status, upload staging, transcode jobs queue, app distribution, health check, SPA fallback.
* **Transparent Backward Compatibility:** Module facades in `services/mod.rs`, `routes/mod.rs`, and `models/mod.rs` ensure 100% backward-compatible imports without breaking existing call sites.
* **FFmpeg/FFprobe Subprocess Governance:**
  - `ProcessGuard` (RAII): Ensures child processes are immediately terminated upon drop (`kill_on_drop(true)` with non-blocking `try_wait()` reaping), preventing zombie FFmpeg processes when clients disconnect or seek abruptly.
  - Priority Concurrency Semaphores: `InteractivePlayback` (high priority for active streaming), `InteractiveProbe` (bounded ffprobe analysis), `BackgroundExtract` (thumbnails/subtitles), and `BackgroundPreTranscode` (background pre-transcoding yielding to active streams).
* **Consolidated Test Harness:** Replaced 34 separate integration test binaries with a single unified binary (`rust/tests/integration/main.rs`), cutting test compilation and link overhead by over 50%.

### 2.3 Slice 3: Flutter Clean Architecture & Intro Audio Compression
* **Uniform 3-Layer Clean Architecture:** Restructured all 12 feature modules in `flutter_client/lib/features/` to adhere strictly to:
  - `domain/`: Business entities, contract interfaces, value objects.
  - `data/`: Repositories, data sources, platform bridges, hardware adapters.
  - `presentation/`: Controllers, Riverpod state providers, screens, and widgets.
* **Settings Decoupling:** Relocated `settings_content.dart` and `settings_sheet.dart` out of `features/updater/` into `features/settings/presentation/widgets/`.
* **Catalog State Unification:** `home_feed_controller.dart` consumes the canonical Riverpod `libraryControllerProvider`, eliminating redundant network queries.
* **Intro Audio Compression:** Transcoded uncompressed brand intro PCM audio `intro-theme.wav` (541 KB) to 256k AAC `intro-theme.m4a` (104 KB), reducing asset footprint by **>81%** (439 KB saved per APK) while maintaining 44.1 kHz stereo fidelity.

### 2.4 Slice 4: OpenAPI Contract Synchronization & Web Parity
* **OpenAPI 3.1 Specification (`docs/openapi.yaml`):** Synchronized live fields:
  - `MovieSummaryItem`: `poster`, `details_json`, `last_metadata_refresh`.
  - `TechnicalSpecs`: `resolution_badge`, `video_profile`, `container`, `file_size`, `subtitles`.
  - `MediaInfoResponse`: `quality_ladder` array and `QualityOption` schema.
* **Web Client Type Generation:** Regenerated `web/src/lib/api/schema.ts` from the updated spec.
* **Spec Drift Reconciled:** Refactored `web/src/lib/api/spec-drift.ts` to alias generated canonical types, eliminating historical drift while preserving React SPA compatibility.
* **Rust Integration Assertions:** Added `api_contracts_test.rs` validating that all live Axum endpoints strictly adhere to the OpenAPI schema.

---

## 3. Multi-Pillar Test & Verification Matrix

| Pillar | Verification Suite | Command | Result |
|---|---|---|---|
| **Rust Backend** | Compiler & Lint Check | `cargo check` | **0 warnings, 0 errors** (1.51s) |
| **Rust Backend** | Integration Test Suite | `cargo test --test integration` | **242 passed, 0 failed** (100% green) |
| **Rust Backend** | Android API Contract Probe | `python scripts/probe_android_api.py` | **22/22 endpoints passed** |
| **Flutter Client** | Static Analysis | `flutter analyze` | **No issues found!** (0 warnings, 0 errors) |
| **Flutter Client** | Unit & Widget Tests | `scripts/run_flutter_tests.ps1` | **417 passed, 0 failed** (12 live tests skipped) |
| **Web SPA** | TypeScript Typecheck | `npm run typecheck` (`tsc -b`) | **0 errors** (exit code 0) |
| **Web SPA** | Unit & Component Tests | `npm run test` (Vitest) | **46/46 files passed, 336/336 tests green** |
| **Web SPA** | Production Bundle Build | `npm run build` (Vite) | **Built in 2.11s** (exit code 0) |

---

## 4. Key Source Code & File Reference Map

```text
E:\MediaServer/
├── docs/
│   ├── ARCHITECTURAL_TIGHTENING_MASTER_REVIEW.md    <-- THIS MASTER OVERVIEW
│   ├── ARCHITECTURAL_TIGHTENING_SLICE_1_PLAN.md / WALKTHROUGH.md
│   ├── ARCHITECTURAL_TIGHTENING_SLICE_2_PLAN.md / WALKTHROUGH.md
│   ├── ARCHITECTURAL_TIGHTENING_SLICE_3_PLAN.md / WALKTHROUGH.md
│   ├── ARCHITECTURAL_TIGHTENING_SLICE_4_PLAN.md / WALKTHROUGH.md
│   └── openapi.yaml                                 <-- Synchronized API Contract
├── rust/
│   ├── src/
│   │   ├── services/
│   │   │   ├── media_pipeline/                      <-- ProcessGuard, GpuService, HlsService
│   │   │   ├── casting/                             <-- Cast & DLNA subsystems
│   │   │   ├── catalog/                             <-- MovieService, Scanner Engine
│   │   │   ├── identity/                            <-- AuthService, AuditService, DeviceService
│   │   │   └── ops/                                 <-- StorageService, SystemService, JobService
│   │   ├── routes/                                  <-- Domain-modularized Axum route handlers
│   │   └── models/                                  <-- Domain-modularized database models
│   └── tests/
│       └── integration/main.rs                      <-- Consolidated single test harness
├── flutter_client/
│   ├── assets/audio/intro-theme.m4a                 <-- 104KB compressed AAC intro audio
│   └── lib/features/                                <-- Standardized 12 features (domain/data/presentation)
│       ├── settings/                                <-- Cleaned Settings UI
│       ├── player/                                  <-- Production player (PoC purged)
│       └── ...
└── web/
    └── src/lib/api/
        ├── schema.ts                                <-- Regenerated OpenAPI TypeScript types
```

---

## 5. Pre-Merge Polish (Argon Sign-Off)

Following the initial Argon review of `argon-review`, a final pre-merge consistency and boundary pass was executed:

1. **Rust Subtitle Integration Test Deduplication:**
   - Consolidated all 5 test functions from `rust/tests/integration/media_pipeline/subtitle_test.rs` into `subtitles_test.rs`.
   - Deleted redundant `subtitle_test.rs` and removed its declaration from `media_pipeline/mod.rs`.
   - All 21 tests in `subtitles_test.rs` verified 100% green.
2. **Flutter `core/device/` Layer Alignment:**
   - Standardized `flutter_client/lib/core/device/infrastructure/device_capability_service.dart` to `core/device/data/device_capability_service.dart`.
   - Removed the empty `infrastructure/` directory to match the clean `domain/` + `data/` convention used across all 12 feature domains.
   - Updated all 20 import occurrences across `flutter_client/lib/` and `flutter_client/test/` with 0 analysis issues.
3. **Unidirectional Rust Service Boundaries:**
   - Refactored `rust/src/services/ops/storage_service.rs` to use explicit domain paths (`services::catalog::{PathResolver, ScanService}`, `services::media_pipeline::{HlsService, PreviewService}`, `services::ops::SystemService`).
   - Audited all 5 service domains to guarantee zero circular dependencies (strict DAG architecture).
4. **Web `spec-drift.ts` Tightening:**
   - Inlined canonical type exports (`MovieSummary`, `MovieListResponse`, `MovieDetailsResponse`) directly from `web/src/lib/api/types.ts` into all active components and `client.ts`.
   - Marked all legacy aliases in `web/src/lib/api/spec-drift.ts` with explicit `@deprecated` JSDocs pointing to the canonical `docs/openapi.yaml` schema.

