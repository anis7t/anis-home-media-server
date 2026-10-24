# Architectural Tightening: Slice 4 Implementation Plan
## Cross-Client Contract Enforcement & Web Parity

### Origin & Context
Following the successful completion and verification of Slice 1 (Workspace Hygiene), Slice 2 (Rust Backend Domain Modularization & GPU Governance), and Slice 3 (Flutter Client Layer Standardization & Audio Compression), this plan executes **Slice 4**, the final slice of the Argon Architectural Tightening Directive.

Slice 4 enforces bidirectional contract integrity between the native Rust Axum backend (`rust/`), the Flutter Android/Fire TV client (`flutter_client/`), and the React 19 SPA (`web/`), anchoring all three pillars to the authoritative OpenAPI 3.1 specification (`docs/openapi.yaml`).

---

### 1. Scope

#### What Changes:
1. **OpenAPI Specification Synchronization (`docs/openapi.yaml`):**
   - Resolve documented schema drift identified in `web/src/lib/api/spec-drift.ts` and `rust/src/models/catalog/movie.rs`:
     - Update `MovieSummaryItem`: add `poster` (`type: [string, "null"]`, documenting tagged format `tmdb:<id>`, `local:<relpath>`), `details_json` (`type: [string, "null"]`), and `last_metadata_refresh` (`type: [integer, "null"]`).
     - Update `TechnicalSpecs`: add `resolution_badge`, `video_profile`, `container`, `file_size`, and `subtitles` (`type: array, items: { type: string }`), retaining `filesize` as alias.
     - Document modern Axum endpoints added during PostgreSQL & Rust modernization (e.g., QR pairing session endpoints `/api/auth/qr/*`, admin audit logs `/api/admin/audit-log`, device presence `/api/devices/presence`, and updated system status payloads).
2. **Web Client OpenAPI Typings & Spec Drift Reconciliation (`web/`):**
   - Synchronize `web/src/lib/api/schema.ts` with the updated `docs/openapi.yaml` (via `npx -y openapi-typescript ../docs/openapi.yaml -o src/lib/api/schema.ts`).
   - Update `web/src/lib/api/spec-drift.ts`: declare that the documented drift is resolved in the core schema, and adjust type aliases (`MovieSummary`, `MovieListResponseLive`, `MovieDetailsResponseLive`, `TechnicalSpecsDrift`) to map directly to the canonical schema without manual workarounds.
   - Run complete web test & verification suite: `npm run verify` (`typecheck`, `oxlint`, `vitest run`, `vite build`).
3. **Contract Enforcement Integration Tests (`rust/tests/integration/ops/api_contracts_test.rs`):**
   - Expand `api_contracts_test.rs` to validate that the Axum responses for `/api/movies`, `/api/movie/{filename}`, and `/api/system-status` strictly conform to the unified OpenAPI schemas without missing required fields or serialization errors.
4. **Final Architecture Certification across all 3 Pillars:**
   - **Rust Pillar:** `scripts/cargo.bat check` + `scripts/cargo.bat test` (all 241+ tests green).
   - **Flutter Pillar:** `flutter analyze` + `scripts/run_flutter_tests.ps1` (all 417+ tests green).
   - **Web Pillar:** `npm run verify` (typecheck, lint, test, build all green).

#### What Deliberately Does NOT Change:
- Zero breaking changes to existing public HTTP route paths or wire serialization formats.
- Zero database migrations or schema alterations in PostgreSQL.
- Flutter DTO parser logic remains intact, as it already consumes the live wire shapes.

---

### 2. Exit Criteria
Completion will be judged by the following checkable criteria:
1. `docs/openapi.yaml` accurately describes `poster`, `file_size`, `resolution_badge`, `video_profile`, `container`, and `subtitles`.
2. `web/src/lib/api/schema.ts` is regenerated from `docs/openapi.yaml` with 0 type errors.
3. `npm run typecheck`, `npm run lint`, `npm run test` (Vitest), and `npm run build` in `web/` pass with 0 errors.
4. `scripts/cargo.bat test` in `rust/` passes 100% green (all unit + integration tests).
5. `powershell -ExecutionPolicy Bypass -File scripts/run_flutter_tests.ps1` passes 100% green (all 417 tests).
6. A comprehensive walkthrough document `docs/ARCHITECTURAL_TIGHTENING_SLICE_4_WALKTHROUGH.md` is produced, and the changes are committed to `feat/argon-architectural-revamp`.

---

### 3. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| OpenAPI TypeScript schema regeneration alters types used across React components | Build failure in `web/` | `spec-drift.ts` and `types.ts` act as bridging adapters; `tsc -b` and Vitest suite (336 tests) will immediately pinpoint any mismatch. |
| OpenAPI YAML syntax errors | Broken tooling/spec | Validate `docs/openapi.yaml` via YAML parser and `openapi-typescript` generation before proceeding. |
| Test suite execution contention | Flaky test timeouts | Use established test runners (`scripts/cargo.bat test`, `scripts/run_flutter_tests.ps1`, `npm run test`) with bounded wait times. |

---

### 4. Open Decisions

1. **Spec Drift Handling in `web/src/lib/api/spec-drift.ts`:**
   - **Option A (Recommended):** Keep `spec-drift.ts` as a backward-compatible adapter export that now aliases the newly canonical `schema.ts` types, with an updated comment noting the drift has been resolved. This ensures zero disruption to existing React components that import from `spec-drift.ts`.
   - **Option B:** Refactor all React components to import directly from `types.ts` and delete `spec-drift.ts`. (Slightly higher churn across 15+ React component files).
