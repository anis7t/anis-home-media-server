# Media Upload Port — Native Rust/Axum + React

**Date:** 2026-10-22
**Status:** Implemented, built, deployed, and live-verified against the running
`MediaServerRust` service on 2026-10-22. The release binary is newer than both the last commit and
the newest upload source file; `/health` is healthy, the Admin PIN is configured, the authorized and
unauthenticated upload probes pass, and the Android client contract probe is 22/22. The live SPA shows
the **Upload Media** entry point and opens the **Unlock Admin Mode** PIN dialog. The only
unexercised path is the final file selection/transfer from that dialog (see §8).

## 1. Scope

This completes the port of the retired Flask upload feature to the native stack:

- single-file `POST /api/upload` compatibility route,
- resumable 8 MiB chunked upload (`init` / append / status / abort / complete),
- React UI on the library page, with an admin-session or Admin-PIN gate,
- per-route Axum body limits so the chunk route is not blocked by the global 2 MB default,
- live and unit coverage, OpenAPI and user-manual updates.

The port deliberately keeps the old contract shapes (`upload_id`, byte `offset`, `complete`,
`ChunkStatusResponse`, `UploadSuccessResponse`) so the React client and any existing tooling can
speak to it without a translation layer.

## 2. Routes and authorization

| Method | Route | Purpose | Auth |
| --- | --- | --- | --- |
| `POST` | `/api/upload` | Single-file compatibility upload, max **256 MiB** | admin session or `X-Admin-Pin` |
| `POST` | `/api/upload/chunk/init` | Start a resumable session, max **20 GiB** | admin session or `X-Admin-Pin` |
| `GET` | `/api/upload/chunk/{upload_id}` | Report the current received offset | admin session or `X-Admin-Pin` |
| `POST` | `/api/upload/chunk/{upload_id}` | Append one chunk at `X-Upload-Offset` | admin session or `X-Admin-Pin` |
| `DELETE` | `/api/upload/chunk/{upload_id}` | Abort and remove the temporary session | admin session or `X-Admin-Pin` |
| `POST` | `/api/upload/chunk/{upload_id}/complete` | Verify, move into the library, index | admin session or `X-Admin-Pin` |

**Every route is gated**, including append and complete. The Flask implementation only gated
`init`; this port closes that gap. Authorization goes through
`AuthService::is_admin_authorized()`, which accepts:

1. a valid `session_token` cookie with the `admin` role, or
2. the configured Admin PIN in the `X-Admin-Pin` header.

The PIN is never read from a query string, a JSON body, or a cookie. The route passes
`body_pin = None`, so only the header path is available to an unauthenticated caller. The PIN
itself is not hard-coded: it is read from the `settings.admin_pin` PostgreSQL row, and the test
suite uses a distinct test PIN (`97531`) to prove the production value is not baked into the code.

Refusals are `403 Forbidden` with a JSON body. The React client shows the server's message rather
than inventing one.

## 3. Limits and body-limit design

| Limit | Value | Enforcement |
| --- | --- | --- |
| Chunk size | **8 MiB** (`8 * 1024 * 1024`) | server rejects a chunk over 8 MiB; client slices at exactly 8 MiB |
| Chunk request body | 8 MiB + 64 KiB | per-route `DefaultBodyLimit`; the extra 64 KiB leaves room for multipart/HTTP overhead |
| Total resumable upload | **20 GiB** | declared at `init`, checked at append and complete |
| Single-file compatibility | **256 MiB** | per-route `DefaultBodyLimit` and an explicit size check |
| Subtitle upload | **16 MiB** | per-route `DefaultBodyLimit` on `/api/upload-subtitle/{*filename}` |
| All other routes | Axum **2 MB** default | unchanged |

The global default is intentionally **not** disabled. `DefaultBodyLimit::disable()` would turn
every JSON and multipart endpoint into an unbounded-body surface; per-route limits keep the
upload feature from weakening the rest of the API. The integration test
`upload_init_keeps_the_default_json_body_limit` pins that `/api/upload/chunk/init` still refuses
a 3 MiB JSON body, while `chunk_flow_enforces_offsets_limits_and_completes` pins the 8 MiB + 1
and 9 MiB chunk refusals.

## 4. Storage and lifecycle

- Upload IDs are generated with `AuthService::generate_random_token()` (OS CSPRNG, 64 hex
  characters), not a clock or counter, and validated to the filename-safe character set.
- Temporary state lives in `MEDIA_SERVER_UPLOAD_TMP` (default `<first media root>/.uploads`):
  - `<upload_id>.part` — raw bytes,
  - `<upload_id>.json` — manifest (original filename, declared size, title override, overwrite
    flag, creation time).
- `init` removes sessions older than 24 hours before creating a new one.
- Appending requires the request's `X-Upload-Offset` (default `0`) to equal the current
  `.part` length. A mismatch returns `409` with `current_offset`; the client rewinds to that
  offset instead of restarting the file.
