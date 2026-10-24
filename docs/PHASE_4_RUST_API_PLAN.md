# Phase 4: Rust API Foundation — Implementation Plan

> **Status:** PENDING USER APPROVAL  
> **Author:** Antigravity  
> **Workspace:** `E:\MediaServer`  
> **Active Branch:** `feat/rust-api-foundation`  
> **Governing Roadmap:** [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md) §4  
> **Prerequisites:** Phase 1 (Contracts), Phase 2 (React Frontend), Phase 3 (PostgreSQL Migration) — **All Complete**  
> **Exit Gate:** Rust serves selected production-like requests (`/api/system-status`, `/api/movies`, `/api/movie/{filename}`) with contract tests matching documented OpenAPI 3.1 behavior and zero split-brain data states.

---

## 1. Executive Summary & Architecture

Phase 4 establishes the **Rust backend foundation** for Anis' Home Media Server. Following the governing roadmap principles:
- **Rule 2: Preserve behavior before replacing implementation** — Rust endpoints must match the exact JSON schemas, field types, and HTTP status codes defined in [`docs/openapi.yaml`](openapi.yaml) and verified by [`tests/test_api_contracts.py`](../tests/test_api_contracts.py).
- **Rule 4: Separate risky changes** — Phase 4 does *not* touch live FFmpeg transcoding workers (Phase 6) or direct media range streaming (Phase 5). It focuses purely on high-performance, asynchronous REST API serving for telemetry and metadata queries.
- **Rule 8: Avoid premature abstraction** — Utilize idiomatic async Rust with Tokio, Axum, and SQLx compile-time checked queries directly against the PostgreSQL database (`media_server`) created in Phase 3.
- **Coexistence without split-brain**: The Rust API server will run on port `8001` (configurable via `RUST_PORT` or `PORT`), allowing side-by-side verification and zero disruption to the production Flask service running on port `8000`.

---

## 2. Technology Stack & Dependencies

| Layer | Library / Tool | Justification |
|---|---|---|
| **Language** | Rust 1.99.0 | Active host compiler (`rustc 1.99.0`, `cargo 1.99.0`) |
| **Async Runtime** | `tokio` (v1.x, full) | Industry standard async runtime with multi-threaded work-stealing scheduler |
| **HTTP Framework** | `axum` (v0.8.x) | Ergonomic, modular web framework built on Tower and Hyper with zero-cost extractors |
| **Database Driver** | `sqlx` (v0.8.x, postgres, runtime-tokio) | Pure Rust async PostgreSQL driver with connection pooling and compile-time SQL validation |
| **Serialization** | `serde` + `serde_json` | High-performance JSON serialization matching OpenAPI schemas |
| **Logging & Tracing** | `tracing` + `tracing-subscriber` | Structured logging with correlation IDs and spans |
| **Configuration** | `dotenvy` | Seamless `.env` parsing matching Flask's configuration |
| **System Telemetry** | `sysinfo` (v0.33.x) | Native Windows hardware metrics (CPU, RAM, disk space) replacing Python `psutil` |

---

## 3. Directory & Workspace Layout

We will create a clean Rust project inside `rust/`:
```text
e:\MediaServer\
├── rust/
│   ├── Cargo.toml                  # Rust package manifest
│   ├── src/
│   │   ├── main.rs                 # Binary entry point, Axum router setup, graceful shutdown
│   │   ├── config.rs               # Environment & port configuration
│   │   ├── error.rs                # AppError with Axum IntoResponse mapping
│   │   ├── db.rs                   # SQLx PgPool initialization & health checks
│   │   ├── models/                 # Strongly typed data models matching OpenAPI schemas
│   │   │   ├── mod.rs
│   │   │   ├── movie.rs            # Movie, MovieListResponse, MovieDetailsResponse
│   │   │   ├── system.rs           # SystemTelemetryResponse, Cpu, Memory, Storage
│   │   │   └── device.rs           # Device records & client hints
│   │   ├── routes/                 # Route handlers
│   │   │   ├── mod.rs
│   │   │   ├── health.rs           # /health and /api/health
│   │   │   ├── system.rs           # /api/system-status
│   │   │   └── movies.rs           # /api/movies and /api/movie/{filename}
│   │   └── services/               # Business logic
│   │       ├── mod.rs
│   │       ├── system_service.rs   # Windows hardware stats gathering (sysinfo)
│   │       └── movie_service.rs    # PostgreSQL query execution & JSON details parsing
│   └── tests/
│       ├── api_contracts_test.rs   # Contract tests asserting exact parity with Flask
│       └── system_status_test.rs   # Telemetry integration test
```

