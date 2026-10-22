# Handoff — 2026-10-22 13:50 IST — Network benchmark, Caddy `admin off`, and media-upload port

**Agent:** opencode
**Status:** Investigation and documentation complete. **No code changes.** Implementation is
awaiting approval.
**Benchmark report:** [`docs/NETWORK_BENCHMARK_2026-10-22.md`](../docs/NETWORK_BENCHMARK_2026-10-22.md)

---

## 0. Repository state

- Last commit: `ef010dd`.
- `M scripts/router_port_forward.ps1` is a **pre-existing** modification. Do not revert it.
- New uncommitted docs: `docs/NETWORK_BENCHMARK_2026-10-22.md` and this handoff.
- **No code changes** in this session.
- Local commits `aa523a9` and `ef010dd` are **not pushed**.
- The Airtel static-IP email is drafted but **unsent**. Do not send it unless asked.

---

## 1. What was asked

1. Document the completed public/LAN benchmark, including what Caddy `admin off` means.
2. Check the Rust/Axum upload body limit; remove the blocking limitation if one exists.
3. Port the Flask media-upload feature to Rust/Axum + React, accessible only to an admin
   session or with the configured Admin PIN, without hard-coding it.
4. Keep documenting continuously because the context window is small.

---

## 2. Benchmark summary

Full tables and caveats: [`docs/NETWORK_BENCHMARK_2026-10-22.md`](../docs/NETWORK_BENCHMARK_2026-10-22.md).

| Measurement | Result | Meaning |
| --- | ---: | --- |
| ISP download (Cloudflare / Ookla) | 197 / 203–206 Mbps | ~200 Mbps-class line. |
| ISP upload (Cloudflare / Ookla) | 109–114 / 61–79 Mbps | Single-stream; endpoint-dependent. |
| Parallel upload, best case | ~120–160 Mbps | Observed aggregate, not a plan rate. |
| Public hairpin HLS | 627–736 Mbps | LAN/router/Caddy path, **not ISP**. |
| LAN loopback HLS, cold / warm | 1.386 / 4.29 Gbps | `192.168.1.16` from the server = loopback/RAM. |
| Direct file, `D:` | 455–732 Mbps | HDD-bound. |
| `E:` SSD / `D:` HDD sequential | 211–228 / 56–91 MB/s | Runtime/cache vs cold media. |
| LAN `/health` / HLS | 1.4 / 4.8 ms | Local path. |
| Public `/health` / HLS | 35.3 / 37.6 ms | Mostly local DNS+TLS/hairpin. |
| Public TCP connect | 2.7 ms | Connect only. |
| Server processing | 1.5–4.7 ms | Origin handling. |

**Capacity at ~100 Mbps usable uplink:** roughly 5–7 concurrent 4K HLS (~14 Mbps each),
4–5 direct 4K (~18 Mbps), 15–22 1080p. Estimates with normal headroom, not guarantees.

**Line framing:** the line behaves like a **200/100-class** service. It is **not proven to be
200/200**. The upload is provisioned below 200 Mbps. If the plan is 200/200, raise an Airtel
ticket; if the plan is 200/100, the upload is at plan. The Airtel Lucknow Ookla server's
4.5–4.9 Mbps upload is endpoint-capped and is **excluded**.

**Caveats:**
- Public tests from the server's laptop are **hairpin**: they measure the LAN/router/Caddy path,
  not the ISP.
- `192.168.1.16` from the server is **loopback**; the Gbps numbers are not NIC throughput.
- No true external-client throughput test was possible; the remote fleet needs user consent.
- `r.jina.ai` fetched `/health` with HTTP 200; the HLS master returned 422 through Jina, which is
  the fetch service's limitation, not an origin failure.
- Public ~35 ms latency is not a WAN RTT; it is dominated by local DNS/TLS and the hairpin route.

**Ingress:** public static IP `171.50.176.119`; DNS/Caddy/TLS working; only **443/80** are
forwarded; the old **8000** forward is gone.

---

## 3. What Caddy `admin off` means

`E:\MediaServer\Caddyfile` has **`admin off`** in the global block.

