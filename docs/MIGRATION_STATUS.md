# Media Server Modernization — Migration Status & Handoff

**Authoritative Roadmap:** [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md)  
**Dedicated Branch:** `feat/rust-react-postgres-migration`  
**Current Baseline Commit:** `b007944` (`feat(api): add OpenAPI 3.1 specification and automated contract test suite (Phase 1)`)  
**Last Updated:** October 10, 2026  

---

## 1. Migration Phase Progress Tracker

| Phase | Title | Status | Primary Artifacts / Deliverables |
|:---:|---|:---:|---|
| **0** | **Read-Only Architecture Audit** | ✅ **COMPLETE** | [`docs/PHASE_0_ARCHITECTURE_AUDIT.md`](PHASE_0_ARCHITECTURE_AUDIT.md) — 42 endpoints, 10 templates, SQLite models, dual-GPU scheduling, risk register, Flutter compatibility matrix. |
| **1** | **OpenAPI Spec & Automated Contract Tests** | ✅ **COMPLETE** | [`docs/openapi.yaml`](openapi.yaml) (OpenAPI 3.1, 42 routes, 31 schemas), [`tests/test_api_contracts.py`](../tests/test_api_contracts.py) (15/15 passing contract tests). |
| **2** | **React Web Frontend** | ⏳ **PENDING AUTHORIZATION** | Proposed web app under `web/` (Vite, TypeScript, Tailwind, shadcn/ui) consuming existing Flask API. |
| **3** | **PostgreSQL Migration** | 📋 Planned | Schema definition, versioned migrations, idempotent SQLite data transfer, rollback plan. |
| **4** | **Rust API Foundation** | 📋 Planned | Axum / Tokio / SQLx modular server, configuration, auth, shared data models. |
| **5** | **Media Streaming & Static Delivery in Rust** | 📋 Planned | Zero-copy byte-range streaming, HLS manifests, DLNA headers, CORS, range verification. |
| **6** | **Transcoding Orchestration & FFmpeg in Rust** | 📋 Planned | Dual-GPU chunk scheduling, hardware probe, progress tracking, fallback, queue safety. |
| **7** | **Live Events & Real-Time Client Integration** | 📋 Planned | SSE / WebSocket streaming for transcode progress, device heartbeats, scan telemetry. |
| **8** | **Operations, Hosting & Cloudflare Deployment** | 📋 Planned | Windows service (NSSM) / Linux service configuration, Cloudflare named tunnel verification. |
| **9** | **Deprecation, Cleanup & Post-Cutover** | 📋 Planned | Decommission legacy Flask endpoints and Jinja templates once all clients are verified. |

---

## 2. Completed Phases Summary

### Phase 0 — Read-Only Architecture Audit
- **Report Document:** [`docs/PHASE_0_ARCHITECTURE_AUDIT.md`](PHASE_0_ARCHITECTURE_AUDIT.md)
- **Key Findings:**
  - 42 active Flask endpoints inventoried across 6 blueprints (`api`, `pages`, `media`, `subtitles`, `upload`, `static`).
  - 10 Jinja templates mapped to proposed modular React components.
  - Dual-GPU chunked transcoding architecture mapped (`chunk_transcode_service.py`, discrete RX 560X + integrated Vega 8).
  - Storage tiering documented: Fast SSD `E:\MediaServer` (app, DB, HLS cache, previews) vs. Mass HDD `D:\Flicks` (raw media, uploads, archive).
  - Flutter / Fire TV Stick 4K client API contracts mapped (`year` nullable int, `rating` nullable float, `direct_play` authoritative bool).

### Phase 1 — OpenAPI 3.1 Specification & Automated Contract Tests
- **Commit:** `b0079448d134da72a3fa16480c938ff9489434dc`
- **Spec:** [`docs/openapi.yaml`](openapi.yaml)
  - Full OpenAPI 3.1.0 document describing all 42 registered endpoints and 31 schemas.
  - Formally documents byte-range streaming, DLNA DIDL headers, chunked upload lifecycle, device telemetry, and subtitles.
- **Contract Tests:** [`tests/test_api_contracts.py`](../tests/test_api_contracts.py)
  - 15 automated test cases validating actual Flask route responses against `docs/openapi.yaml`.
  - Enforces Flutter-sensitive types: `year` nullable int, `rating` nullable float, `direct_play` boolean logic (`container == 'mp4' and video_codec in {'h264', 'avc1'} and audio_codec in {'aac', 'mp3'}`).
- **Verification Command:**
  ```powershell
  .\venv\Scripts\python.exe -m pytest tests/test_api_contracts.py -v
  ```
  *Result: 15 passed in ~11s.*
- **Existing Regression Test Suite:**
  ```powershell
  .\venv\Scripts\python.exe -m pytest tests/test_movies_api.py tests/test_devices.py tests/test_media_cors.py tests/test_app_updates.py tests/test_subtitle_upload.py tests/test_system.py tests/test_caching.py tests/test_utils.py tests/test_resolver.py
  ```
  *Result: 98 passed in ~13s.*

---

## 3. Preserved Working-Tree State & Guardrails
- **Branch:** `feat/rust-react-postgres-migration`
- **Zero Production Changes:** No production Flask code, database schemas, or Flutter client files modified.
- **Preserved Working-Tree Files:** 12 pre-existing uncommitted files across `app/`, `flutter_client/`, and `tests/` remain preserved.

---

## 4. Next Phase: Phase 2 Scope & Acceptance Criteria
According to [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md):
- **Objective:** Scaffold and build the modern React web frontend against the *existing* Flask API (and OpenAPI contract) prior to backend replacement.
- **Tech Stack:** React 19, TypeScript, Vite, Tailwind CSS, shadcn/ui.
- **Acceptance Criteria:**
  1. Vite + React + TypeScript initialized in `web/` directory with production build pipeline.
  2. Typed API client generated from or validated against `docs/openapi.yaml`.
  3. Core workflows accessible: Library browsing, Movie details, HTML5 video player with seek preview, Subtitles selector, Connected devices view.
  4. Existing Jinja templates remain completely untouched and operational as fallback.