---

## 4. Step-by-Step Implementation Sequence

### Step 1: Initialize Rust Workspace (`rust/Cargo.toml`)
1. Create `rust/` directory and configure `rust/Cargo.toml` with `axum`, `tokio`, `sqlx`, `serde`, `serde_json`, `tracing`, `tracing-subscriber`, `sysinfo`, and `dotenvy`.
2. Add `target/` to `.gitignore` to ensure Rust compilation artifacts remain untracked.

### Step 2: Core Infrastructure (Config, Database & Error Handling)
1. Implement `config.rs` to read `MEDIA_SERVER_DATABASE_URL` (defaulting to `postgresql://postgres:postgres@127.0.0.1:5432/media_server`) and `PORT` (default `8001`).
2. Implement `db.rs` to configure `sqlx::postgres::PgPoolOptions` (max 16 connections, 5s acquire timeout) and perform connection validation on startup.
3. Implement `error.rs` mapping internal database and parsing errors to standard JSON error payloads (`{"error": "<message>"}`).

### Step 3: High-Performance System Telemetry (`/api/system-status`)
1. Replicate Python's `system_service.py` telemetry structure using `sysinfo`:
   - CPU overall utilization percentage.
   - Host RAM total, used, available, and usage percent.
   - Dual-drive storage pool metrics (Drive `E:` primary fast SSD and Drive `D:` mass storage).
   - Multi-GPU engine status placeholder (preserves JSON shape for discrete RX 560X & Vega 8).
2. Wire up `GET /api/system-status` and `GET /health`.

### Step 4: Library Metadata Endpoints (`/api/movies` & `/api/movie/{filename}`)
1. Implement `GET /api/movies`:
   - Query PostgreSQL `movies` table joined with `device_watch_history` (via `X-Device-Id` header) and `progress`.
   - Support optional query parameter `q` (case-insensitive substring title search).
   - Support sorting (`sort=title|year|rating|recent`).
   - Emit `MovieListResponse` matching OpenAPI schema.
2. Implement `GET /api/movie/{filename}`:
   - Query movie record by `filename`.
   - Parse and expand `details_json` (cast, directors, writers, certification, trailer key).
   - Emit `MovieDetailsResponse` matching OpenAPI schema.

### Step 5: Dual-Server Parity & Automated Verification
1. Author integration tests in `rust/tests/`:
   - Direct assertion of OpenAPI schema compliance.
   - Parity verification: Run test against Flask (port 8000) and Rust (port 8001), asserting byte-for-byte schema compatibility and field equality.
2. Execute `cargo test` and verify clean compilation with zero warnings.
3. Run React frontend (`npm test -- --run` in `web/`) against Rust proxy endpoint to confirm client transparency.

### Step 6: Documentation, Walkthrough & Handoff
1. Update `docs/MIGRATION_STATUS.md` and `docs/PROJECT_STATUS.md` with Phase 4 milestone progress.
2. Produce comprehensive post-completion walkthrough document (`docs/PHASE_4_RUST_API_WALKTHROUGH.md`).
3. Prepare session handoff.

---

## 5. Verification & Acceptance Criteria (Phase 4 Exit Gate)

| Metric / Check | Required Threshold | Verification Command |
|---|---|---|
| **Compilation** | Zero compiler errors or warnings | `cargo check --manifest-path rust/Cargo.toml` |
| **Unit & Integration Tests** | 100% passing | `cargo test --manifest-path rust/Cargo.toml` |
| **OpenAPI Contract Compliance** | Exact schema match on `/api/movies`, `/api/movie/*`, `/api/system-status` | Contract assertion test suite |
| **Non-Interference** | Flask (8000) and Rust (8001) operate concurrently without lock contention | Concurrency check |
| **Frontend Transparency** | Web UI renders catalog identically through Rust API proxy | Browser & Vitest verification |