- Caddy's admin API (default `127.0.0.1:2019`) is **disabled**.
- `caddy reload`, `caddy stop`, and dynamic config changes through the admin API fail.
- To change the Caddyfile, edit it and **restart the `MediaServerCaddy` service** (or run Caddy
  with the new config). There is no reload endpoint.
- `admin off` does **not** impose a request-body limit. `reverse_proxy` streams request and
  response bodies. The 2 MB upload cap found below is **Axum's** default, not Caddy's.

---

## 4. Axum upload limit — confirmed

The backend is Axum 0.8 with `multipart`. There is **no** `DefaultBodyLimit`,
`RequestBodyLimitLayer`, or equivalent in `rust/src`. Axum's default **2 MB** body limit applies
to `Multipart` / `Bytes` extractors.

Measured against the live service:

| Test | Result |
| --- | --- |
| 1.5 MB subtitle upload | Succeeded. |
| 3 MiB subtitle upload | **HTTP 400** `{"error":"Error parsing \`multipart/form-data\` request","status":400}`. The `Multipart` handler maps the limit error to 400, not 413. |
| `POST /api/upload` | **404** — no route. |
| `POST /api/upload/chunk/init` | **404** — no route. |
| `POST /api/upload-subtitle/{filename}` | Exists; the 1.5 MB success was here. |

Because the Flask chunk size is **8 MiB**, a port that reused it would fail on the first chunk
under the 2 MB default. The fix is **per-route** limits, not a global
`DefaultBodyLimit::disable()` — the latter would make every JSON/multipart route an unbounded
body DoS surface.

Proposed limits:

| Route | Limit |
| --- | ---: |
| `POST /api/upload/chunk/{upload_id}` | 8 MiB + small overhead |
| `POST /api/upload` (single-file compatibility) | 256 MiB |
| `POST /api/upload-subtitle/{*filename}` | 16 MiB |
| All other routes | Axum default 2 MB unchanged |

The chunked route plus the 20 GiB total cap is the path for large files.

---

## 5. Admin auth and the Admin PIN

- The Rust gate is `AuthService::is_admin_authorized` in
  `rust/src/services/auth_service.rs:119`. It accepts an authenticated admin session or the
  `X-Admin-Pin` header / JSON body PIN. It reads `settings.admin_pin`.
- The PIN is **not** hard-coded. It is already set in the database.
- Live verification: `GET /api/admin/status` with the configured `X-Admin-Pin` returned HTTP 200
  `{"is_admin":true,"has_pin":true,"user":null}`. No DB change was made.
- The PIN is **never** accepted from a query string.

React primitives already present:

- `getStoredAdminPin` — `web/src/lib/api/account.ts` (reads `sessionStorage.ms_admin_pin`,
  with a localStorage fallback).
- `verifyAdminPin` — `web/src/lib/api/manage.ts:122` (`POST /api/admin/verify` with `{pin}`).
- `AdminPinModal` — `web/src/features/manage/components/AdminPinModal.tsx` (portaled).
- `AdminPinSignInModal` — `web/src/components/AdminPinSignInModal.tsx`.
- `useAuth().role` / `AuthProvider` — `web/src/auth/AuthProvider.tsx`.
- `ManagePage` uses `AdminPinModal` + `verifyAdminPin` and sends `X-Admin-Pin`.

---

## 6. Recovered Flask upload contract

Recovered from git (`c5ee97d^` = before `app/` deletion; `5a2af4f^` = before templates deletion).

### 6.1 Single-file route

`5a2af4f^:app/routes/api.py:513`

- `@api_bp.route('/api/upload', methods=['POST'])`, decorated `@require_admin`.
- Multipart fields: `file`, optional `title`, optional `overwrite`.
- Sanitizes the filename, checks `VIDEO_EXTENSIONS`, saves to `MEDIA_ROOT` via
  `.upload_<name>.part`, then atomic replace.
- `_prepare_media` scans the single file, inserts/updates a fallback `movies` row, triggers the
  library scan, starts a transcode if needed, and prefetches subtitles.
- Response `UploadSuccessResponse`:
  `{success, filename, title, year, needs_transcode, details_url}`.

### 6.2 Chunked routes

`c5ee97d^:app/routes/upload.py`

