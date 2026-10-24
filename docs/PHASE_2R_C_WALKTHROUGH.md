# Walkthrough: Phase 2R-C — Reverse-Proxy Bridge for Unmigrated Endpoints

**Status:** Completed & Verified  
**Date:** October 15, 2026  
**Governing Document:** [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](file:///e:/MediaServer/docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md) §Phase 2 & §Phase 5  
**Preceding Deliverables:** Phase 2R-A (Dual-Origin Vite Proxy), Phase 2R-B (Rust Static SPA Server), Rust Windows Service (`MediaServerRust`)

---

## 1. Executive Summary

In **Phase 2R-C**, we delivered the **Reverse-Proxy Bridge** in the native Rust Axum backend (`media-server-api`), enabling port `8001` to function as a 100% self-sufficient single origin for the React Single Page Application:

1. **Native Rust Routes Retain Pure Performance:** Video streaming (`/media/*`), dual-GPU chunked HLS (`/hls/*`), live seek hover frame caching (`/seek-preview/*`, `/preview-vtt/*`), subtitles (`/subtitles/*`), and PostgreSQL catalog queries (`/api/movies`, `/api/progress`) execute natively with zero overhead.
2. **Transparent Streaming Proxy for Unmigrated Features:** Endpoints for movie posters (`/tmdb-poster/*`, `/tmdb-backdrop/*`, `/poster/*`), device telemetry & heartbeats (`/api/devices/*`), Google OAuth authentication (`/auth/*`, `/api/auth/*`), LAN DLNA/Chromecast casting (`/api/cast/*`), and storage management (`/api/admin/*`, `/api/storage/*`) are transparently streamed to Waitress WSGI on `127.0.0.1:8000` via `reqwest::Client`.
3. **Cookie & Redirect Preservation:** Preserves `Location` and `Set-Cookie` headers for authentication redirects (`/auth/login`) without following redirects internally.
4. **Zero-Copy Streaming Body Transfers:** Incoming client upload streams and outgoing poster image bytes stream directly between clients and Waitress without in-memory buffering.
5. **Hop-by-Hop Header Sanitization & Upstream 502 Bad Gateway:** Cleans transport headers and provides structured JSON diagnostics if the upstream Flask service is temporarily unreachable.

---

## 2. Deliverables & Code Changes

| Component | File | Description |
| :--- | :--- | :--- |
| **Dependencies** | [`rust/Cargo.toml`](file:///e:/MediaServer/rust/Cargo.toml) | Added `reqwest` with `stream` & `json` features and `futures-util` to production dependencies. |
| **Configuration** | [`rust/src/config.rs`](file:///e:/MediaServer/rust/src/config.rs) | Added `flask_origin: String` to `AppConfig` (reads `FLASK_ORIGIN` / `MEDIA_SERVER_FLASK_ORIGIN`, defaults to `http://127.0.0.1:8000`). |
| **Proxy Service** | [`rust/src/routes/proxy.rs`](file:///e:/MediaServer/rust/src/routes/proxy.rs) | Created `ProxyState` and `proxy_handler`: method preservation, header forwarding, streaming request/response bodies, and 502 error handling. |
| **Module Export** | [`rust/src/routes/mod.rs`](file:///e:/MediaServer/rust/src/routes/mod.rs) | Exported `pub mod proxy;`. |
| **SPA Fallback Guard** | [`rust/src/routes/spa.rs`](file:///e:/MediaServer/rust/src/routes/spa.rs) | Added poster (`/tmdb-poster/`, `/poster/`) and auth (`/auth/`) to API prefix isolation list so unhandled proxy paths never return HTML. |
| **Router Mounting** | [`rust/src/lib.rs`](file:///e:/MediaServer/rust/src/lib.rs) | Implemented `create_app_full` with `proxy_routes` mounted for all unmigrated paths; updated `create_app` and `create_app_with_static`. |
| **Entrypoint Wiring** | [`rust/src/main.rs`](file:///e:/MediaServer/rust/src/main.rs) | Wired `config.flask_origin` into `create_app_full`. |
| **Integration Suite** | [`rust/tests/proxy_bridge_test.rs`](file:///e:/MediaServer/rust/tests/proxy_bridge_test.rs) | 5 automated tests verifying GET proxying, POST header/body forwarding, redirect/cookie preservation, and 502 error handling. |

---

## 3. Automated Test Verification

Executed full cargo test battery via `.\scripts\cargo.bat test --manifest-path rust/Cargo.toml`:

```text
running 5 tests
test test_proxy_forwards_headers_and_body_post ... ok
test test_proxy_forwards_poster_get ... ok
test test_proxy_preserves_redirect_and_cookies ... ok
test test_proxy_forwards_api_devices ... ok
test test_proxy_returns_502_on_unreachable_upstream ... ok

test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 3.68s
```

### Full Rust Regression Suite (All 8 Test Suites Passed):
- `tests/api_contracts_test.rs`: **4 / 4 passed**
- `tests/hls_transcode_test.rs`: **10 / 10 passed**
- `tests/preview_test.rs`: **9 / 9 passed**
- `tests/progress_contracts_test.rs`: **1 / 1 passed**
- `tests/proxy_bridge_test.rs`: **5 / 5 passed**
- `tests/spa_serving_test.rs`: **5 / 5 passed**
- `tests/streaming_range_test.rs`: **11 / 11 passed**
- `tests/subtitles_test.rs`: **12 / 12 passed**
- **TOTAL: 57 / 57 passing Rust tests (100% success rate)**

---

## 4. Next Step: Service Rebuild & End-to-End Validation (Phase 2R-D)

To activate the newly compiled proxy bridge in the running Windows Service:
1. Double-click [`scripts/restart_rust_service.bat`](file:///e:/MediaServer/scripts/restart_rust_service.bat) (or run in elevated PowerShell `Restart-Service MediaServerRust`).
2. Proceed to **Phase 2R-D: End-to-End Live Browser & Mobile Verification** across all features on `http://127.0.0.1:8001`.