- `complete` verifies the final byte count exactly, sanitizes the filename, applies an optional
  title override while preserving exactly one extension, and moves the file into
  `MEDIA_SERVER_UPLOAD_TARGET_DIR` (default the first media root).
- Name collisions produce `name (1).ext`, `name (2).ext`, … unless the caller explicitly set
  `overwrite: true`; overwrite is never the default.
- Path components, traversal segments, control characters, and unsupported extensions are
  rejected. The accepted extensions are `mp4`, `mkv`, `webm`, `mov`, `avi`, `m4v`.
- After the move, a fallback `movies` row is inserted with `ON CONFLICT DO NOTHING`, a full scan
  is triggered asynchronously, and the response carries `filename`, `title`, `year`,
  `needs_transcode`, and `details_url`.
- `DELETE` unlinks the manifest and part file. A crash or network loss can still leave state
  behind; the 24-hour `init` sweep is the backstop.

Production paths are configured in `.env`:

```dotenv
MEDIA_SERVER_UPLOAD_TARGET_DIR='D:\Flicks'
MEDIA_SERVER_UPLOAD_TMP='D:\Flicks\.uploads'
```

The staging directory must exist and be writable by the `MediaServerRust` service account.

## 5. React UI

- **Library page:** an always-visible **Upload Media** button at the top of `/`.
- **Access:** a signed-in admin uploads directly. Otherwise the page opens the existing
  `AdminPinModal`, verifies the PIN with `POST /api/admin/verify`, stores it in
  `sessionStorage.ms_admin_pin`, and reopens the upload dialog. Outside an `AuthProvider` (for
  example in the existing library tests) `useOptionalAuth` returns `null`, so the page still
  renders and simply follows the PIN path.
- **Upload modal:** drag/drop or file picker, optional title, explicit overwrite switch,
  allowed-extension validation, and a 20 GiB client-side guard.
- **Transfer:** `XMLHttpRequest` per chunk (for upload progress), sequential at the
  server-reported offset, with transfer speed and a measured ETA. Transient network/5xx failures
  retry twice with a short backoff; a `409` rewinds to `current_offset`; the abort control calls
  `DELETE`.
- **Completion:** the modal shows a processing state, then the server's title/year and a
  **View details** link; the library reloads so the new title appears without a page refresh.
- **PIN handling:** the PIN is passed in `X-Admin-Pin`, never in the URL. The upload hook does
  not invent a PIN if none is available; the server refuses.

The API helper is `web/src/features/upload/uploadApi.ts`; the state machine is
`useMediaUpload.ts`; the dialog is `MediaUploadModal.tsx`. `LibraryPage.tsx` owns the PIN flow.

## 6. Verification

### Rust

- `cargo test --manifest-path rust/Cargo.toml -j 1 -- --test-threads=1`
  - **322 passed, 0 failed, 0 ignored** across the unit suite and every integration test binary.
- `upload_flow_test` (5/5):
  - `upload_routes_require_admin_and_ignore_query_pins`
  - `chunk_flow_enforces_offsets_limits_and_completes`
  - `abort_removes_temp_files`
  - `single_file_compatibility_route_writes_and_indexes`
  - `upload_init_keeps_the_default_json_body_limit`
- `upload_service` unit tests (4/4): sanitization/extension refusal, title/year parsing, title
  override preserving one extension, unique-name incrementing.
- Build note: the full suite must compile with `-j 1` on this host. Parallel linking exhausted
  the Windows commit limit and produced misleading “invalid metadata”/ICE output. Serial
  compilation succeeded and the run above is the complete suite.

### Web

- `npm run test`: **42 files, 306 tests, all passing**.
- `npm run build`: passes.
- `npm run lint`: exits 0. The remaining output is warnings, including pre-existing
  `set-state-in-effect` warnings and one new warning in `MediaUploadModal.tsx` for the
  open/close reset effect; it is not a lint failure.
- `uploadApi.test.ts` (6/6): PIN header and title trimming, no invented PIN, 403 mapping,
  extension allowlist, chunk offset/acknowledgement, 409 `current_offset` recovery.

### Live probe

`scripts/probe_upload.py` checks the running service:

- unauthenticated `init` → `403` (proves the route exists and is gated, not a 404),
- `init` with a PIN in the query string → `403`,
- with `MEDIA_SERVER_ADMIN_PIN` set: init → append 4 bytes → status → abort → status `404`.

It never completes an upload, so it creates no media file and no catalog row. The PIN is read
from the environment only and is never printed.

**Live result (2026-10-22, against `127.0.0.1:8000`):** all seven checks pass and the probe exits
`0`. The first authorized run failed at the append with `400 Chunk extends past the declared
upload size`; the fixture, not the server, was wrong — the probe declared `size: 4` but sent the
5-byte literal `b"probe"`. The server correctly rejected it. The fixture is now `b"test"` (4
bytes), and the re-run records the offset, aborts, and confirms the session is gone. This is worth
keeping in view: the size guard is enforced on the **raw byte count**, not on a client-supplied
length.