- `CHUNK_SIZE = 8 * 1024 * 1024`; `MAX_UPLOAD_BYTES = 20 * 1024 * 1024 * 1024` (20 GiB).
- `POST /api/upload/chunk/init` — **admin-gated**; JSON `{filename, size, title, overwrite}`;
  returns `{success, upload_id, filename, size, offset, chunk_size}`.
- `GET|POST|DELETE /api/upload/chunk/{upload_id}`:
  - `GET` returns status.
  - `POST` is raw `application/octet-stream` with `X-Upload-Offset`; returns
    `{success, upload_id, offset, size, complete}`.
  - Offset mismatch returns **409** with `current_offset`.
  - A chunk larger than 8 MiB returns **413**.
  - `DELETE` removes the session.
- `POST /api/upload/chunk/{upload_id}/complete` — checks exact total size, moves the part file
  to the target, scans, returns `UploadSuccessResponse`.
- **Important:** only `init` was admin-gated. The append and complete routes were **not** gated.
  The port must gate **all** upload routes.
- Upload ID: `secrets.token_urlsafe(24)`; validated by
  `^[A-Za-z0-9_-]{20,64}$`.
- Session files: `<upload_id>.json` manifest + `<upload_id>.part` data, in `UPLOAD_TMP`
  (default `MEDIA_ROOT/.uploads`).
- Target: `UPLOAD_TARGET_DIR` (default `MEDIA_ROOT`), unique `stem (n).ext` names.

### 6.3 Active Flask UI

`5a2af4f^:static/js/nav.js` (lines ~169–388) overrides `startUpload` with resumable 8 MiB XHR
chunks:

- `init` / `complete` via `fetch`; chunks via XHR.
- Progress, speed, ETA, abort (`DELETE`).
- Offset-mismatch handling resumes from `current_offset`; transient errors retry.
- After the last chunk: abort button hidden, processing card shown, `complete` called.
- Success box with title and `details_url`; reload after 1.5 s.
- The modal markup is `5a2af4f^:templates/library.html` lines 2–78.
- The `init` fetch did **not** send `X-Admin-Pin`; it relied on the admin session. The React
  port will send the PIN header when a PIN is stored.

### 6.4 Response schema

`web/src/lib/api/schema.ts`:

- `UploadSuccessResponse` line 1455: `{success, filename, title, year?, needs_transcode, details_url}`.
- `ChunkInitResponse` line 1463: `{success, upload_id, filename, size, offset, chunk_size}`.
- `ChunkStatusResponse` line 1471: same shape as init.

---

## 7. Current Rust/React state

### Rust

- **No media upload routes.** Only `/api/upload-subtitle/{*filename}` exists
  (`rust/src/routes/subtitles.rs`). `/api/upload` and `/api/upload/chunk/*` return 404.
- `rust/src/lib.rs` builds per-feature routers and merges them. Add an `UploadState` router the
  same way.
- `AppConfig` (`rust/src/config.rs:66`) has `database_url`, `host`, `port`, `media_root`,
  `media_roots`, `cache_dir`, `static_dir`, `flask_origin`, `base_dir`, `tmdb_api_token`,
  `public_base_url`. It does **not** read `MEDIA_SERVER_UPLOAD_TMP` or
  `MEDIA_SERVER_UPLOAD_TARGET_DIR`, although both keys exist in `.env`.
- `ScanService::trigger_scan` exists (`rust/src/services/scan_service.rs`); it is a
  **full-library** scan. There is no single-file scan. A fallback `movies` row plus the full scan
  is the practical port of the Flask `_prepare_media`.
- `AuthService::generate_random_token` (`auth_service.rs:47`) uses `getrandom` and returns
  64 hex chars. Use it for upload IDs; never a clock.
- `AppError` (`rust/src/error.rs`) has no 413 variant. Add one (or map).
- `test_support::test_config()` isolates the database and cache but **leaves media roots alone**
  (by design). Upload tests must use temp upload dirs and a no-op scan trigger; do not write to
  `D:\Flicks`.
- `upload_tmp` path currently **does not exist**; no stale upload sessions were found.
- No recent large subtitle artifact (>1 MB) was found in `D:\Flicks`; the 3 MiB test created
  nothing.

