# Implementation Plan — Pre-Merge Architectural Polish Directive

## Context & Objectives
Following the Gemini Argon review of the `argon-review` branch (`docs/ARCHITECTURAL_TIGHTENING_MASTER_REVIEW.md`), Slices 1–4 are certified. Before merging `feat/argon-architectural-revamp` and updating the `argon-review` snapshot, this implementation plan executes the final four pre-merge polish findings identified by Argon:
1. Deduplicate redundant subtitle integration tests in the Rust test harness.
2. Align `core/device/` layer naming in Flutter to the canonical `data/` Clean Architecture convention.
3. Enforce unidirectional domain boundaries in `rust/src/services/` by removing extraneous cross-domain imports.
4. Tighten `spec-drift.ts` in the React SPA by inlining canonical types and adding `@deprecated` mappings.
5. Update `docs/ARCHITECTURAL_TIGHTENING_MASTER_REVIEW.md` and execute the multi-pillar verification gate.

---

## 1. Scope

### In Scope
* **Task 1: Deduplicate Subtitle Integration Tests in `rust/`**
  - Migrate unique test functions from `rust/tests/integration/media_pipeline/subtitle_test.rs` (`test_opensubtitles_hash_computation`, `test_language_cache_hit_and_eviction`, `test_detect_language_fallback`, `test_proactive_acquisition_flow`, `test_negative_match_cache_prevents_query`) into `rust/tests/integration/media_pipeline/subtitles_test.rs`.
  - Delete `rust/tests/integration/media_pipeline/subtitle_test.rs`.
  - Remove `mod subtitle_test;` from `rust/tests/integration/media_pipeline/mod.rs`.
* **Task 2: Align `core/device/` Layer Naming in `flutter_client/`**
  - Move `flutter_client/lib/core/device/infrastructure/device_capability_service.dart` to `flutter_client/lib/core/device/data/device_capability_service.dart`.
  - Remove the empty `flutter_client/lib/core/device/infrastructure/` directory.
  - Update all 20 import occurrences across `flutter_client/lib/` and `flutter_client/test/`.
* **Task 3: Enforce Unidirectional Domain Boundaries in `rust/src/services/`**
  - Remove unused cross-domain service imports (`HlsService`, `PathResolver`, `PreviewService`, `ScanService`, `SystemService`) from `rust/src/services/ops/storage_service.rs`.
  - Verify sibling service modules across `media_pipeline`, `casting`, `catalog`, `identity`, and `ops` maintain zero circular couplings and that orchestration remains in route handlers.
* **Task 4: Tighten `spec-drift.ts` & Schema Exports in `web/`**
  - Update React components in `web/src/components/` and `web/src/features/` to import `MovieSummaryItem` from `types.ts` directly.
  - In `web/src/lib/api/spec-drift.ts`, add `@deprecated` JSDoc annotations on legacy adapter types mapping each to its canonical `docs/openapi.yaml` schema.
* **Task 5: Update Master Review Dossier & Run Verification Gate**
  - Append "5. Pre-Merge Polish (Argon Sign-Off)" section to `docs/ARCHITECTURAL_TIGHTENING_MASTER_REVIEW.md`.
  - Run full test suite: Rust (`cargo check`, `cargo test`), Flutter (`flutter analyze`, unit tests), Web (`typecheck`, `lint`, `vitest`, `build`).
  - Update the lightweight snapshot commit on `argon-review` and push to GitHub.

### Deliberately Out of Scope
* **No Database Schema Changes:** PostgreSQL schema (`rust/src/db.rs`) is unmodified.
* **No HTTP Route Path Changes:** Axum route paths and OpenAPI endpoints remain strictly preserved.
* **No Historical Document Edits:** Historical files in `docs/` and `Handoffs/` remain untouched per repository guardrails.

---

## 2. Exit Criteria
1. **Rust Integration Harness:** `scripts/cargo.bat test --test integration` passes 100% with `subtitle_test.rs` cleanly eliminated and all assertions preserved in `subtitles_test.rs`.
2. **Flutter Clean Architecture:** Zero references to `core/device/infrastructure/` remain; `flutter analyze` passes with 0 warnings and 0 errors; all unit/widget tests pass.
3. **Rust Service Boundaries:** `storage_service.rs` has zero unused cross-domain imports and compiles cleanly.
4. **Web Client Types:** `npm run typecheck` (`tsc -b`), `npm run lint` (`oxlint`), `npm run test` (Vitest), and `npm run build` pass with exit code 0.
5. **Git & Remote Parity:** Working tree on `feat/argon-architectural-revamp` is clean and committed; `argon-review` snapshot is updated (< 10 MB) and pushed to GitHub.

---

## 3. Risk Assessment & Mitigations
| Risk | Potential Impact | Mitigation & Detection |
|---|---|---|
| Missed import path in Flutter | Compilation failure in Flutter client | `flutter analyze` checks every file across `lib/` and `test/` |
| Lost test coverage during subtitle test merge | Undetected regression in subtitle hash/cache logic | Explicit test inventory: all 5 functions verified in `subtitles_test.rs` before deletion |
| TypeScript type breakage in Web SPA | Build failure during bundle generation | `npm run typecheck` and `npm run build` run as mandatory gates |
| Bloat in `argon-review` snapshot | Repository exceeding 100 MB Argon limit | Lightweight tree generator strips heavy media frames and video assets before committing |

---

## 4. Open Decisions
* **None:** All tasks directly execute the explicit findings certified and requested in the Argon review directive.
