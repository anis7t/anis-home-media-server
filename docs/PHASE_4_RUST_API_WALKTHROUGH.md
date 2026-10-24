# Phase 4 Walkthrough — Rust API Foundation (Axum + Tokio + SQLx)

> **Document Type:** Migration Phase Walkthrough & Verification  
> **Repository:** `anis7t/media-server`  
> **Branch:** `feat/rust-api-foundation`  
> **Depends On:** Phase 3 PostgreSQL Migration (`docs/PHASE_3_POSTGRESQL_MIGRATION_WALKTHROUGH.md`)  
> **Status:** ✅ **DELIVERED & VERIFIED** (4/4 Contract Integration Tests Passing, 0 Warnings)

---

## 1. Executive Summary

Phase 4 establishes the high-performance Rust API foundation for the media server, fulfilling the roadmap requirements outlined in [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md) §Phase 4 and [`docs/PHASE_4_RUST_API_PLAN.md`](PHASE_4_RUST_API_PLAN.md).

The Rust API server is constructed using:
- **Axum 0.8** & **Tokio 1** for asynchronous, thread-pooled HTTP routing and connection handling.
- **SQLx 0.8** (PostgreSQL, Chrono, JSON) with connection pooling and asynchronous query execution against the live PostgreSQL 18.4 database (`media_server`).
- **Sysinfo 0.33** for native OS-level CPU, RAM, and dual-volume storage telemetry (`D:` mass storage + `E:` fast SSD runtime).
- **Tower-HTTP 0.6** with CORS (`CorsLayer`) and structured request tracing (`TraceLayer`).
- **Serde & Serde JSON** mapping directly to the existing OpenAPI 3.1 specification (`docs/openapi.yaml`).

All operations run isolated on dedicated branch `feat/rust-api-foundation` on port 8001, ensuring zero interference with the running production Flask service on port 8000.

---

## 2. Architecture & File Inventory

The complete Rust implementation lives under `rust/` in a clean, modular structure:

```text
rust/
├── Cargo.toml                     # Crate manifest with axum, tokio, sqlx, sysinfo, tower-http
├── src/
│   ├── lib.rs                     # Library root exporting create_app(pool, system_service)
│   ├── main.rs                    # Executable entry point with signal handling and port binding
│   ├── config.rs                  # Environment configuration (MEDIA_SERVER_DATABASE_URL, PORT)
│   ├── db.rs                      # SQLx connection pool (max 16 connections, 5s timeout, startup ping)
│   ├── error.rs                   # AppError enum with Axum IntoResponse HTTP status mapping
│   ├── models/
│   │   ├── mod.rs
│   │   ├── system.rs              # SystemTelemetryResponse, CpuStats, MemoryStats, StoragePool
│   │   └── movie.rs               # MovieSummaryItem, MovieListResponse, MovieDetailsResponse, TechnicalSpecs
│   ├── routes/
│   │   ├── mod.rs
│   │   ├── health.rs              # /health & /api/health handlers
│   │   ├── system.rs              # /api/system-status handler
│   │   └── movies.rs              # /api/movies & /api/movie/{filename} handlers
│   └── services/
│       ├── mod.rs
│       ├── system_service.rs      # System telemetry service querying CPU, RAM, and D:/E: disks
│       └── movie_service.rs       # Movie catalog service querying PostgreSQL movies & watch progress
└── tests/
    └── api_contracts_test.rs      # End-to-end integration tests verifying HTTP & DB contracts
```

### Supporting Toolchain Wrappers

- [`scripts/cargo.bat`](../scripts/cargo.bat): Automated MSVC and Windows SDK environment wrapper for Cargo. It configures the MSVC host binary search path (resolving the MSYS2 `link.exe` collision) and sets the `LIB` paths for the Windows 10 SDK (`D:\WindowsKits\10\lib\10.0.26100.0\um\x64` and `ucrt\x64`), allowing clean compilation on Windows without requiring manual Developer Command Prompt launches.

---

## 3. Toolchain & Windows Environment Hardening

During initial compilation, two Windows platform-specific traps were encountered and permanently solved:

1. **MSYS2 vs MSVC `link.exe` Collision**:
   The development host has `C:\msys64\usr\bin\link.exe` (GNU hardlink utility) present on the global system `PATH`. When MSVC `rustc` invoked `link.exe`, Windows resolved the GNU tool, resulting in `link: extra operand '/NOLOGO'`.  
   *Resolution*: [`scripts/cargo.bat`](../scripts/cargo.bat) explicitly prepends Visual Studio BuildTools 18 `Hostx64\x64` to `PATH` before invoking `cargo`.

