# Phase 2R-B Walkthrough: Static SPA Serving & Fallback in Rust Axum

> **Document Type:** Sliced Migration Walkthrough  
> **Repository:** `anis7t/media-server`  
> **Branch:** `feat/rust-api-foundation`  
> **Governing Document:** [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](file:///e:/MediaServer/docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md) §Phase 2 & §Phase 5  
> **Status:** ✅ **DELIVERED, VERIFIED & PASSING (52/52 RUST TESTS + LIVE BROWSER TESTS PASSING)**

---

## 1. Executive Summary

Phase 2R-B enables the native Rust binary (`media-server-api.exe`) to directly serve the compiled React SPA from `web/dist/` on port 8001 without requiring Node.js or Vite.

Key capabilities delivered:
1. **Production SPA Serving (`tower-http` `ServeDir`)**: Root `/` directly serves `index.html` with HTTP 200 OK and `text/html`.
2. **Client-Side SPA Routing Fallback**: Non-file paths (`/manage`, `/devices`, `/manual`, `/movie/{filename}`) transparently serve `index.html` with HTTP 200 OK, enabling React Router 7 to mount routes on initial page load or direct link entry.
3. **API & Media Isolation Guard**: Unmatched requests under `/api/`, `/media/`, `/hls/`, `/subtitles/`, `/seek-preview/`, and `/preview-vtt/` return honest HTTP 404 JSON (`{"error": "Not Found"}`), preventing syntax errors and decoding crashes on missing backend routes.
4. **Optimized Cache-Control Headers**:
   - Cryptographically hashed chunks (`/assets/*`): `Cache-Control: public, max-age=31536000, immutable`.
   - SPA documents (`index.html` and client routes): `Cache-Control: no-cache, must-revalidate`.
5. **Live Autonomous Headless Chrome Verification**: Drove the running Rust binary using Selenium 4.50, verified DOM hydration, asserted brand header rendering, navigated client routes directly, and captured photographic proof in `_shots/`.

---

## 2. Changes Made

### Rust Backend (`rust/`)

1. **[`rust/Cargo.toml`](file:///e:/MediaServer/rust/Cargo.toml)**:
   - Enabled `"fs"` feature flag on `tower-http` (`features = ["cors", "trace", "fs"]`), bringing in `ServeDir` and `ServeFile`.

2. **[`rust/src/config.rs`](file:///e:/MediaServer/rust/src/config.rs)**:
   - Added `static_dir: PathBuf` to `AppConfig`, dynamically resolving `MEDIA_SERVER_STATIC_DIR` or defaulting to `web/dist` (with automatic fallback to `E:\MediaServer\web\dist`).

3. **[`rust/src/routes/spa.rs`](file:///e:/MediaServer/rust/src/routes/spa.rs)**:
   - Created `SpaFallbackService` implementing prefix isolation guards, `ServeDir` delegation, and caching header policies.

4. **[`rust/src/routes/mod.rs`](file:///e:/MediaServer/rust/src/routes/mod.rs)**:
   - Registered `pub mod spa;`.

5. **[`rust/src/lib.rs`](file:///e:/MediaServer/rust/src/lib.rs)**:
   - Exported `create_app_with_static(pool, system_service, media_roots, cache_dir, static_dir)` while maintaining 100% backward compatibility for existing `create_app(...)` callers.
   - Attached `spa_service.handle(...)` as Axum router fallback when `static_dir` contains `index.html`.

6. **[`rust/src/main.rs`](file:///e:/MediaServer/rust/src/main.rs)**:
   - Updated executable entrypoint to invoke `create_app_with_static(..., Some(config.static_dir))`.

7. **[`rust/tests/spa_serving_test.rs`](file:///e:/MediaServer/rust/tests/spa_serving_test.rs)**:
   - Added 5 automated integration tests validating root index serving, client routing fallbacks, immutable asset caching, API route precedence, and 404 JSON protection.

---

## 3. Automated Test Outcomes

### 1. Dedicated SPA Serving Test Suite
```powershell
.\scripts\cargo.bat test --test spa_serving_test --manifest-path rust\Cargo.toml
```
```text
running 5 tests
test test_api_endpoints_retain_precedence_over_spa ... ok
test test_serves_spa_index_at_root ... ok
test test_missing_api_and_media_routes_return_404_json_not_html ... ok
test test_static_asset_serving_with_immutable_cache ... ok
test test_client_side_routing_fallback ... ok

test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.35s
```

### 2. Full Rust Regression Battery
```powershell
.\scripts\cargo.bat test --manifest-path rust\Cargo.toml
```
- **Result:** **52 / 52 tests passed across 7 test suites** (0 failures).

---

## 4. Live Selenium Browser Verification

Script: [`scripts/verify_rust_spa_live.py`](file:///e:/MediaServer/scripts/verify_rust_spa_live.py)

Executed against `media-server-api.exe` running on `http://127.0.0.1:8001`:
1. **Health Verification**: Polled `/api/health` — responded with `{"status":"healthy","engine":"rust"}` in <0.3s.
2. **Root Route (`/`)**: Loaded React SPA, verified `#root` hydration, brand header ("Anis' Home Media Server"), and movie catalog (50 titles loaded from PostgreSQL).
3. **Client Route (`/manage`)**: Direct navigation returned 200 OK with `index.html` and rendered Administrator Access gate.
4. **Client Route (`/manual`)**: Direct navigation returned 200 OK with `index.html` and rendered the full Controls, Streaming & Architecture Guide.
5. **Console Inspection**: 0 syntax errors, 0 asset decode errors.
6. **Process Safety**: Both Chrome WebDriver and the Rust child process were cleanly terminated upon completion.

### Visual Evidence Captured

| Route | Captured Screenshot | Description |
|---|---|---|
| `GET /` | `_shots/phase_2r_b_spa_home.png` | Home library with Featured Spotlight (*2001: A Space Odyssey*) and catalog grid |
| `GET /manage` | `_shots/phase_2r_b_spa_manage.png` | Administrator Access Required security gate |
| `GET /manual` | `_shots/phase_2r_b_spa_manual.png` | Controls, Streaming & Architecture Guide |

---

## 5. Next Step: Phase 2R-C (Unmigrated Flask Proxy Bridge in Rust)

With the static SPA serving cleanly from Rust on `:8001`, the remaining step before full standalone migration is **Phase 2R-C**:
- Implement a reverse-proxy bridge in Rust Axum (`reqwest::Client`) that transparently forwards requests for unmigrated services (`/auth/*`, `/api/auth/*`, `/api/cast/*`, `/api/devices/*`, `/tmdb-poster/*`, `/poster/*`, `/api/admin/*`, `/api/storage/*`) to Flask on `http://127.0.0.1:8000`.
- This will allow the browser on `http://127.0.0.1:8001` to display TMDb poster artwork and Google OAuth sign-in seamlessly.