### React

- **No media upload UI.** Only the stale schema and the subtitle upload exist.
- `LibraryPage` (`web/src/features/library/LibraryPage.tsx`) has search/filter/sort but no upload
  button. It uses `useAsync` and exposes `reload()`.
- `AppShell` (`web/src/app/AppShell.tsx`) nav already has `Manage`; a library-page button is the
  smallest change.
- Route `/movie/*` exists (`web/src/main.tsx:35`), so `details_url: /movie/<rel_filename>` works.
- `MovieDetailsPage` is `web/src/features/media-details/MovieDetailsPage.tsx`.
- `AdminPinModal`, `verifyAdminPin`, `getStoredAdminPin`, and `useAuth` are ready to reuse.

---

## 8. Proposed implementation (approval required)

### 8.1 Scope

**In scope**

- Native Rust/Axum media upload endpoints: single-file compatibility route, resumable chunked
  route (8 MiB chunks, 20 GiB total), status, abort, complete.
- Admin authorization on **all** upload routes via admin session or `X-Admin-Pin`; PIN from
  `settings.admin_pin`, never hard-coded and never from a query string.
- Per-route Axum body limits so the 2 MB default no longer blocks uploads.
- Safe filename sanitization, unique names, atomic move, temp cleanup.
- React upload modal with 8 MiB chunks, progress/speed/ETA, abort, success link, and the admin
  PIN gate.
- Trigger the existing full-library scan after completion; insert a minimal fallback `movies` row
  so the details link works immediately while the scan enriches metadata.
- Tests, OpenAPI/schema updates, operator/user documentation, live probe.

**Out of scope / deliberately unchanged**

- No global `DefaultBodyLimit::disable()`; only per-route limits.
- No hard-coded PIN and no DB change; the configured PIN remains the live setting.
- No change to subtitle-upload authorization (the player uses it); only its body limit may rise.
- No change to Caddy `admin off`; no Caddy reload.
- No change to media roots or the dual-drive storage tiering.
- No blocking transcode on upload; the normal auto-transcode path handles playback.
- No Flutter `/api/*` contract change; do not add upload to `probe_android_api.py`.
- No commit or push unless asked.

### 8.2 Backend

New files:

- `rust/src/routes/upload.rs` — handlers:
  - `POST /api/upload` (single-file)
  - `POST /api/upload/chunk/init`
  - `GET|POST|DELETE /api/upload/chunk/{upload_id}`
  - `POST /api/upload/chunk/{upload_id}/complete`
- `rust/src/models/upload.rs` — response/request structs matching the existing schema:
  `UploadSuccessResponse`, `ChunkInitResponse`, `ChunkStatusResponse`, `ChunkInitRequest`.
- `rust/src/services/upload_service.rs` — pure/async logic: filename/title sanitization, target
  path resolution, manifest read/write, offset validation, complete/finalize, stale cleanup.

Modified files:

- `rust/src/config.rs` — add `upload_tmp: PathBuf` and `upload_target_dir: PathBuf`, read from
  `MEDIA_SERVER_UPLOAD_TMP` / `MEDIA_SERVER_UPLOAD_TARGET_DIR`, defaulting to
  `media_root/.uploads` and `media_root`.
- `rust/src/lib.rs` — build `UploadState` and merge the upload router. `UploadState` holds
  `pool`, `config`/upload dirs, and a `scan_trigger` closure. Production closure calls
  `ScanService::trigger_scan`; tests inject a no-op.
- `rust/src/error.rs` — add `PayloadTooLarge(String)` (413) and map it.
- `rust/src/routes/mod.rs`, `models/mod.rs`, `services/mod.rs` — module declarations.
- `rust/src/test_support.rs` — point upload temp/target at a per-test temp dir; keep DB/cache
  isolation.
- `rust/src/lib.rs` route layering:
  - chunk route: `DefaultBodyLimit::max(8 MiB + 64 KiB)`
  - single-file route: `DefaultBodyLimit::max(256 MiB)`
  - subtitle route: `DefaultBodyLimit::max(16 MiB)`
  - everything else: default 2 MB.

Behavior:

- Generate upload IDs with `AuthService::generate_random_token()` (64 hex), validate the route
  param against `^[A-Za-z0-9_-]{20,64}$`.