2. **Secondary-Drive Windows 10 SDK Linker Resolution**:
   The host has Visual Studio BuildTools 18 installed at `C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\`, but the Windows 10 SDK resides on the secondary drive at `D:\WindowsKits\10\`. This triggered `LNK1181: cannot open input file 'kernel32.lib'` and `LNK1104: cannot open file 'ucrt.lib'`.  
   *Resolution*: [`scripts/cargo.bat`](../scripts/cargo.bat) automatically injects the MSVC `lib\x64`, Windows Kits `um\x64`, and `ucrt\x64` directories into the `LIB` environment variable.

---

## 4. Endpoints Delivered & Validated

The Phase 4 foundation delivers 4 core endpoints that achieve 100% schema parity with Flask and `docs/openapi.yaml`:

### 1. `GET /health` & `GET /api/health`
- **Purpose**: Health and engine readiness probe.
- **Response**:
  ```json
  {
    "status": "healthy",
    "engine": "rust",
    "version": "0.1.0"
  }
  ```

### 2. `GET /api/system-status`
- **Purpose**: Telemetry data feed consumed by the System HUD on the web client.
- **Features**:
  - Live CPU total usage percentage, logical core count, and processor brand via `sysinfo`.
  - Memory total, used, free, and usage percentage.
  - Dual-Drive Storage Pool aggregation across mass storage `D:` and fast SSD `E:` (`target_mounts: ["D:", "E:"]`), with total pool capacity, pool free space, pool percent used, and per-mount breakdowns.

### 3. `GET /api/movies`
- **Purpose**: Core movie library listing and Continue Watching rail.
- **Parameters**:
  - Query parameter `q`: Optional search filter across title, filename, and genres.
  - Query parameter `sort`: Sorting by `title` (default, alphabetical), `recent` (release date descending), `rating` (vote average descending), or `year` (year descending).
  - Header `x-device-id`: Dynamic join with PostgreSQL `device_watch_history` (falling back to global `progress`), computing playback position, duration, completion percentage, and remaining minutes.
- **Response**:
  ```json
  {
    "movies": [...],
    "watching": [...],
    "total": 852
  }
  ```

### 4. `GET /api/movie/{filename}`
- **Purpose**: Movie details, technical stream specifications, and extended TMDb metadata.
- **Features**:
  - Exact match against PostgreSQL `movies` table by filename.
  - Watch progress resolution for the querying device.
  - Safe title decoding falling back to file stem if `title` is NULL.
  - Technical stream specifications (resolution, container, codec, default subtitles).
  - Proper HTTP 404 response with JSON error message when filename does not exist.

---

## 5. Automated Verification & Test Results

The automated integration suite in [`rust/tests/api_contracts_test.rs`](../rust/tests/api_contracts_test.rs) was executed against the live PostgreSQL 18.4 database (`media_server`):

```text
> .\scripts\cargo.bat test --manifest-path rust\Cargo.toml

   Compiling media-server-api v0.1.0 (E:\MediaServer\rust)
    Finished `test` profile [unoptimized + debuginfo] target(s) in 5.66s
     Running tests\api_contracts_test.rs

running 4 tests
test test_health_endpoints ... ok
test test_system_status_endpoint ... ok
test test_movies_list_endpoint ... ok
test test_movie_details_endpoint ... ok

test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.53s
```

### Static Analysis & Lints
```text
> .\scripts\cargo.bat check --manifest-path rust\Cargo.toml

    Checking media-server-api v0.1.0 (E:\MediaServer\rust)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 3.87s
```
- **Result**: 0 warnings, 0 errors.

---

## 6. Exit Gate Assessment

| Exit Gate Requirement (`FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md` §Phase 4) | Status | Evidence |
|---|---|---|
| Working Rust application with Axum + Tokio | ✅ Passed | [`rust/src/main.rs`](../rust/src/main.rs), [`rust/src/lib.rs`](../rust/src/lib.rs) |
| PostgreSQL connection & pool management | ✅ Passed | [`rust/src/db.rs`](../rust/src/db.rs) with 16-connection pool against PostgreSQL 18.4 |
| Health and system telemetry checks | ✅ Passed | `GET /health`, `GET /api/health`, `GET /api/system-status` |
| Read-only movie library queries | ✅ Passed | `GET /api/movies` (with search, sort, watch progress), `GET /api/movie/{filename}` |
| Contract integration tests matching documented behavior | ✅ Passed | 4/4 passing tests in [`rust/tests/api_contracts_test.rs`](../rust/tests/api_contracts_test.rs) |
| Zero disruption to existing Flask backend | ✅ Passed | Flask continues running on port 8000; Rust binds on port 8001 |

**Phase 4 Exit Gate is fully satisfied.**