The unauthenticated run was exercised separately and also exits `0`, reporting the two `403`s and
skipping the authorized path.

`python scripts/probe_android_api.py` was also run against the same service: **22/22 endpoints
respond per contract**, exit `0`. That includes the unchanged `/api/*` shapes used by the Flutter
client and the deliberate `400` for an idle cast status.

## 7. Contract and documentation

- `docs/openapi.yaml` now documents the Admin PIN header, `403`/`413`/`415` responses, the
  `ChunkAppendResponse` shape, the `409` `current_offset` recovery, the single-file 256 MiB cap,
  the 20 GiB total, and the corrected `400` (not `409`) for an incomplete finalize.
- `docs/MANUAL.md` describes the library-page button, admin gate, limits, overwrite behavior,
  abort, and header-only PIN handling.

## 8. Deployment

> **The running service holds `media-server-api.exe` open.** A release build cannot replace it
> in place — Cargo fails with `Access is denied (os error 5)` at the final link. The service must
> be stopped first. `scripts/restart_rust_service.bat` does the whole sequence: stop, wait for the
> binary to be released, rebuild, refresh the NSSM environment, start, and probe `/` and
> `/api/movies`.

1. Rebuild the release binary:
   `cargo build --manifest-path rust/Cargo.toml --release`
2. Build the SPA if `web/dist` is not current: `cd web; npm run build`
3. Restart the service: `e:\MediaServer\scripts\restart_rust_service.bat`
4. Verify the binary is newer than the last source commit, not just that `/health` answers:
   `Get-Item rust\target\release\media-server-api.exe | Select LastWriteTime`
5. Run the probes:
   - `python scripts/probe_upload.py`
   - `$env:MEDIA_SERVER_ADMIN_PIN = '<pin>'; python scripts/probe_upload.py`
   - `python scripts/probe_android_api.py`
6. In the browser, sign in as admin or enter the PIN, upload a small file, and confirm the
   details page and library refresh.

**Executed on 2026-10-22.** The service was restarted at **14:53:48 IST** with the rebuilt
binary. Evidence:

- `MediaServerRust`: `RUNNING`; `/health` → `{"engine":"rust","service":"media-server-api",
  "status":"healthy","version":"0.1.0"}`.
- `rust\target\release\media-server-api.exe`: **14:53:48**, 14,620,672 bytes. This is newer than
  the last commit (`ef010dd`, 12:44:17) and newer than the newest upload source file
  (`upload_service.rs`, 14:07:13).
- `/api/admin/status` → `{"is_admin":false,"has_pin":true,"user":null}`. The PIN itself was read
  from PostgreSQL into the probe's environment and was never printed.
- `scripts/probe_upload.py` unauthenticated → exit `0`; authorized → exit `0`, 7/7 checks.
- `scripts/probe_android_api.py` → exit `0`, 22/22.
- `D:\Flicks\.uploads` contains **0 entries** after the aborted probes; no `probe_upload_*` file
  exists under `D:\Flicks`.
- `web/dist/assets` was built at **14:41:59** and the bundle contains the upload UI strings, so the
  service is serving the React build that includes the feature.

Step 6 was exercised as far as the gate: the live SPA was opened at `http://127.0.0.1:8000/`, the
**Upload Media** button rendered, and clicking it opened the **Unlock Admin Mode** dialog with the
4-digit PIN field and Cancel/Unlock controls. The dialog was cancelled without entering a PIN, so
no file was selected, no bytes were transferred, and no catalog row was created. The actual file
transfer remains the final optional check; it should be done with a disposable file and then
removed from the library, so it does not leave a catalog row.

## 9. Known limitations

- The browser does not persist an `upload_id` across a page reload, so a tab closed mid-upload
  cannot resume in a new tab. The server-side offset and 24-hour cleanup still make a future
  resume UI possible.
- Abort intentionally fires the `DELETE` without waiting; if the tab is closed immediately the
  request may not reach the server, leaving the session for the 24-hour sweep.
- The single-file compatibility route stages directly in the target directory (`.upload_*.part`)
  and is not resumable. The React client always uses the chunked route.
- There is no per-user quota, malware scan, or content-type inspection; the extension allowlist
  and admin gate are the current controls.
- `cleanup_stale` runs at `init`, not on a timer. A server that never receives another init will
  keep stale sessions until the next one.

## 10. Related

- [`NETWORK_BENCHMARK_2026-10-22.md`](NETWORK_BENCHMARK_2026-10-22.md) — line capacity, Caddy,
  and the Axum 2 MB finding that motivated per-route limits.
- [`openapi.yaml`](openapi.yaml) — the upload contract.
- [`MANUAL.md`](MANUAL.md) — user-facing upload flow.
- `Handoffs/2026-10-22_13-50_opencode_network-benchmark-and-upload-port.md` — the original
  benchmark and port handoff.
