# Implementation Plan: Phase 2R-B — Static SPA Serving & Fallback in Rust Axum

> **Document Type:** Sliced Implementation Plan  
> **Repository:** `anis7t/media-server`  
> **Branch:** `feat/rust-api-foundation`  
> **Governing Documents:** [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](file:///e:/MediaServer/docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md) §Phase 2 & §Phase 5, [`docs/PHASE_2R_REACT_RUST_INTEGRATION_PLAN.md`](file:///e:/MediaServer/docs/PHASE_2R_REACT_RUST_INTEGRATION_PLAN.md)  
> **Target Files:** [`rust/Cargo.toml`](file:///e:/MediaServer/rust/Cargo.toml), [`rust/src/lib.rs`](file:///e:/MediaServer/rust/src/lib.rs), [`rust/src/config.rs`](file:///e:/MediaServer/rust/src/config.rs), [`rust/src/routes/spa.rs`](file:///e:/MediaServer/rust/src/routes/spa.rs), [`rust/tests/spa_serving_test.rs`](file:///e:/MediaServer/rust/tests/spa_serving_test.rs), [`scripts/verify_rust_spa_live.py`](file:///e:/MediaServer/scripts/verify_rust_spa_live.py)  
> **Status:** 📋 **AWAITING USER APPROVAL**

---

## 1. Goal Description

In **Phase 2R-A**, we configured Vite's development proxy to direct local dev traffic on `:5173` to the Rust media and streaming engine on `:8001`. 

However, in production or standalone mode (without running Node.js / Vite), visiting the native Rust engine directly at `http://127.0.0.1:8001/` currently produces a 404 Not Found error because the Rust Axum router only exposes `/api/*`, `/media/*`, `/hls/*`, `/subtitles/*`, `/seek-preview/*`, `/preview-vtt/*`, and `/health`. It does not serve static assets or provide client-side Single Page Application (SPA) fallback routing for the compiled React frontend in `web/dist/`.

**Phase 2R-B** enables the native Rust binary (`media-server-api.exe`) to:
1. Directly serve the compiled production React SPA bundle (`web/dist/`) via `tower-http`'s `ServeDir`.
2. Provide seamless client-side SPA fallback routing: requests to client-side paths (e.g. `/`, `/manage`, `/devices`, `/manual`, `/movie/{filename}`) that do not match a static file on disk are served `index.html` with HTTP 200 OK.
3. Protect API and media routes from HTML fallback: any unmatched request under `/api/`, `/media/`, `/hls/`, `/subtitles/`, `/seek-preview/`, or `/preview-vtt/` returns HTTP 404 with JSON (`{"error": "Not Found"}`), preventing syntax errors on missing backend endpoints.
4. Enforce HTTP caching headers:
   - Hashed static assets (`/assets/*`): `Cache-Control: public, max-age=31536000, immutable` (for instant cached loads).
   - SPA documents (`index.html` / fallback): `Cache-Control: no-cache, must-revalidate` (guaranteeing instant updates upon new frontend deployments).
5. Verify end-to-end via automated Rust integration tests and live headless Chrome Selenium tests driving the running Rust server on `http://127.0.0.1:8001/`.

---

## 2. User Review Required

> [!NOTE]
> **API & Media Isolation Invariant:**  
> A common flaw in static SPA serving is routing all 404s to `index.html`. If an API route 404s and returns HTML, the client fails with `SyntaxError: Unexpected token '<'`. The fallback handler explicitly guards all server-owned prefixes (`/api/`, `/media/`, `/hls/`, `/subtitles/`, `/seek-preview/`, `/preview-vtt/`) so they always return honest 404 JSON, never `index.html`.

> [!IMPORTANT]
> **Process Safety for Live Selenium Testing:**  
> Per `GEMINI.md` invariants, all Selenium scripts must strictly wrap browser lifecycles in `try ... finally: if driver: driver.quit()` and bound polling loops to a maximum of 15–20s to ensure zero orphaned background WebDriver or Chrome processes.

---

## 3. Open Questions

There are no blocking open questions. The compiled bundle in `web/dist/` already exists, builds in 704ms, and passes all 174 React tests.

---

## 4. Proposed Changes

### Component: Rust API & Media Server (`rust/`)

#### [MODIFY] [`rust/Cargo.toml`](file:///e:/MediaServer/rust/Cargo.toml)
- Enable the `"fs"` feature flag on `tower-http = { version = "0.6", features = ["cors", "trace", "fs"] }` to provide `ServeDir` and `ServeFile`.

```diff
--- a/rust/Cargo.toml
+++ b/rust/Cargo.toml
@@ -10,3 +10,3 @@
 tokio-util = { version = "0.7", features = ["io"] }
 tower = { version = "0.5", features = ["util"] }
-tower-http = { version = "0.6", features = ["cors", "trace"] }
+tower-http = { version = "0.6", features = ["cors", "trace", "fs"] }
 sqlx = { version = "0.8", features = ["runtime-tokio", "postgres", "macros", "chrono", "json"] }
```

---

#### [MODIFY] [`rust/src/config.rs`](file:///e:/MediaServer/rust/src/config.rs)
- Add `static_dir: PathBuf` to `AppConfig`, reading from `MEDIA_SERVER_STATIC_DIR` or defaulting to `web/dist` (with automatic fallback to `E:\MediaServer\web\dist` if present).

```diff
--- a/rust/src/config.rs
+++ b/rust/src/config.rs
@@ -11,4 +11,5 @@
     pub media_roots: Vec<PathBuf>,
     pub cache_dir: PathBuf,
+    pub static_dir: PathBuf,
 }
 
@@ -57,4 +58,16 @@
             .unwrap_or_else(|_| PathBuf::from("E:\\MediaServer\\cache"));
 
+        let static_dir = env::var("MEDIA_SERVER_STATIC_DIR")
+            .map(PathBuf::from)
+            .unwrap_or_else(|_| {
+                let rel_dist = PathBuf::from("web/dist");
+                if rel_dist.exists() {
+                    rel_dist
+                } else {
+                    PathBuf::from("E:\\MediaServer\\web\\dist")
+                }
+            });
+
         Self {
             database_url,
             host,
             port,
             media_root,
             media_roots,
             cache_dir,
+            static_dir,
         }
```

---

#### [NEW] [`rust/src/routes/spa.rs`](file:///e:/MediaServer/rust/src/routes/spa.rs)
- Implements `spa_fallback_handler` with:
  1. Prefix guard: returns HTTP 404 JSON for missing `/api/*`, `/media/*`, `/hls/*`, `/subtitles/*`, `/seek-preview/*`, `/preview-vtt/*`.
  2. Static file serving via `ServeDir<ServeFile>`: serves matching assets or falls back to `index.html`.
  3. Caching headers:
     - `/assets/*` -> `Cache-Control: public, max-age=31536000, immutable`
     - `index.html` and client routes -> `Cache-Control: no-cache, must-revalidate`

```rust
use axum::{
    body::Body,
    extract::Request,
    http::{header, HeaderValue, StatusCode, Uri},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;
use std::path::PathBuf;
use tower::ServiceExt;
use tower_http::services::{ServeDir, ServeFile};

#[derive(Clone, Debug)]
pub struct SpaFallbackService {
    serve_dir: ServeDir<ServeFile>,
}

impl SpaFallbackService {
    pub fn new(dist_path: &PathBuf) -> Self {
        let index_file = dist_path.join("index.html");
        let serve_dir = ServeDir::new(dist_path).fallback(ServeFile::new(index_file));
        Self { serve_dir }
    }

    pub async fn handle(&self, uri: Uri, req: Request) -> Response {
        let path = uri.path();

        // 1. Never serve HTML for API or media routes that were not matched.
        if path.starts_with("/api/")
            || path.starts_with("/media/")
            || path.starts_with("/hls/")
            || path.starts_with("/subtitles/")
            || path.starts_with("/seek-preview/")
            || path.starts_with("/preview-vtt/")
        {
            return (
                StatusCode::NOT_FOUND,
                Json(json!({
                    "error": "Not Found",
                    "path": path,
                })),
            )
                .into_response();
        }

        // 2. Delegate to ServeDir with index.html fallback
        let mut res = match self.serve_dir.clone().oneshot(req).await {
            Ok(r) => r.into_response(),
            Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, "Static file error").into_response(),
        };

        // 3. Set Cache-Control based on content type and asset path
        if path.starts_with("/assets/") {
            res.headers_mut().insert(
                header::CACHE_CONTROL,
                HeaderValue::from_static("public, max-age=31536000, immutable"),
            );
        } else {
            res.headers_mut().insert(
                header::CACHE_CONTROL,
                HeaderValue::from_static("no-cache, must-revalidate"),
            );
        }

        res
    }
}
```

---

#### [MODIFY] [`rust/src/routes/mod.rs`](file:///e:/MediaServer/rust/src/routes/mod.rs)
- Register `pub mod spa;`.

---

#### [MODIFY] [`rust/src/lib.rs`](file:///e:/MediaServer/rust/src/lib.rs)
- Update `create_app` signature to maintain 100% backward compatibility:
  ```rust
  pub fn create_app(
      pool: PgPool,
      system_service: SystemService,
      media_roots: Vec<PathBuf>,
      cache_dir: PathBuf,
  ) -> Router {
      create_app_with_static(pool, system_service, media_roots, cache_dir, None)
  }
  ```
- Implement `create_app_with_static(pool, system_service, media_roots, cache_dir, static_dir: Option<PathBuf>)`:
  - Auto-resolves static directory (from parameter or `AppConfig::static_dir`).
  - If `index.html` exists in `static_dir`, attaches `spa_fallback.handle(...)` as `.fallback(...)`.
  - If no `index.html` exists, falls back to honest 404 JSON handler.

---

#### [NEW] [`rust/tests/spa_serving_test.rs`](file:///e:/MediaServer/rust/tests/spa_serving_test.rs)
- Integration tests:
  1. `test_serves_spa_index_at_root`: `GET /` returns 200 OK with `text/html` and `Cache-Control: no-cache`.
  2. `test_client_side_routing_fallback`: `GET /manage`, `GET /devices`, `GET /manual` return 200 OK with `index.html`.
  3. `test_static_assets_have_immutable_cache`: `GET /assets/...` returns 200 OK with `Cache-Control: public, max-age=31536000, immutable`.
  4. `test_api_endpoints_retain_precedence`: `GET /api/health` returns `{"status":"ok"}` (JSON, not HTML).
  5. `test_unmatched_api_and_media_return_404_json`: `GET /api/missing` returns 404 JSON, NOT `index.html`.
  6. `test_unmatched_media_returns_404`: `GET /media/missing.mp4` returns 404 (not `index.html`).

---

### Component: Live Browser Verification (`scripts/`)

#### [NEW] [`scripts/verify_rust_spa_live.py`](file:///e:/MediaServer/scripts/verify_rust_spa_live.py)
- Autonomous Selenium script using `e:\MediaServer\venv\Scripts\python.exe`:
  1. Spawns `media-server-api.exe` as a subprocess on port 8001.
  2. Bounded poll (max 10s) on `http://127.0.0.1:8001/api/health`.
  3. Launches headless Chrome with options (`--headless=new`, `--window-size=1440,900`, `--mute-audio`).
  4. Navigates to `http://127.0.0.1:8001/`:
     - Asserts DOM contains `#root`.
     - Asserts React mounts the application header.
     - Captures screenshot `_shots/phase_2r_b_spa_home.png`.
  5. Navigates directly to client-side route `http://127.0.0.1:8001/manage`:
     - Asserts SPA client routing succeeds without server 404.
     - Captures screenshot `_shots/phase_2r_b_spa_manage.png`.
  6. Navigates directly to `http://127.0.0.1:8001/manual`:
     - Asserts user manual renders.
     - Captures screenshot `_shots/phase_2r_b_spa_manual.png`.
  7. Checks browser console logs for any syntax or script loading errors.
  8. Enforces strict process cleanup in `finally:` block (`driver.quit()` and `server.terminate()`).

---

## 5. Verification Plan

### Automated Tests
1. **Rust Integration Test Suite**:
   ```powershell
   .\scripts\cargo.bat test --test spa_serving_test --manifest-path rust\Cargo.toml
   ```
   *Expected Outcome:* All SPA serving test cases pass with 0 errors.

2. **Full Rust Regression Battery**:
   ```powershell
   .\scripts\cargo.bat test --manifest-path rust\Cargo.toml
   ```
   *Expected Outcome:* All 47+ existing tests continue passing without regression.

3. **Live Headless Chrome Selenium Verification**:
   ```powershell
   & e:\MediaServer\venv\Scripts\python.exe scripts\verify_rust_spa_live.py
   ```
   *Expected Outcome:* Headless Chrome loads `http://127.0.0.1:8001/`, navigates SPA routes, captures evidence screenshots in `_shots/`, and cleanly terminates all processes.

### Manual Verification
- Review generated screenshots:
  - `_shots/phase_2r_b_spa_home.png`
  - `_shots/phase_2r_b_spa_manage.png`
  - `_shots/phase_2r_b_spa_manual.png`
