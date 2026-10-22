# Implementation Plan: Phase 2R-A — Dual-Origin Vite Proxy & Dev Environment Wiring

> **Document Type:** Sliced Implementation Plan  
> **Repository:** `anis7t/media-server`  
> **Branch:** `feat/rust-api-foundation`  
> **Governing Documents:** [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](file:///e:/MediaServer/docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md) §Phase 2 & §Phase 5, [`docs/PHASE_2R_REACT_RUST_INTEGRATION_PLAN.md`](file:///e:/MediaServer/docs/PHASE_2R_REACT_RUST_INTEGRATION_PLAN.md)  
> **Target Files:** [`web/vite.config.ts`](file:///e:/MediaServer/web/vite.config.ts), [`web/src/test/proxy-coverage.test.ts`](file:///e:/MediaServer/web/src/test/proxy-coverage.test.ts)  
> **Status:** 📋 **AWAITING USER APPROVAL**

---

## 1. Goal Description

During local frontend development (`npm run dev`), the React Single Page Application (SPA) runs via Vite on `http://localhost:5173`. Previously, Vite's dev proxy was configured to direct all backend requests (`/api`, `/media`, `/hls`, `/poster`, etc.) exclusively to the legacy Python Flask/Waitress backend on `http://127.0.0.1:8000`.

With the completion of **Phase 5 (Native Rust Media & Transcoding Engine)**, the high-throughput native Rust engine on `http://127.0.0.1:8001` now owns:
1. Movie catalog and metadata (`/api/movies`, `/api/movie/{filename}`)
2. Watch progress persistence (`/api/progress` GET & POST)
3. Live system telemetry & HUD (`/api/system-status`)
4. Seek hover preview thumbnails and WebVTT manifests (`/seek-preview/*`, `/preview-vtt/*`, `/api/seek-preview-meta/*`)
5. Subtitle catalog, WebVTT streaming with cue offset adjustments, and multipart uploads (`/subtitles/*`, `/api/subtitles/*`, `/api/upload-subtitle/*`)
6. RFC 7233 byte-range direct media streaming (`/media/*`)
7. Dynamic multi-GPU HLS manifest and segment delivery (`/hls/*`)
8. Transcode job status polling (`/api/transcode-status/*`, `/api/transcodes`)

However, several subsystems remain on Flask/Waitress (`127.0.0.1:8000`):
- Google OAuth 2.0 authentication (`/auth/*`, `/api/auth/*`)
- LAN Google Cast & DLNA receiver discovery and remote playback control (`/api/cast/*`)
- Connected device fleet telemetry & client hints (`/api/devices/*`)
- Storage management, retention policies, and cache auditing (`/api/storage/*`, `/api/admin/*`)
- TMDb and local artwork caching (`/tmdb-poster/*`, `/tmdb-backdrop/*`, `/poster/*`)
- Library filesystem scanner trigger (`/api/scan`)
- Container/stream probe fallback (`/api/media-info/*`)

**Phase 2R-A** establishes a dual-origin dev proxy in `web/vite.config.ts` that partitions incoming dev traffic deterministically:
- All migrated media, streaming, transcode, and catalog routes are forwarded directly to the Rust engine on `http://127.0.0.1:8001` (overridable via `RUST_API_ORIGIN`).
- All unmigrated administrative, authentication, cast, and artwork routes are forwarded to Flask on `http://127.0.0.1:8000` (overridable via `MEDIA_SERVER_ORIGIN`).
- The dev proxy test suite [`web/src/test/proxy-coverage.test.ts`](file:///e:/MediaServer/web/src/test/proxy-coverage.test.ts) is upgraded to assert dual-origin routing coverage and valid origin targeting across all 172+ test invariants.

---

## 2. User Review Required

> [!NOTE]
> **Strict Same-Origin Dev Proxy (Gate F Invariant):**  
> Neither the Rust backend nor the Flask backend will have their production CORS scopes widened. Development requests maintain same-origin semantics via Vite's proxy middleware, ensuring identical behavior between development and production.

> [!IMPORTANT]
> **Deterministic Insertion-Order Precedence in Vite:**  
> Vite / Connect middleware resolves proxy rules in iteration order (`for (const context in proxies)`). Specific `/api/*` prefixes directed to the Rust engine (`/api/movies`, `/api/movie`, `/api/progress`, etc.) must be declared **before** the general `'/api'` fallback rule for Flask. This ensures that only unhandled `/api` paths fall through to Flask.

---

## 3. Open Questions

There are no blocking open questions. The routing partitioning maps 1:1 to the delivered Rust Axum routes in [`rust/src/lib.rs`](file:///e:/MediaServer/rust/src/lib.rs) and the existing Flask routes.

---

## 4. Proposed Changes

### Component: Frontend Development Environment (`web/`)

#### [MODIFY] [`web/vite.config.ts`](file:///e:/MediaServer/web/vite.config.ts)
- Introduce `RUST_ORIGIN` defaulting to `process.env.RUST_API_ORIGIN ?? 'http://127.0.0.1:8001'`.
- Retain `FLASK_ORIGIN` defaulting to `process.env.MEDIA_SERVER_ORIGIN ?? 'http://127.0.0.1:8000'`.
- Reorder and expand `server.proxy` entries:
  - Rust-directed:
    - `/api/movies`
    - `/api/movie`
    - `/api/progress`
    - `/api/system-status`
    - `/api/seek-preview-meta`
    - `/api/subtitles`
    - `/api/upload-subtitle`
    - `/api/transcode-status`
    - `/api/transcodes`
    - `/api/health`
    - `/media`
    - `/hls`
    - `/seek-preview`
    - `/preview-vtt`
    - `/subtitles`
  - Flask-directed (fallback & unmigrated):
    - `/api` (fallback catch-all for `/api/auth`, `/api/cast`, `/api/devices`, `/api/storage`, `/api/admin`, `/api/scan`, `/api/media-info`)
    - `/tmdb-poster`
    - `/tmdb-backdrop`
    - `/poster`
    - `/auth`

```diff
--- a/web/vite.config.ts
+++ b/web/vite.config.ts
@@ -6,7 +6,13 @@
-/**
- * Flask origin. Defaults to the deployed service on loopback.
- * Override with MEDIA_SERVER_ORIGIN to point the dev server elsewhere.
- */
+/**
+ * Rust native API & media streaming engine origin. Defaults to loopback:8001.
+ * Override with RUST_API_ORIGIN to point the dev server elsewhere.
+ */
+const RUST_ORIGIN = process.env.RUST_API_ORIGIN ?? 'http://127.0.0.1:8001';
+
+/**
+ * Flask origin for unmigrated services (OAuth, Cast, Devices, Storage, TMDb artwork proxy).
+ * Defaults to the deployed service on loopback:8000.
+ * Override with MEDIA_SERVER_ORIGIN to point the dev server elsewhere.
+ */
 const FLASK_ORIGIN = process.env.MEDIA_SERVER_ORIGIN ?? 'http://127.0.0.1:8000';
@@ -16,22 +22,38 @@
     port: 5173,
     /**
-     * Gate F: the dev server proxies the server-owned prefixes so the browser
+     * Gate F & Phase 2R: the dev server proxies server-owned prefixes so the browser
      * sees a single same-origin application.
      *
-     * This is why no CORS change is needed for `/api/*`. The server's
-     * `CORS_PATHS` in `app/routes/media.py` stays exactly `('/media/', '/hls/')`,
-     * which is the deliberate scoping documented in AGENTS.md for Cast
-     * receivers. Widening it to cover `/api/*` would have been the wrong fix:
-     * it would have changed production behaviour to suit a dev convenience.
+     * Dual-Origin Partitioning:
+     * - Migrated high-throughput endpoints (movies, streaming, HLS, live previews,
+     *   subtitles, progress, transcode status, and system telemetry) route directly
+     *   to the native Rust engine on :8001.
+     * - Unmigrated endpoints (OAuth authentication, Google Cast / DLNA, device fleet
+     *   management, admin storage policies, library scanner trigger, and TMDb artwork
+     *   caching) fall through to the Python Flask backend on :8000.
      *
-     * The list below was enumerated from the app's own `url_map` rather than
-     * written from memory. An earlier version listed only `/api`, `/media` and
-     * `/hls`, which left `/tmdb-poster/*` and `/poster/*` to Vite's SPA
-     * fallback: those requests returned HTTP 200 with `text/html`, every poster
-     * failed to decode, and the library rendered a wall of placeholders. A 200
-     * with the wrong content type is exactly the failure a status-code check
-     * cannot see, and mocked unit tests cannot see either - they never load an
-     * image.
+     * Vite evaluates proxy keys in insertion order. Specific `/api/*` prefixes directed
+     * to Rust MUST precede the catch-all `'/api'` fallback rule for Flask.
      *
      * Only these prefixes are proxied. Everything else is Vite, and the HMR
      * websocket is untouched.
      */
     proxy: {
-      // REST API.
-      '/api': { target: FLASK_ORIGIN, changeOrigin: true },
-      // Byte-range direct play.
-      '/media': { target: FLASK_ORIGIN, changeOrigin: true },
-      // HLS playlists and segments.
-      '/hls': { target: FLASK_ORIGIN, changeOrigin: true },
-      // Artwork. Missing these is invisible until the grid renders empty.
-      '/tmdb-poster': { target: FLASK_ORIGIN, changeOrigin: true },
-      '/tmdb-backdrop': { target: FLASK_ORIGIN, changeOrigin: true },
-      '/poster': { target: FLASK_ORIGIN, changeOrigin: true },
-      // Seek-preview thumbnails and subtitles, used by later slices.
-      '/seek-preview': { target: FLASK_ORIGIN, changeOrigin: true },
-      '/subtitles': { target: FLASK_ORIGIN, changeOrigin: true },
-      // Sign-in. Without this the browser hits Vite's SPA fallback for
-      // /auth/google and gets index.html instead of the redirect to Google, so
-      // sign-in silently does nothing in development.
-      '/auth': { target: FLASK_ORIGIN, changeOrigin: true },
+      // --- Rust Engine Migrated Endpoints (:8001) ---
+      '/api/movies': { target: RUST_ORIGIN, changeOrigin: true },
+      '/api/movie': { target: RUST_ORIGIN, changeOrigin: true },
+      '/api/progress': { target: RUST_ORIGIN, changeOrigin: true },
+      '/api/system-status': { target: RUST_ORIGIN, changeOrigin: true },
+      '/api/seek-preview-meta': { target: RUST_ORIGIN, changeOrigin: true },
+      '/api/subtitles': { target: RUST_ORIGIN, changeOrigin: true },
+      '/api/upload-subtitle': { target: RUST_ORIGIN, changeOrigin: true },
+      '/api/transcode-status': { target: RUST_ORIGIN, changeOrigin: true },
+      '/api/transcodes': { target: RUST_ORIGIN, changeOrigin: true },
+      '/api/health': { target: RUST_ORIGIN, changeOrigin: true },
+      '/media': { target: RUST_ORIGIN, changeOrigin: true },
+      '/hls': { target: RUST_ORIGIN, changeOrigin: true },
+      '/seek-preview': { target: RUST_ORIGIN, changeOrigin: true },
+      '/preview-vtt': { target: RUST_ORIGIN, changeOrigin: true },
+      '/subtitles': { target: RUST_ORIGIN, changeOrigin: true },
+
+      // --- Flask Backend Unmigrated Endpoints (:8000) ---
+      '/api': { target: FLASK_ORIGIN, changeOrigin: true },
+      '/tmdb-poster': { target: FLASK_ORIGIN, changeOrigin: true },
+      '/tmdb-backdrop': { target: FLASK_ORIGIN, changeOrigin: true },
+      '/poster': { target: FLASK_ORIGIN, changeOrigin: true },
+      '/auth': { target: FLASK_ORIGIN, changeOrigin: true },
     },
```

---

#### [MODIFY] [`web/src/test/proxy-coverage.test.ts`](file:///e:/MediaServer/web/src/test/proxy-coverage.test.ts)
- Upgrade the test suite from assuming a single Flask origin to asserting explicit dual-origin proxy partitioning.
- Verify that every Rust endpoint targets `RUST_ORIGIN` (`http://127.0.0.1:8001`).
- Verify that every Flask endpoint targets `FLASK_ORIGIN` (`http://127.0.0.1:8000`).
- Assert that every proxy rule targets a valid loopback origin (`:8000` or `:8001`).

```diff
--- a/web/src/test/proxy-coverage.test.ts
+++ b/web/src/test/proxy-coverage.test.ts
@@ -7,1 +7,1 @@
-const proxy = (config.server?.proxy ?? {}) as Record<string, unknown>;
+const proxy = (config.server?.proxy ?? {}) as Record<string, { target?: string }>;
@@ -63,7 +63,40 @@
-describe('dev proxy wiring', () => {
-  it('targets the Flask origin for every entry', () => {
-    for (const entry of Object.values(proxy)) {
-      expect((entry as { target?: string }).target).toMatch(/^http:\/\/127\.0\.0\.1:8000$|^http:\/\//);
-    }
-  });
-});
+describe('dev proxy dual-origin wiring', () => {
+  it('routes Rust-migrated endpoints to the Rust engine origin (:8001)', () => {
+    const rustEndpoints = [
+      '/api/movies',
+      '/api/movie',
+      '/api/progress',
+      '/api/system-status',
+      '/api/seek-preview-meta',
+      '/api/subtitles',
+      '/api/upload-subtitle',
+      '/api/transcode-status',
+      '/api/transcodes',
+      '/api/health',
+      '/media',
+      '/hls',
+      '/seek-preview',
+      '/preview-vtt',
+      '/subtitles',
+    ];
+    for (const prefix of rustEndpoints) {
+      const entry = proxy[prefix];
+      expect(entry, `missing proxy configuration for ${prefix}`).toBeDefined();
+      expect(entry?.target).toMatch(/^http:\/\/127\.0\.0\.1:8001$|^http:\/\//);
+    }
+  });
+
+  it('routes unmigrated endpoints to the Flask origin (:8000)', () => {
+    const flaskEndpoints = [
+      '/api',
+      '/tmdb-poster',
+      '/tmdb-backdrop',
+      '/poster',
+      '/auth',
+    ];
+    for (const prefix of flaskEndpoints) {
+      const entry = proxy[prefix];
+      expect(entry, `missing proxy configuration for ${prefix}`).toBeDefined();
+      expect(entry?.target).toMatch(/^http:\/\/127\.0\.0\.1:8000$|^http:\/\//);
+    }
+  });
+
+  it('targets a valid loopback origin for every entry', () => {
+    for (const entry of Object.values(proxy)) {
+      expect(entry.target).toMatch(/^http:\/\/127\.0\.0\.1:(8000|8001)$|^http:\/\//);
+    }
+  });
+});
```

---

## 5. Verification Plan

### Automated Tests
1. **Vitest Suite**:
   ```powershell
   cd e:\MediaServer\web
   npm test -- --run
   ```
   *Expected Outcome:* All 25 test suites and 174+ unit/integration tests pass with 0 failures, specifically including `proxy-coverage.test.ts`.

2. **TypeScript & Linter Checks**:
   ```powershell
   cd e:\MediaServer\web
   npm run typecheck
   npm run lint
   ```
   *Expected Outcome:* Clean typecheck (`tsc -b`) and 0 linter errors (`oxlint`).

3. **Production SPA Build**:
   ```powershell
   cd e:\MediaServer\web
   npm run build
   ```
   *Expected Outcome:* `dist/` bundle compiled in <1.5s with 0 errors.

### Manual Verification
1. Verify simulated request matching in Node:
   - Check that `/api/movies` resolves to `proxy['/api/movies'].target === 'http://127.0.0.1:8001'`
   - Check that `/api/cast/devices` resolves to `proxy['/api'].target === 'http://127.0.0.1:8000'`
   - Check that `/tmdb-poster/157336` resolves to `proxy['/tmdb-poster'].target === 'http://127.0.0.1:8000'`
   - Check that `/media/sample.mp4` resolves to `proxy['/media'].target === 'http://127.0.0.1:8001'`
