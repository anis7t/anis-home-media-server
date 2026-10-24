# Phase 2R-A Walkthrough: Dual-Origin Vite Proxy & Dev Environment Wiring

> **Document Type:** Sliced Migration Walkthrough  
> **Repository:** `anis7t/media-server`  
> **Branch:** `feat/rust-api-foundation`  
> **Governing Document:** [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](file:///e:/MediaServer/docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md) §Phase 2 & §Phase 5  
> **Status:** ✅ **DELIVERED, VERIFIED & PASSING**

---

## 1. Executive Summary

Phase 2R-A is the first slice of **Phase 2R: React Frontend & Rust Engine Integration**. It configures Vite's local development server (`web/vite.config.ts`) with a dual-origin proxy architecture:
1. **High-Throughput Native Rust Engine (`RUST_ORIGIN = http://127.0.0.1:8001`)**:
   - Movie catalog & details (`/api/movies`, `/api/movie`)
   - Watch progress persistence (`/api/progress`)
   - Live hardware telemetry HUD (`/api/system-status`)
   - Live seek preview metadata & thumbnails (`/api/seek-preview-meta`, `/seek-preview`, `/preview-vtt`)
   - Subtitle catalog, dynamic cue offset shifting, and uploads (`/api/subtitles`, `/subtitles`, `/api/upload-subtitle`)
   - Direct byte-range media streaming (`/media`)
   - Dynamic multi-GPU HLS playlists & segments (`/hls`)
   - Transcode job status polling (`/api/transcode-status`, `/api/transcodes`)
   - Engine health check (`/api/health`)
2. **Python Flask / Waitress Backend (`FLASK_ORIGIN = http://127.0.0.1:8000`)**:
   - Google OAuth 2.0 flow & authentication tokens (`/auth`, `/api/auth`)
   - LAN Google Cast & DLNA remote playback (`/api/cast`)
   - Connected device fleet telemetry & client hints (`/api/devices`)
   - Admin PIN verification & storage retention policies (`/api/admin`, `/api/storage`)
   - Filesystem library scan trigger (`/api/scan`)
   - TMDb artwork cache & local poster delivery (`/tmdb-poster`, `/tmdb-backdrop`, `/poster`)

---

## 2. Changes Made

### Frontend Configuration (`web/`)

1. **[`web/vite.config.ts`](file:///e:/MediaServer/web/vite.config.ts)**:
   - Defined `RUST_ORIGIN` defaulting to `process.env.RUST_API_ORIGIN ?? 'http://127.0.0.1:8001'`.
   - Defined `FLASK_ORIGIN` defaulting to `process.env.MEDIA_SERVER_ORIGIN ?? 'http://127.0.0.1:8000'`.
   - Reordered proxy configuration so specific Rust endpoints take precedence in Vite/Connect iteration order over the general `'/api'` catch-all.
   - Preserved Gate F strict same-origin semantics without altering backend production CORS policies.

2. **[`web/src/test/proxy-coverage.test.ts`](file:///e:/MediaServer/web/src/test/proxy-coverage.test.ts)**:
   - Upgraded test suite from single-origin assertions to dual-origin partition validation.
   - Added `it('routes Rust-migrated endpoints to the Rust engine origin (:8001)')`.
   - Added `it('routes unmigrated endpoints to the Flask origin (:8000)')`.
   - Added `it('targets a valid loopback origin for every entry')`.

---

## 3. Verification & Test Outcomes

### 1. Vitest Test Suite (Unit & Integration)
- **Command:** `npm test -- --run`
- **Result:** **25 / 25 test files passed**, **174 / 174 tests passed** (expanded from 172 to 174 tests with 100% pass rate).
- **Execution Time:** ~25.10s.

### 2. TypeScript Compilation Check
- **Command:** `npm run typecheck` (`tsc -b`)
- **Result:** 0 errors.

### 3. Code Linter
- **Command:** `npm run lint` (`oxlint`)
- **Result:** 0 errors across 81 files.

### 4. Full Verification & Coverage Battery
- **Command:** `npm run verify` (`tsc -b && oxlint && vitest run --coverage && vite build`)
- **Result:** 100% passed with coverage report generated.

### 5. Production SPA Build
- **Command:** `npm run build`
- **Result:** Built in **704ms** (`dist/` generated cleanly).

---

## 4. Next Phase: Phase 2R-B (Static SPA Serving & Fallback in Rust Axum)

With the dev proxy wired, the next phase (**Phase 2R-B**) will enable the native Rust executable (`media-server-api.exe`) to directly serve the compiled React SPA from `web/dist/` with client-side SPA fallback routing (`ServeDir` / `ServeFile` in `tower-http`), allowing users to access the React frontend directly from `http://127.0.0.1:8001/`.