- Init body: `{filename, size, title?, overwrite?}`; reject `size <= 0` or `> 20 GiB`;
  sanitize name; create `<id>.part` with `create_new`; write `<id>.json` manifest atomically.
- Chunk: `X-Upload-Offset` (default 0, matching Flask); require offset == current part size;
  otherwise 409 with `current_offset`; require body length `<= 8 MiB` and
  `offset + len <= total`; write at the offset and `sync_all`.
- Complete: require actual size == expected total; choose target name (unique `(n)` unless
  `overwrite`); move atomically (same volume) or copy+remove (cross-volume); remove manifest;
  insert fallback `movies` row with `ON CONFLICT DO NOTHING`; trigger scan; return
  `UploadSuccessResponse`.
- Abort: remove part + manifest; return success.
- Stale cleanup: on init (or startup), delete sessions older than 24 h; optional free-space check.
- Sanitization: basename only; strip `/\:NUL`; reject `.`, `..`, empty, unsupported extension;
  optional title override; ensure the final path stays inside `upload_target_dir`.
- Allowed extensions (recommended): `.mp4`, `.mkv`, `.webm`, `.mov`, `.avi`, `.m4v`; align with
  the scanner and the old UI.

### 8.3 Frontend

New files under `web/src/features/upload/`:

- `uploadApi.ts` — `initUpload`, `sendChunk`, `getStatus`, `completeUpload`, `abortUpload`;
  `credentials: 'same-origin'`; `X-Admin-Pin` from `getStoredAdminPin()` when present.
- `useMediaUpload.ts` — state machine (`idle`, `selecting`, `uploading`, `processing`,
  `success`, `error`), 8 MiB chunk loop, progress/speed/ETA, 409 offset resume, transient retry,
  abort.
- `MediaUploadModal.tsx` — portaled to `document.body`; dropzone + file card + optional title;
  progress bar; abort; success/error; `details_url` link.

Modified:

- `web/src/features/library/LibraryPage.tsx` — add an always-visible “Upload Media” button
  (including when the library is empty). If `role !== 'admin'` and no stored PIN, open the
  existing `AdminPinModal`; verify with `verifyAdminPin`; store in
  `sessionStorage.ms_admin_pin`; then open the upload modal. On success call `reload()`.
- Reuse `AdminPinModal`, `verifyAdminPin`, `getStoredAdminPin`, `useAuth`, `Icon`.
- On 403 from any upload call: clear the stored PIN, close the upload modal, reopen the PIN modal.
- Portal/overflow: `fixed inset-0 z-50 ... overflow-y-auto`, card `my-auto`, matching the
  existing modal invariant.

### 8.4 Tests and verification

Rust:

- Unit tests: filename/title sanitization, path traversal rejection, unique target names,
  manifest round-trip, offset validation, exact-size completion, abort cleanup.
- Route tests: no PIN / wrong PIN -> 403; correct `X-Admin-Pin` -> 200; admin session ->
  200; query-string PIN ignored; 8 MiB chunk accepted; 9 MiB -> 413; wrong offset -> 409 with
  `current_offset`; complete -> file moved + response shape; abort -> no temp files.
- Use temp upload dirs and a no-op scan trigger; clean any test `movies` row.
- The global 2 MB limit still applies outside upload routes (e.g. a 3 MB JSON body rejected).

Web:

- Vitest/Testing Library: PIN gate (no PIN/wrong PIN/correct PIN), file selection, chunk progress,
  success, error, abort, 403 re-prompt; mock `fetch`/XHR.
- `npm run test` and `npm run build`.

Live:

- Extend the manual/live probe: init -> chunk(s) -> status -> complete with a small test `.mp4`
  using `X-Admin-Pin`; verify the file, response, and library; remove the test file and row.
- `python scripts/probe_android_api.py` must remain green (no upload changes to the Flutter
  surface).

### 8.5 Exit criteria

- A non-admin with no PIN gets **403** on every upload route; the correct `X-Admin-Pin`
  gets **200**; an admin session gets **200**; a query-string PIN does nothing.
