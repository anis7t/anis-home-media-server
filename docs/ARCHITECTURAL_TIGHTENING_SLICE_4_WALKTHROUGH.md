# Architectural Tightening: Slice 4 Walkthrough
## Cross-Client Contract Enforcement & Web Parity

### Summary
Slice 4 of the Argon Architectural Tightening Directive has been fully implemented, verified, and certified across all three pillars of `anis-home-media-server`:
1. **Rust / Axum Backend (`rust/`)**
2. **Flutter Android / Fire TV Client (`flutter_client/`)**
3. **React 19 SPA (`web/`)**

This slice anchors all client DTOs and backend serializers to the authoritative OpenAPI 3.1 specification (`docs/openapi.yaml`), resolving historical schema drift and guaranteeing cross-client contract integrity.

---

## 1. Scope of Changes

### 1.1 OpenAPI 3.1 Specification Synchronization (`docs/openapi.yaml`)
- **`MovieSummaryItem` Model:**
  - Added `poster` property (`type: [string, "null"]`): documents the canonical tagged poster reference scheme (`tmdb:<id>`, `local:<relpath>`) and artwork URLs.
  - Added `details_json` property (`type: [string, "null"]`): documents the raw JSON payload holding TMDb metadata (tagline, cast, crew, and certifications).
  - Added `last_metadata_refresh` property (`type: [integer, "null"]`): documents the 4-hour metadata refresh epoch timestamp.
- **`TechnicalSpecs` Model:**
  - Added `resolution_badge` (`type: [string, "null"]`): standardized display badge (e.g. `1080p`, `4K`).
  - Added `video_profile` (`type: [string, "null"]`): encoding profile (e.g. `High`, `Main 10`).
  - Added `container` (`type: [string, "null"]`): container format descriptor (e.g. `Matroska / WebM`, `MP4`).
  - Added `file_size` (`type: [string, "null"]`): human-readable size string (e.g. `2.4 GB`), retaining `filesize` as a backward-compatible alias.
  - Added `subtitles` (`type: array, items: { type: string }`): available subtitle track descriptors.
- **`MediaInfoResponse` & `QualityOption`:**
  - Added `quality_ladder` array property to `MediaInfoResponse`.
  - Added `QualityOption` schema declaring `label`, `quality`, `height`, `width`, `bitrate`, `is_direct`, `is_ready`, and `hls_url`.

### 1.2 Web Client Typings & Schema Drift Resolution (`web/`)
- Regenerated `web/src/lib/api/schema.ts` directly from `docs/openapi.yaml` using `openapi-typescript 7.13.0`.
- Updated `web/src/lib/api/spec-drift.ts` (Option A):
  - Documented that the historical gap discovered on 2026-10-12 during Phase 2 is now resolved.
  - Refactored `MovieSummary`, `MovieListResponseLive`, `MovieDetailsResponseLive`, and `TechnicalSpecsDrift` to alias canonical generated types from `types.ts` directly.
  - Maintained zero breaking changes across all React SPA components.

### 1.3 Rust Integration Contract Verification (`rust/tests/integration/ops/api_contracts_test.rs`)
- Enhanced `test_movie_details_endpoint` to assert that live Axum responses contain `resolution_badge`, `container`, and valid `subtitles` arrays.
- Added `test_media_info_quality_ladder_contract` to assert that `GET /api/media-info/{filename}` conforms to `MediaInfoResponse` with a populated `quality_ladder`, validating every `QualityOption` field (`label`, `quality`, `height`, `width`, `bitrate`, `is_direct`, `is_ready`).

---

## 2. Multi-Pillar Test & Verification Outcomes

### 2.1 Rust / Axum Backend Pillar
- **Compiler / Static Analysis:**
  ```
  ..\scripts\cargo.bat check
  Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.83s
  0 warnings, 0 errors
  ```
- **Consolidated Integration Test Suite:**
  ```
  ..\scripts\cargo.bat test --test integration
  test result: ok. 242 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 132.86s
  ```
  All 242 domain integration tests passed (100% green).

### 2.2 Flutter Mobile & Fire TV Pillar
- **Flutter Static Analysis:**
  ```
  flutter analyze
  No issues found! (ran in 7.8s)
  0 warnings, 0 errors
  ```
- **Flutter Unit & Widget Test Runner:**
  ```
  powershell -ExecutionPolicy Bypass -File scripts/run_flutter_tests.ps1
  01:47 +417 ~12: All tests passed!
  RESULT: PASS
  ```
  All 417 unit and widget tests passed (100% green).

### 2.3 React 19 SPA Web Pillar
- **TypeScript Typecheck:**
  ```
  npm run typecheck (tsc -b)
  Exit code: 0
  ```
- **Oxlint Linter:**
  ```
  npm run lint (oxlint)
  0 errors, 55 informational warnings on 135 files (199ms)
  Exit code: 0
  ```
- **Vitest Test Suite:**
  ```
  npm run test (vitest run)
  Test Files  46 passed (46)
       Tests  336 passed (336)
  Exit code: 0
  ```
- **Production Bundle Build:**
  ```
  npm run build (tsc -b && vite build)
  ✓ built in 807ms
  Exit code: 0
  ```

---

## 3. Architecture Tightening Summary Across All 4 Slices

With the completion of Slice 4, the entire Gemini Argon Architectural Tightening Directive is accomplished:

| Slice | Focus Area | Deliverables | Status |
|---|---|---|---|
| **Slice 1** | Hygiene & Dead-Code Purge | Deleted stray root artifacts (`=`, `.bak`), purged debug captures, pruned `pyrightconfig.json`, removed dead Flutter `player_poc/` | **Committed (`06d7988`)** |
| **Slice 2** | Rust Modularization & GPU Governance | Reorganized `services/`, `routes/`, `models/` into 5 domain namespaces (`media_pipeline`, `casting`, `catalog`, `identity`, `ops`), merged `scanner/`, centralized GPU & subprocess governance in `gpu_service.rs` with `ProcessGuard`, consolidated 34 test binaries into 1 | **Committed (`13a80a1`)** |
| **Slice 3** | Flutter Clean Architecture & Asset Optimization | Standardized 12 feature folders to `domain/`, `data/`, `presentation/`, moved Settings UI out of `updater/`, compressed intro theme audio to 256k AAC (saved 81% / 439 KB per APK) | **Committed (`5c9e5f8`)** |
| **Slice 4** | Contract Enforcement & Web Parity | Synchronized `docs/openapi.yaml` with live models, regenerated `schema.ts`, reconciled `spec-drift.ts`, added quality ladder contract tests, verified Rust (242 tests), Flutter (417 tests), and Web (336 tests) 100% green | **Verified & Ready for Commit** |
