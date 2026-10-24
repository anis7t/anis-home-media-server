# Implementation Plan: Phase 5A — Playback Watch Progress & History API (`/api/progress`)

> **Document Type:** Migration Sub-Phase Implementation Plan  
> **Repository:** `anis7t/media-server`  
> **Branch:** `feat/rust-api-foundation`  
> **Parent Roadmap:** [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md) §Phase 5  
> **Parent Sliced Plan:** [`docs/PHASE_5_RUST_STREAMING_PLAN.md`](PHASE_5_RUST_STREAMING_PLAN.md)  
> **Depends On:** Phase 4 Rust API Foundation ([`docs/PHASE_4_RUST_API_WALKTHROUGH.md`](PHASE_4_RUST_API_WALKTHROUGH.md))  
> **Status:** 📋 **AWAITING USER APPROVAL**

---

## 1. Goal Description & Scope

Phase 5A delivers the playback watch progress and device watch history API in the Rust Axum backend. It handles:
- Querying watch progress for a movie (`GET /api/progress?filename={filename}`) with multi-device isolation.
- Persisting watch progress (`POST /api/progress`) with position clamping and completion calculation against PostgreSQL 18.4 (`media_server`).
- Preserving 100% compatibility with the existing React web frontend, Flutter/Fire TV application, and OpenAPI 3.1 contracts (`docs/openapi.yaml`).

---

## 2. User Review Required & Architectural Invariants

> [!IMPORTANT]
> **Database Table Coexistence**:
> Like Flask, Rust concurrently maintains both the global `progress` table (`filename, position, duration, updated_at`) and the per-device `device_watch_history` table (`device_id, filename, position, duration, completed, last_watched`). This ensures that legacy clients without device IDs continue to receive global progress while modern clients retain private per-device progress.

> [!NOTE]
> **Zero Downtime / Production Isolation**:
> Flask continues serving production on port 8000; the Rust API runs on port 8001 during candidate validation. Both backends share the same PostgreSQL 18.4 database (`media_server`), guaranteeing live state synchronization.

---

## 3. Proposed Changes

Grouped by component layer:

### 1. Data Models (`rust/src/models/`)

#### [NEW] `rust/src/models/progress.rs`
Define strong types for query requests, updates, and JSON responses:
```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct ProgressResponse {
    pub position: f64,
    pub duration: f64,
}

#[derive(Debug, Deserialize)]
pub struct UpdateProgressRequest {
    pub filename: String,
    pub position: f64,
    pub duration: f64,
    pub device_id: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SuccessResponse {
    pub success: bool,
}
```

#### [MODIFY] `rust/src/models/mod.rs`
Export the `progress` module:
```rust
pub mod movie;
pub mod progress;
pub mod system;
```

---

### 2. Service Layer (`rust/src/services/`)

#### [NEW] `rust/src/services/progress_service.rs`
Implements PostgreSQL database queries using SQLx connection pooling:

```rust
use crate::error::AppError;
use crate::models::progress::{ProgressResponse, UpdateProgressRequest};
use sqlx::{PgPool, Row};

pub struct ProgressService;

impl ProgressService {
    /// Retrieve playback watch progress for a given filename and optional device ID.
    pub async fn get_progress(
        pool: &PgPool,
        filename: &str,
        device_id: Option<&str>,
    ) -> Result<ProgressResponse, AppError> {
        if filename.trim().is_empty() {
            return Err(AppError::BadRequest("Filename is required".to_string()));
        }

        // 1. Try querying device_watch_history if device_id is present
        if let Some(dev) = device_id.filter(|d| !d.trim().is_empty()) {
            let row = sqlx::query(
                r#"
                SELECT position, duration
                FROM device_watch_history
                WHERE device_id = $1 AND filename = $2
                "#,
            )
            .bind(dev)
            .bind(filename)
            .fetch_optional(pool)
            .await?;

            if let Some(r) = row {
                let position: f64 = r.try_get("position").unwrap_or(0.0);
                let duration: f64 = r.try_get("duration").unwrap_or(0.0);
                return Ok(ProgressResponse { position, duration });
            }
        }

        // 2. Fallback to global progress table
        let row = sqlx::query(
            r#"
            SELECT position, duration
            FROM progress
            WHERE filename = $1
            "#,
        )
        .bind(filename)
        .fetch_optional(pool)
        .await?;

        if let Some(r) = row {
            let position: f64 = r.try_get("position").unwrap_or(0.0);
            let duration: f64 = r.try_get("duration").unwrap_or(0.0);
            return Ok(ProgressResponse { position, duration });
        }

        // 3. Default to 0.0 if not found
        Ok(ProgressResponse {
            position: 0.0,
            duration: 0.0,
        })
    }

    /// Persist watch progress to both `progress` and `device_watch_history`.
    pub async fn update_progress(
        pool: &PgPool,
        req: UpdateProgressRequest,
        header_device_id: Option<&str>,
    ) -> Result<(), AppError> {
        let filename = req.filename.trim();
        if filename.is_empty() {
            return Err(AppError::BadRequest("Filename is required".to_string()));
        }

        let dur = req.duration.max(0.0);
        let mut pos = req.position.max(0.0);
        if dur > 0.0 {
            pos = pos.min(dur);
        }

        // Upsert into global progress table
        sqlx::query(
            r#"
            INSERT INTO progress (filename, position, duration, updated_at)
            VALUES ($1, $2, $3, CURRENT_TIMESTAMP)
            ON CONFLICT (filename) DO UPDATE SET
                position = EXCLUDED.position,
                duration = EXCLUDED.duration,
                updated_at = CURRENT_TIMESTAMP
            "#,
        )
        .bind(filename)
        .bind(pos)
        .bind(dur)
        .execute(pool)
        .await?;

        // Determine effective device ID (payload device_id takes precedence over header)
        let effective_device_id = req
            .device_id
            .as_deref()
            .or(header_device_id)
            .filter(|d| !d.trim().is_empty());

        if let Some(dev) = effective_device_id {
            let completed = if dur > 0.0 && (pos >= dur * 0.9 || (dur - pos) <= 15.0) {
                1
            } else {
                0
            };

            sqlx::query(
                r#"
                INSERT INTO device_watch_history (
                    device_id, filename, position, duration, completed, last_watched
                ) VALUES ($1, $2, $3, $4, $5, CURRENT_TIMESTAMP)
                ON CONFLICT (device_id, filename) DO UPDATE SET
                    position = EXCLUDED.position,
                    duration = EXCLUDED.duration,
                    completed = EXCLUDED.completed,
                    last_watched = CURRENT_TIMESTAMP
                "#,
            )
            .bind(dev)
            .bind(filename)
            .bind(pos)
            .bind(dur)
            .bind(completed)
            .execute(pool)
            .await?;
        }

        Ok(())
    }
}
```