- An **8 MiB** chunk is accepted; a **9 MiB** chunk is rejected **413**; a wrong offset returns
  **409** with `current_offset`.
- A multi-chunk file completes, lands in `MEDIA_SERVER_UPLOAD_TARGET_DIR`, returns the documented
  `UploadSuccessResponse`, appears in the library, and `/movie/<filename>` works.
- Abort and failure leave no `.part`/manifest behind; stale sessions are cleaned.
- Path traversal, unsupported extensions, wrong size, and over-20 GiB are rejected.
- The 2 MB default still protects non-upload routes; only the four upload routes have larger
  limits.
- Rust tests, web tests, and the web build pass; the Flutter probe is unchanged and green.
- OpenAPI/schema and docs are updated; no hard-coded PIN; no test data remains.
- After a backend build, `MediaServerRust` is restarted and the binary timestamp is newer than
  the last source commit.

### 8.6 Risks

- **Global body-limit disable would be a DoS.** Use per-route caps only.
- **Auth bypass on chunk append/complete** was a real Flask gap. Gate every route and test it.
- **Path traversal / overwrite / disk exhaustion.** Sanitize, cap at 20 GiB, check free space,
  clean stale sessions.
- **Full scan is slow.** Insert the fallback row and trigger the scan asynchronously; do not block
  the upload response. The UI can show “Processing…” and refresh.
- **Test contamination.** Temp upload dirs, no-op scan trigger, explicit cleanup; never write to
  `D:\Flicks` in tests.
- **Windows file locks.** Use atomic rename on the same volume; fall back to copy+remove; do not
  delete an open file.
- **Caddy `admin off`.** Caddyfile changes need a `MediaServerCaddy` restart; the upload path
  itself does not need a Caddy change.
- **Service restart.** Notify the user and verify the binary timestamp after rebuilding.

### 8.7 Open decisions (recommended defaults in bold)

1. **Single-file cap:** **256 MiB** (chunked path for larger files) vs unbounded/streaming.
2. **Post-upload scan:** **insert a fallback `movies` row and trigger the full scan
   asynchronously** vs wait for scan completion vs no auto-scan.
3. **Upload button placement:** **library page top row** (always visible) vs header nav/route.
4. **Allowed extensions:** **the six UI formats (`mp4, mkv, webm, mov, avi, m4v`)** vs the
   scanner's full list.
5. **Name collision:** **unique `stem (n).ext` plus an optional `overwrite` flag** vs always
   replace.
6. **PIN UX:** **reuse the local `AdminPinModal` + `sessionStorage.ms_admin_pin`** vs the global
   `AdminPinSignInModal` session only.

---

## 9. Files and commands

### New (planned)

- `rust/src/routes/upload.rs`
- `rust/src/models/upload.rs`
- `rust/src/services/upload_service.rs`
- `rust/tests/upload_*.rs`
- `web/src/features/upload/uploadApi.ts`
- `web/src/features/upload/useMediaUpload.ts`
- `web/src/features/upload/MediaUploadModal.tsx`
- `docs/UPLOAD_FEATURE.md`
- `scripts/probe_upload_api.py` (optional live probe)

### Modified (planned)

- `rust/src/lib.rs`, `rust/src/config.rs`, `rust/src/error.rs`, `rust/src/test_support.rs`,
  `rust/src/routes/mod.rs`, `rust/src/models/mod.rs`, `rust/src/services/mod.rs`
- `web/src/features/library/LibraryPage.tsx`
- `docs/openapi.yaml`, `web/src/lib/api/schema.ts` (align with the existing Flask contract)
- `docs/MANUAL.md` (upload section)

### Reuse (no change expected)

- `rust/src/services/auth_service.rs` (`is_admin_authorized`, `generate_random_token`)
- `rust/src/services/scan_service.rs` (`trigger_scan`)
- `web/src/features/manage/components/AdminPinModal.tsx`
- `web/src/lib/api/manage.ts` (`verifyAdminPin`)
- `web/src/lib/api/account.ts` (`getStoredAdminPin`)
- `web/src/auth/AuthProvider.tsx` (`useAuth`)

### Commands

```powershell
cargo test --manifest-path rust/Cargo.toml -- --test-threads=1

cd web
npm run test
npm run build
cd ..

python scripts/probe_android_api.py
# plus the new upload probe
```

After a backend rebuild:

```powershell
e:\MediaServer\scripts\restart_rust_service.bat
Get-Item rust\target\release\media-server-api.exe | Select-Object LastWriteTime
git --no-pager log -1 --format=%cd --date=format:'%Y-%m-%d %H:%M:%S'
```

Do not run Playwright alongside a transcode; the harness uses `--disable-gpu`. The web oracles
need the Vite dev server on `http://localhost:5173` only while they run.

---

## 10. Next step

**Awaiting approval of §8.** On approval with the recommended defaults, implement in slices:

1. Backend config + service + routes + per-route limits + auth + tests.
2. React API/hook/modal + library button + PIN gate + tests.
3. OpenAPI/schema/manual docs + live probe.
4. Restart `MediaServerRust`, verify the binary timestamp, run the test suites, and report.

---

## 11. Implementation status (2026-10-22)

The port is implemented with the recommended defaults. The actual artefact names differ from
the planned ones above:

- Backend: `rust/src/routes/upload.rs`, `rust/src/models/upload.rs`,
  `rust/src/services/upload_service.rs`, `rust/tests/upload_flow_test.rs`.
- Frontend: `web/src/features/upload/uploadApi.ts`,
  `web/src/features/upload/useMediaUpload.ts`,
  `web/src/features/upload/MediaUploadModal.tsx`,
  `web/src/features/upload/uploadApi.test.ts`.
- Live probe: `scripts/probe_upload.py` (not `probe_upload_api.py`).
- Detailed record: `docs/MEDIA_UPLOAD_PORT_2026-10-22.md` (not `docs/UPLOAD_FEATURE.md`).

Verification completed:

- Full Rust suite: **322 passed, 0 failed, 0 ignored** across the unit suite and every
  integration test binary, run with `cargo test -j 1 -- --test-threads=1`.
- Upload integration tests: **5/5**; upload service unit tests: **4/4**.
- Web suite: **42 files / 306 tests**, all passing; production build passes; lint exits 0 with
  warnings only.
- Upload API tests: **6/6**.

Deployment and live verification (2026-10-22, 14:53–15:08 IST):

- `MediaServerRust` is `RUNNING`; `/health` returns healthy.
- The release binary is dated **14:53:48** and is **14,620,672 bytes**. It is newer than the last
  commit (`ef010dd`, 12:44:17) and newer than the newest upload source file
  (`upload_service.rs`, 14:07:13).
- `/api/admin/status` reports `has_pin: true`. The PIN was read from PostgreSQL into the probe's
  environment without being printed.
- Unauthenticated `scripts/probe_upload.py`: **exit 0**, two `403` checks pass.
- Authorized `scripts/probe_upload.py`: **exit 0**, 7/7 checks (init → append 4 bytes → status →
  abort → 404).
- `scripts/probe_android_api.py`: **exit 0**, 22/22 endpoints per contract.
- `D:\Flicks\.uploads` is empty and no `probe_upload_*` file remains under `D:\Flicks`.
- `web/dist` assets were built at 14:41:59 and contain the upload UI, so the running service is
  serving the feature-bearing React bundle.

One probe defect was found and fixed during verification: the first authorized run declared
`size: 4` but appended the 5-byte literal `b"probe"`. The server answered `400 Chunk extends past
the declared upload size`, which is the guard working correctly. The fixture is now `b"test"` and
the probe passes. The running server was not changed to accommodate the bad fixture.

The live SPA was also checked: the library page rendered **Upload Media**, and clicking it opened
the **Unlock Admin Mode** 4-digit PIN dialog. It was cancelled without entering a PIN or selecting
a file, so no upload occurred and no row was created.

Still optional: complete a real browser upload from that dialog with a disposable file, then remove
it from the library so no catalog row remains. The UI is covered by the web suite, the deployed
bundle was checked, and the live entry point/PIN gate has now been seen.

The Airtel static-IP email remains drafted and unsent. No commit or push was made. The
pre-existing `M scripts/router_port_forward.ps1` change was left untouched.


The recommended §8.7 decisions were implemented as stated; no further approval is required for the
port itself.