#### [MODIFY] `rust/src/services/mod.rs`
Export `progress_service`:
```rust
pub mod movie_service;
pub mod progress_service;
pub mod system_service;
```

---

### 3. Route Handlers (`rust/src/routes/`)

#### [NEW] `rust/src/routes/progress.rs`
Extracts device hints, validates parameters, and delegates to `ProgressService`:

```rust
use crate::error::AppError;
use crate::models::progress::{ProgressResponse, SuccessResponse, UpdateProgressRequest};
use crate::services::progress_service::ProgressService;
use axum::{
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use sqlx::PgPool;

#[derive(Debug, Deserialize)]
pub struct ProgressQuery {
    pub filename: Option<String>,
}

fn extract_device_id(headers: &HeaderMap) -> Option<&str> {
    headers
        .get("x-device-id")
        .and_then(|v| v.to_str().ok())
        .or_else(|| {
            headers
                .get("cookie")
                .and_then(|v| v.to_str().ok())
                .and_then(|c| {
                    c.split(';')
                        .map(|s| s.trim())
                        .find(|s| s.starts_with("ms_device_id="))
                        .map(|s| &s["ms_device_id=".len()..])
                })
        })
}

pub async fn get_progress_handler(
    State(pool): State<PgPool>,
    headers: HeaderMap,
    Query(query): Query<ProgressQuery>,
) -> Result<impl IntoResponse, AppError> {
    let filename = query
        .filename
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| AppError::BadRequest("Filename query parameter is required".to_string()))?;

    let device_id = extract_device_id(&headers);
    let progress = ProgressService::get_progress(&pool, &filename, device_id).await?;

    Ok(Json(progress))
}

pub async fn post_progress_handler(
    State(pool): State<PgPool>,
    headers: HeaderMap,
    Json(payload): Json<UpdateProgressRequest>,
) -> Result<impl IntoResponse, AppError> {
    let device_id = extract_device_id(&headers);
    ProgressService::update_progress(&pool, payload, device_id).await?;

    Ok((StatusCode::OK, Json(SuccessResponse { success: true })))
}
```

#### [MODIFY] `rust/src/routes/mod.rs`
Export `progress`:
```rust
pub mod health;
pub mod movies;
pub mod progress;
pub mod system;
```

#### [MODIFY] `rust/src/lib.rs`
Mount `/api/progress` into the Axum router:
```rust
    let progress_routes = Router::new()
        .route(
            "/api/progress",
            get(routes::progress::get_progress_handler).post(routes::progress::post_progress_handler),
        )
        .with_state(pool.clone());
```

---

## 4. Verification Plan

### Automated Tests (`rust/tests/progress_contracts_test.rs`)
Implement integration tests in `rust/tests/progress_contracts_test.rs` executing against PostgreSQL 18.4 (`media_server`):

1. **Initial GET returns zeros**:
   - `GET /api/progress?filename=Unique_Movie_Test_1.mp4`
   - Assert `200 OK`, `position == 0.0`, `duration == 0.0`.
2. **POST progress updates database**:
   - `POST /api/progress` with `position: 45.5, duration: 3600.0` and `X-Device-Id: dev_rust_phone`.
   - Assert `200 OK`, `{"success": true}`.
3. **Subsequent GET returns stored value**:
   - `GET /api/progress?filename=Unique_Movie_Test_1.mp4` with `X-Device-Id: dev_rust_phone`.
   - Assert `position == 45.5, duration == 3600.0`.
4. **Multi-device isolation**:
   - `GET /api/progress?filename=Unique_Movie_Test_1.mp4` with `X-Device-Id: dev_other_device`.
   - Assert `position == 0.0` (device-isolated row).
5. **Position clamping logic**:
   - `POST /api/progress` with `position: 5000.0, duration: 3600.0`.
   - `GET /api/progress` -> assert `position == 3600.0` (clamped to duration).
6. **Completed calculation logic**:
   - `POST /api/progress` with `position: 3300.0, duration: 3600.0` (>90%).
   - Direct query to PostgreSQL `device_watch_history` asserts `completed == 1`.
7. **Error handling**:
   - Missing `filename` on GET -> assert `400 Bad Request`.
   - Empty body on POST -> assert `400 Bad Request`.

### Test Execution Command
```powershell
.\scripts\cargo.bat test --test progress_contracts_test
```
And verify 0 linter warnings:
```powershell
.\scripts\cargo.bat check --manifest-path rust\Cargo.toml
```
