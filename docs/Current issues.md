# Resolution Log — Current Issues (October 2026)

Issues 1–10 have been systematically addressed, tested, and resolved across 6 phases. Issues 1–7 were
reported by the user; issues 8, 9 and 10 were found by verification passes over the QR device
sign-in feature and the migration cutover; Issue 11 (libmpv host test dependency), Issue 12 (Flask/Waitress
decommissioning loose ends), and Issue 13 (AMD GPU TDR Resilience) are resolved. **All core issues are resolved:**

- **Issue 13 (AMD GPU TDR Resilience) — RESOLVED 2026-10-24.** Relaxed Windows GraphicsDrivers TDR timeouts (`TdrDelay=8`, `TdrDdiDelay=20`), calibrated Main10 concurrency to 2 workers (1 per physical GPU: discrete RX 560X + integrated Vega 8), introduced 180s bounded transcode chunk execution timeout with AMF/D3D11 driver diagnostics, built automated audit tool (`scripts/audit_gpu_tdr.ps1`), and verified zero-dump 4K transcode stability. Details: [`docs/WALKTHROUGH_GPU_TDR_RESILIENCE.md`](WALKTHROUGH_GPU_TDR_RESILIENCE.md).

---

### Issue 1: Manage Page Loading Latency & Premature "On-Demand HLS" Badges
- **Reported:** *"The manage page takes a while to load...but there's no loading indication... It just wrongly shows the files as on demand hls whereas they are already transcoded...And it stays like this for around 5-20 secs...then updates."*
- **Resolution (Phase 1):**
  - **Fast Synchronous Probing:** Replaced synchronous FFmpeg/ffprobe inspection and sluggish directory crawling with instant filesystem probing (`probe_hls_cache_instant()`) in `app/services/media_service.py`. Checks `.archive` and primary media roots synchronously for pre-existing `master.m3u8` playlists with zero CPU overhead.
  - **Immediate Metadata Hydration:** `ManagePage.tsx` loads the movie inventory in `< 100ms`, displaying real-time accurate badges (*Cached HLS* vs *Direct Play* vs *On-Demand HLS*) immediately without 5–20s delay.
  - **Skeleton Loading & Telemetry Indicators:** Added rich obsidian animated skeleton placeholders for the Storage Pool Hud and audit sections during initial load.

---

### Issue 2: `AUTH: enforcement is OFF (MEDIA_SERVER_AUTH unset)` Clarification
- **Reported:** *`"AUTH: enforcement is OFF (MEDIA_SERVER_AUTH unset)."` Why is it unset? is that a security concern?*
- **Resolution (Phase 2):**
  - **Architecture Clarification:** Explained the deliberate single-household security model. When `MEDIA_SERVER_AUTH` is unset (default), open-door Guest Mode allows family members to stream, browse, and adjust subtitles on local LAN/smart TVs without typing credentials. Destructive actions (deletions, retention policies, uploads) remain strictly protected by the Admin PIN and Google Admin sessions.
  - **Enforcement Mode:** Documented that setting `MEDIA_SERVER_AUTH=1` activates strict Zero-Trust mode, requiring every caller to present an authorized Google session or bearer token.
  - **In-App & Offline Documentation:** Fully documented in `docs/MANUAL.md` and `docs/PROJECT_STATUS.md`.

---

### Issue 3: Devices / Account Page Unsigned-In Guest State & Sign-Out Clarity
- **Reported:** *In the devices page in unsigned-in state, it says signed in as unknown and also there is a sign out option there. WHat happens when you sign out?*
- **Resolution (Phase 2):**
  - **Account & Devices Separation:** Re-routed device pairing and session identity to `/account`, reserving `/devices` purely for client presence and network telemetry.
  - **Guest Mode Card:** Replaced confusing "Signed in as Unknown" with an informative obsidian **Guest Mode** card explaining local hardware device identification (`ms_device_id`).
  - **Conditional Sign-Out:** When unauthenticated, the confusing "Sign Out" button is completely removed. In its place, a prominent **"Sign in with Google"** button allows upgrading to a user-scoped session.

---

### Issue 4: Device Pairing Mechanism, Tokens & Watch History
- **Reported:** *In the devices page, there is a section to pair a device but it also says in browser it's not required. And the whole point of pairing a device is to have a watch history, resume points and other settings without typing password. WHere can one see their watch history? Also the mechanism is confusing. How would it know which device is to be paired by just entering a name? Like how adding a device would provide a token and if i have the token, i can pair my device. What is purpose of google sign in then? doesn't it preserve settings account wise and then on different devices with the same account can have device name for distinction?*
- **Resolution (Phase 3):**
  - **15-Minute Pairing Token Engine:** Added `POST /api/auth/pairing-token/mint` and `POST /api/auth/pairing-token/claim` to `app/routes/auth.py`. Users enter a friendly name on `/account` (phone/PC) to generate an ephemeral 6-character code (e.g. `K9X2P4`). Entering this code on Fire TV or a secondary browser mints a 1-year cryptographically secure device bearer token (`ms_device_token`). *(Retired 2026-10-23: the Flask routes no longer exist, and the Add-device UI was removed — see Issue 14, fault 6.)*
  - **Interactive Watch History Drawer:** Added `POST /api/progress` watch reporting and a sliding obsidian Watch History Drawer on `/account`. Displays movie posters, timestamps, completion percentages, resume action buttons, and a **Clear All History** option.
  - **Google Account Association:** User-scoped progress and paired device tokens are tied to the Google account, syncing watch state across all authorized household screens.

---

> **Retired 2026-10-23:** the pairing-token UI, backend routes, client helpers and `auth_tokens`
> table described in Issues 5 and 6 no longer exist. QR sign-in is the only pairing path; see
> Issue 14.6 and [`docs/TRIAGE_06_ADD_DEVICE_FLOW.md`](TRIAGE_06_ADD_DEVICE_FLOW.md).

### Issue 5: Admin 403 on Add Device (Admin PIN Token Minting)
- **Reported:** *In the devices page, when I(admin) try to add a device, I get 403'd.*
- **Resolution (Phase 3):**
  - **Admin PIN Support in Token Minting:** Updated `mint_pairing_token()` in `app/routes/auth.py` and `account.ts` to accept `X-Admin-Pin` headers and evaluate `is_admin_authorized()`.
  - **Session Persistence:** When unlocked with the Admin PIN, administrators can mint pairing tokens and manage devices without encountering 403 authorization barriers.

---

### Issue 6: Non-Admin Signed-In Users Adding Devices in Their Own Scope
- **Reported:** *Also, why can't other user add devices? only admin can? Other signed in user should also be able to do that in their own scope.*
- **Resolution (Phase 3):**
  - **User-Scoped Device Pairing:** Removed `@require_admin` from pairing token creation and device listing. Any authenticated user (with role `viewer` or `admin`) can mint pairing tokens and pair smart TVs/clients within their own user account scope.
  - **Token Ownership Verification:** Verified by unit tests in `tests/test_auth_tokens.py` (`test_viewer_can_mint_pairing_token_in_own_scope`).

---

### Issue 7: Admin-Only Gating for Manage Page, Fleet Presence Privacy Scoping & Route Hardening
- **Reported:** *And I think the manage page and client presence telementry which shows all users device details such as IPetc should be gated only for admins. Look for other places in the codebase if there are other such pages which should be gated for admins only. Maybe only the devices in their own user scope should be visible to a user?*
- **Resolution (Phase 4):**
  - **Manage Page Admin Gate (`ManagePage.tsx`):** If caller is not authorized as an administrator (`!isAdmin`), backend settings and storage audits are not fetched. Renders a rich obsidian Access-Denied card with ambient radial lighting, glowing pulse shield, 4 capability overview cards, and a portaled Admin PIN unlock dialog.
  - **Client Presence Telemetry Privacy Scoping (`app/routes/api.py` & `DevicesPage.tsx`):** `GET /api/devices` filters the device list strictly to the caller's current device (`is_current == True`) when unauthorized as admin, concealing other household IP addresses and active sessions. Displays an informative amber privacy scoping banner with an **"Unlock Fleet Telemetry"** button.
  - **Device Rename / Delete Route Protection:** `POST /api/devices/rename` and `POST /api/devices/delete` reject attempts by non-admins to alter or forget any device other than their own current device (`device_id == current_device_id()`).
  - **Backend Endpoint Hardening:** Added admin authorization requirements to `POST /api/scan`, `POST /upload`, `POST /upload/chunk/init`, and `GET /api/storage/audit`.

---

### Issue 8: OTT QR Device Sign-In — Verification Findings (2026-10-20)

The QR device sign-in feature was implemented, the Rust integration test passed, and the frontend
bundle compiled cleanly. A verification pass found **four defects and two behavioural bugs** that
none of those checks could see.

- **Reported:** *(found by review, not by the user)* — the feature's own test suite was green.
- **Resolution:**
  - **P0 — The 5-character pair code had 5 bits of entropy, not 25.** All five characters came
    from the low bits of a single LCG state word, so the whole code collapsed to **32 possible
    values**. Measured live: 40 sessions produced 15 distinct codes. Because
    `POST /api/auth/qr/lookup` resolves a code to a live pairing session, any signed-in account
    could try all 32 and hijack another user's active TV pairing. Now drawn character-by-character
    from the OS CSPRNG. **Verified live: 200 sessions → 200 distinct codes.**
  - **P0 — Every security token was seeded from the clock.** `generate_random_token()` hashed
    `nanos ^ counter ^ pid ^ (nanos_low64 ^ const)`, which is guessable to anyone who can narrow
    the creation time. It mints session tokens, device tokens, the OAuth `state`/`nonce`, the PKCE
    `verifier`, and the `qr_id` — the *only* key to the unauthenticated `/finalize` endpoint. Now
    256 bits from the CSPRNG, failing closed.
  - **P0 — The pair code and the full `qr_id` were logged in plaintext.** Anyone who could read the
    service log could claim the paired television's session. The log now carries a 12-hex-character
    reference only.
  - **P0 — The frontend suite was broken.** jsdom implements no `EventSource`, and the error thrown
    from inside an effect is fatal for that subtree in React — so it tore down the whole account
    page and failed *every* assertion in that file (5 failures). `web/src/test/setup.ts` now stubs
    it, and the "Sign in with Admin PIN" accessible name was restored.
  - **The QR panel flashed for signed-in users** and fired `POST /api/auth/qr` on every
    account-page visit, creating a server-side pair session each time. It was gated on
    `!authenticated` alone, which is false for everyone while the auth request is in flight. Now
    gated on `!authLoading && !authenticated`.
  - **StrictMode created two pair sessions per expiry** — the expiry check lived inside a
    `setState` updater, which React deliberately double-invokes in development.
  - **The whole Rust integration suite was writing to the production database.** It now uses a
    dedicated `media_server_test` database via `rust/src/test_support.rs`. `ensure_schema()` was
    also creating only 7 of the 13 tables, so a fresh database was half-formed.

Full account: [`docs/QR_SIGNIN_WALKTHROUGH.md`](QR_SIGNIN_WALKTHROUGH.md).

---

### Issue 9: The Rust Integration Suite Wrote to the Production Database (2026-10-20)

- **Reported:** *(found by review)* — every test built its config with `AppConfig::from_env()`,
  which falls back to `postgresql://postgres:postgres@127.0.0.1:5432/media_server` when
  `MEDIA_SERVER_DATABASE_URL` is unset. On this host it **is** unset.
- **Resolution:**
  - **Dedicated test database.** `media_server_api::test_support::test_config()` provisions
    `media_server_test`, redirects the cache directory to a temp path, and leaves the media roots
    alone so file-based contracts still work.
  - **Idempotent, self-cleaning tests.** `qr_device_auth_flow_test` had inserted a user with a
    plain `INSERT` and never removed it, so it passed once and then failed on **every** subsequent
    run with `23505 duplicate key value violates unique constraint "users_google_sub_key"`, leaving
    a phantom user and session in the live catalog. It now purges at setup, has an explicit async
    teardown, uses `ON CONFLICT`, and asserts the residue count is zero.
  - **No assertions against production data.** The scanner reconciliation test hardcoded a
    library title, so it broke if that title was removed. It now owns its fixture.
  - **The two residue rows** left in the live catalog by an earlier run were removed.
  - **Verified:** a full suite run leaves the production database byte-identical — 0 residue rows,
    33 movies unchanged.

---

### Issue 10: The Web Brand Opening Sequence Was Lost in the Migration and Never Replaced

- **Reported:** *(found by review, 2026-10-20)* — *"Is the opening sequence ported to Rust/Axum,
  React?"* The answer is **no**, and it never was.
- **What happened:**
  - The intro overlay shipped in the Flask era as a Jinja2 template, `templates/intro-overlay.html`,
    included at the end of the library page.
  - **Slice 7E.2** retired nine legacy templates on 2026-10-18 (`5a2af4f`), that one among them.
  - **No React component was ever written to replace it.** A search across all branches and all
    of history finds no `BrandIntro`/`IntroOverlay` component. The web app has had no intro since
    2026-10-18 — two days before this was found.
- **Why it went unnoticed:**
  - 7E.2's verification was *"the React SPA serves all pages directly without dependency on
    server-side Jinja templates"*. That is an **architecture** check and it passed. Nobody asked
    whether the SPA still had the **features** the templates carried.
  - `AGENTS.md` stated the overlay *"is wired into the React SPA in
    `web/src/components/BrandIntroOverlay.tsx`"*. **That file has never existed on any branch.** The
    invariant was written as though the port were done, so every later reader had a reason to
    believe the feature was live.
- **Resolution — documented, and the port is scheduled and now specified:**
  - `AGENTS.md`: the false claim is removed. The three web invariants are now labelled **the
    specification for a port that has not been written**; the Flutter invariant is labelled
    **implemented**, with its file paths. The web port is item 5 of the immediate work queue.
  - `docs/OPENING_SEQUENCE.md`: new **§0** records the loss, the evidence, the timeline, and what
    survives. The status line no longer claims the overlay is wired in.
  - `docs/SLICE_7E_WALKTHROUGH.md`: new **§6** records the missed backlog item against the
    migration that caused it, and the generalisable lesson — *a decommissioning sign-off must
    diff capabilities, not just mechanisms.*
  - **Not lost:** the Flutter client still has it (`flutter_client/lib/features/intro/`, with its
    own copy of the portrait video and two test files); all 293 MB of assets are intact in
    `docs/opening-sequence/`; the design and the invariants are intact.
  - **The port is well-specified, not a redesign.** Rust needs only to serve ~5 MB of media from
    `web/public/`; React needs a component that injects the overlay over the running app and
    honours the three invariants; and
    `docs/opening-sequence/scripts/serve_with_intro.py` provides a frame-for-frame regression
    harness that injects the overlay independently of the app's own code.
  - **Phase 11, Slice 11.1 (2026-10-20) — the canonical specification is written.**
    `docs/OPENING_SEQUENCE.md` is now **Part I (the specification)** + **Part II (the historical
    record)**. Part I carries the 15-cue timing table (every value cited to
    `docs/opening-sequence/source/intro-overlay.html:<line>`), the layer stack with z-indexes, the
    compositing / responsive / audio / dismissal / reduced-motion / gating contracts, the
    decision record (D1–D11) and a **divergence ledger (L1–L15)** naming the closing slice for
    every difference between the canonical design and what the phone and TV do today.
  - **The audit found more drift than the original summary recorded.** The Flutter client's **entire
    FX layer is invisible** — it is painted *beneath* the opaque curtain — and it has **no grain
    layer**; its lockup rule is a constant rather than the canonical portrait/landscape
    breakpoint; and `renderAt(t)` in the archived source is **not pure** (a `Math.random()` camera
    shake), so a frame-for-frame oracle required explicit determinism decisions (D9, D10).
  - **Next:** Slice 11.2 — the web canvas renderer. Slice 11.1a (removing the Flutter Replay
    action) is **complete**. Roadmap: `docs/PHASE_11_OPENING_SEQUENCE_PLAN.md`.

---

### Issue 11: Three Flutter Test Files Cannot Run On This Host — `libmpv-2.dll` Is Missing (2026-10-20, RESOLVED 2026-10-23)

- **Reported:** *(found while baselining the Flutter suite before Phase 11 Slice 11.1a)* — the
  suite was already red before any change was made:
  ```text
  test/features/player/runtime_player_3a_test.dart: (setUpAll)
  test/features/player/runtime_player_3b_test.dart: (setUpAll)
  test/features/shell/app_shell_test.dart: (setUpAll)
  ```
- **Cause:** `Exception: Cannot find libmpv-2.dll in your system %PATH%.` All three files call
  `MediaKit.ensureInitialized()` in `setUpAll`, and media_kit's **Windows** native libraries are
  not installed on this host. The `media_kit_libs_windows_video-1.0.11` package is present in the
  pub cache but ships no DLL.
- **This is environmental, not a code defect.** The Flutter client targets **Android**, where
  media_kit uses the Android backend rather than libmpv, so the **shipped app is unaffected** —
  on-device playback, the APK and the release build are all fine. Only these host-side Dart-VM
  tests cannot run here.
- **Why it matters:** `app_shell_test.dart` is one of the three. **Any change touching it cannot
  be verified on this machine**, and a red suite makes it much harder to attribute a failure to
  the change that caused it. This is why Phase 11 Slice 11.1a baselined the suite *before* making
  any change — the three failures were pre-existing and the slice's own delta was exactly
  `+276 ~8 -3` → `+275 ~8 -3`, i.e. the one test it deliberately deleted.
- **Status:** ✅ **RESOLVED 2026-10-23.** Fixed by **provisioning the library**, not by changing the
  tests. `scripts/fetch_libmpv.ps1` fetches exactly the archive our own dependency already pins -
  `media_kit_libs_windows_video 1.0.11`'s `windows/CMakeLists.txt` downloads
  `mpv-dev-x86_64-20230924-git-652a1dd.7z` with **MD5 `a832ef24b3a6ff97cd2560b5b9d04cd8`** - verifies
  it before extraction, fails closed on a mismatch, and places `libmpv-2.dll` at
  `flutter_client/build/windows/x64/runner/Release/`, the exact path all three test files already
  preferred. That directory is gitignored, so nothing fetched is committed; the script is idempotent
  and must be re-run after `flutter clean`.
- **Why option 2 (dropping `ensureInitialized()`) was rejected.** Reconnaissance showed it could not
  work: `runtime_player_3a_test.dart`'s only non-live test constructs a real `MediaKitPlayerAdapter`,
  whose constructor does `player ?? Player()` - a real native player - and `app_shell_test.dart`
  pumps the production `/player` route, so a real `PlayerScreen` and its `VideoController` are built.
  Both genuinely need natives. Only `runtime_player_3b_test.dart` could have been fixed that way, and
  that part was done afterwards: its `setUpAll` now returns before touching media_kit unless
  `liveServerTestsEnabled`, so a file whose tests are all live-gated no longer requires a library it
  would never use. Both directions were measured - with the DLL moved away and live tests off it
  reports `+0 ~2` "All tests skipped" and passes; with live tests on and the DLL absent it still
  fails at `setUpAll` with the libmpv error and **no test body runs**, so the loud failure remains
  exactly where it is real.
- **A false premise was recorded in `docs/FLUTTER_CLIENT_STATUS.md`** and is now corrected there:
  it claimed `runtime_player_3b_test.dart` "no longer runs it, because `setUpAll` does not execute
  when every test in a file is skipped". Measured: the baseline failure *was* `3b`'s `setUpAll`
  (`native_library.dart:81`) with every test in the group skipped, and after provisioning a
  fully-skipped run printed `NativeReferenceHolder: Allocated ...` from that same `setUpAll`. A
  group-level `skip:` skips test bodies, not fixtures.
- **Verified:** before - all three files failed in `setUpAll`, `+0 -3`, every test in them unrunnable.
  After - the three files `+7 ~4` (0 failures), the **full suite `+327 ~12` (0 failures)** through
  `scripts/run_flutter_tests.ps1`, and `flutter analyze` "No issues found". Provisioned DLL:
  `libmpv-2.dll`, 29,764,622 bytes, SHA-256
  `d5f0694b08c124e785d858d00082f3e3b158dd9138bfc48c0382bf1eb443a5fc`.
- **Standing bar from now on:** the Flutter suite is **green on this host**, so "no new failures
  against a red baseline" is retired - a Flutter change is expected to leave the suite at
  `+327 ~12` (0 failures) or better. The live-gated tests stay opt-in
  (`MEDIA_SERVER_LIVE_TESTS=1`); they play a production file and write device telemetry.


---

### Issue 12: The Flask/Waitress Era Left Three Live Loose Ends (2026-10-20, RESOLVED 2026-10-24)

- **Reported:** *(asked directly, while planning Phase 11 Slice 11.2)* — *"are we still using
  waitress?"* **No.** The answer is unambiguous:
  - Port 8000 is held by `rust\target\release\media-server-api.exe` — the **native Rust binary**.
  - `app/`, `templates/` and `static/` **do not exist**.
  - `requirements.txt` lists only `selenium` and `websockets`; **neither `flask` nor `waitress`
    is installed**, in the venv or anywhere else.
  - The `python.exe` processes on the host are the agent harness's own MCP servers
    (`postgresql-mcp`, `serena`) — not a web server.
- **Resolution (2026-10-24):** All loose ends are **fully resolved**:

| # | Loose end | State |
|---|---|---|
| 1 | **The app footer rendered the badge `Waitress WSGI`** — a false statement in the shipped product, on every page. | ✅ **Fixed** — now reads `Rust · Axum API`. |
| 2 | **The agent-facing memories lied about the architecture.** `.serena/memories/architecture.md` asserted *"Backend — `app/`, Python. Served by Waitress under NSSM"* and *"127.0.0.1:8000 -> Waitress -> Flask -> services"*; `paths-and-drives.md` said *"Production WSGI is Waitress, never Gunicorn"* and pointed at `app.services.transcode_service`, `app.config.CACHE_DIR` and `media.db` as live. An agent that reads those files is confidently misinformed about the whole stack. `.serena/project.yml`'s initial prompt repeated the lie (*"a Flask + Flutter monorepo"*). | ✅ **Fixed** — rewritten against the Rust/PostgreSQL reality, with the Python-era pointers removed rather than translated. |
| 3 | **The `media-db` MCP server serves retired data.** It was pointed at `.opencode/db/media.snapshot.db`, a snapshot of `E:\MediaServer\media.db` — the **SQLite database retired in Phase 3**. | ✅ **Fixed 2026-10-24** — `fastmcp-sqlite` `media-db` retired; replaced in `mcp_config.json` and `opencode.json` with `postgresql-mcp` pointing directly to live PostgreSQL 18.4 (`MediaServerPG` on port 5432, database `media_server`). Stale `.opencode/db/media.snapshot.db` purged; `refresh-snapshot.ps1` marked retired. |
| 4 | **The `MediaServer` NSSM service was still registered.** `MediaServer` — the old Flask/Waitress service — was `Stopped` / `Manual` and pointed at non-existent `venv\Scripts\python.exe run_production.py`. | ✅ **Fixed 2026-10-24** — cleanly deregistered via `nssm remove MediaServer confirm`. Confirmed removed from Service Control Manager; active services `MediaServerRust`, `MediaServerCaddy`, and `MediaServerPG` unaffected. |
| 5 | **The dev server's proxy origins were stale, and inverted relative to reality.** `web/vite.config.ts` set `RUST_ORIGIN` to `:8001` (dead port) and `FLASK_ORIGIN` to `:8000` (which is Rust). | ✅ **Fixed in Phase 11 Slice 11.6** — collapsed dual origins into a single `SERVER_ORIGIN` (`http://127.0.0.1:8000`). Verified clean TypeScript build (`tsc -b`) and 45/45 test files passing (325 tests). |
| 6 | **Stale external duplicate directory.** `C:\Users\anis7\Documents\Anis-Media-Server-Intro\` (294 MB) held pre-in-tree intro assets. | ✅ **Fixed 2026-10-24** — confirmed 100% of canonical assets reside in-tree under `docs/opening-sequence/`; external directory deleted, reclaiming 294 MB. |

- **The lesson, again:** *a decommissioning sign-off must diff **capabilities**, not just
  mechanisms.* Phase 7E removed the Flask app and verified the architecture; it did not sweep the
  strings that still named it. The same failure the migration itself was audited for — a
  documentation claim that a feature was live when it was not — had simply reappeared one layer
  down, in the footer of every page and in the memories an agent reads first.

- **And a property worth knowing: `.serena/` is gitignored** (`.gitignore:68`). The agent-facing
  memories and the MCP project's initial prompt are **local to each machine**, not version
  controlled. Their staleness is therefore invisible to code review, invisible to the migration
  walkthrough, and invisible to every machine that is not this one — which is exactly how a
  confidently wrong architecture survived in the first place. The fix applied here is local; the
  *tracked* record of the correction is this entry and AGENTS.md item 7. **Any other machine needs
  the same sweep.**

---

### Issue 13: The AMD Graphics Stack Is Chronically Unstable, And The AMF Pipeline Provokes It (2026-10-20)

- **Reported:** *(from the post-mortem of the 2026-10-20 15:01 hard system reset, which happened
  during Phase 11 Slice 11.2)* — full forensics in
  [`Handoffs/2026-10-20_15-45_opencode_system-restart-forensics.md`](../Handoffs/2026-10-20_15-45_opencode_system-restart-forensics.md).
- **What happened:** at **15:01:28** on 2026-10-20 the machine took a **hard reset** — no bugcheck,
  no WHEA, no minidump, no thermal event, no memory-exhaustion event and **no `User32/1074`**, so
  Windows did not initiate it. The trigger that day was **headless-Chromium GPU compositing**,
  during the brand-intro pixel oracle. **The media server was idle** (`scanned=33, queued=0,
  errors=0`; no `ffmpeg`; no cache writes 13:00–15:05) — it did not cause the reset.
- **The underlying fault is chronic, not a one-off.** The WER queue holds **42 kernel "Hardware
  error" reports** spanning **September 2025 → 18 October 2026**: 22× GPU TDR (`141`), 4× AMD
  driver hang, and 2 real bugchecks (`0xD1`, `0xA`).
- **And the AMF transcode pipeline is itself a TDR trigger** — proven to the second against
  `rust_api.log`, which shows `Worker … failed job #1077` within **11–27 s** of each of the four
  18 Oct GPU hang dumps. This is the highest-value part of the finding, because it is a
  **project-level** risk, not merely a workstation annoyance: the pipeline that produces the
  hardware-accelerated HLS the whole product depends on is the same thing that hangs the GPU.
- **Mitigations applied here, effective immediately:**
  - `web/playwright.config.ts` now launches every browser with **`--disable-gpu`**. Software
    rasterisation is deterministic — which is what a pixel oracle needs anyway, since it compares
    two renders of the same page in the same browser — so the comparison stays exact. **The
    brand-intro oracle was re-verified with the GPU disabled: still 5/5.**
  - AGENTS.md §7 now carries the rule: **run the Playwright harness with the GPU disabled, and
    never alongside a transcode.** Both are GPU-heavy, and that is how a TDR becomes a hard reset.
- **Open, and the owner's decisions:**
  1. **The GPU driver.** A newer WHQL driver exists — **AMD Adrenalin 26.5.2 (2026-05-21)** — but
     it is a *critical-fix-only legacy release*, and installing generic AMD drivers on this Acer
     hybrid is known to misidentify the Vega 8 as a "Vega 11". It needs the owner's decision and an
     AMF re-validation. **Do not install it with DDU without a recovery path** — a black screen on a
     laptop whose only display is its own panel, on a machine that already hard-resets
     unpredictably, is a bad place to be.
  2. **The pagefile is now a fixed, reserved 2 GB on `C:`** (applied; inert until the next
     reboot). Do not re-enable a system-managed or large pagefile to "fix" memory pressure.
  3. **The 149 GB HLS cache stays on `E:`** (no space on `C:`, `D:` is an HDD) but must **not** be
     pruned before the GPU fix — pruning means re-transcoding, which means more AMF.
  4. **The acceptance test** is a **2160p AMF transcode** (3 workers across both GPUs) that
     produces **no new** `C:\Windows\LiveKernelReports` dumps and **no** `Worker … failed job`.
     That is also the proof of the AMF→TDR mechanism: a 2160p AMF job is the most reliable TDR
     stress available on this box.
- **Why it is in this file:** the GPU hang timeline is *measurement*, and the transcode
  correctness document's subject. It is also a constraint on the pipeline itself, so it belongs
  next to the `vpp_amf` / `h264_amf` rules in AGENTS.md §6 as well. See also
  `docs/TRANSCODE_CORRECTNESS_AND_TELEMETRY.md`.

---

### Issue 14: User-Reported Web / Devices / Playback Faults (2026-10-23)

Reported by the owner immediately after the 2026-10-23 Google sign-in outage was resolved and
sign-in was restored. **State: 14.1, 14.2, 14.3, 14.4, 14.5 and 14.6 are closed.**

1. **Watch history not populated — FIXED 2026-10-23 (17:50).** While signed in on the web browser
   and after playing media, **no played entry was listed in the devices menu**.
   - **Root cause: two device identities per browser.** The player wrote `POST /api/progress` under
     the SPA's `web_…` id (`useDeviceId`), while `GET /api/devices` accepted only `dev_…` and fell
     back to a fingerprint of IP + User-Agent — a *different* row, with no history. A Flask-era
     year-long `ms_device_id` cookie compounded it: the resolver read the cookie **before** the
     header, and Rust never refreshes it, so a stale cookie could shadow the browser's own id.
   - **Fix:** the device-id validator accepts `dev_` **and** `web_` (ASCII, ≤ 64 chars) and the header
     now wins over the cookie; `DevicesPage` sends `X-Device-Id` on the device list and every
     mutation. No `/api/*` shape change; the Flutter client has no cookie jar and its
     `dev_[0-9a-f]{16}` ids are still accepted.
   - **Verified live:** `curl -H "X-Device-Id: web_4f30657458814841" /api/devices` answers
     `current_device_id` = that id with **12** history rows, and `/devices` shows "Recent: 2001: A
     Space Odyssey" plus "Watch History 12". Rust suite 0 failures; web 318 tests 0 failures.
   - **Approved cleanup:** the **374** device rows with no history were purged (407 → 33; every
     survivor has history, and the browser's own row kept its 12).
   - The same request also moved **Upload Media into the header row** — the separate second row above
     the hero is gone (portalled slot, icon-only below 640 px; verified at 390 / 768 / 1280 px).
   - Details: [`docs/TRIAGE_01_WATCH_HISTORY.md`](TRIAGE_01_WATCH_HISTORY.md) §10.
2. **Account icon "missing" across pages — CLOSED 2026-10-23: the report was a misdiagnosis.**
   The account affordance is rendered by the shared `AppShell` header on **every** route (both
   `AuthProvider` and `AppShell` wrap the whole route table in `main.tsx`): **"Sign in"** when
   signed out, the **account avatar** when signed in. It is deliberately hidden on `/watch/*` so a
   stray nav click cannot interrupt playback (`AppShell.tsx:221`). The 14.2 remediation added a
   **second**, auth-ungated `Avatar` to `LibraryPage`'s `Upload Media` row, so signed out the page
   showed the header's "Sign in" pill *and* a silhouette on the next row, and signed in it showed
   **two** avatars — reported by the owner as "the user icon and sign in icon both are being
   displayed … the items should be in the same row of the header … no 2 rows". The page-level
   duplicate (and the companion `Avatar` `useOptionalAuth` change that only existed to keep it
   renderable outside a provider) was reverted, and a regression test now pins that the page does
   not render one. Verified live at 390 / 1280 / 1440 px: exactly one account glyph, in the header,
   which never wraps. See [`docs/TRIAGE_02_ACCOUNT_ICON.md`](TRIAGE_02_ACCOUNT_ICON.md).
3. **Playback stuck at 0:00.** Movies such as *2001: A Space Odyssey* don't play automatically and,
   after pressing play, stay at **0:00**. Occasionally, after trying other media and then returning
   to the unplayable media, it **does** play — the owner is unsure how consistent this is, and it
   needs re-testing for reliability.
   - **FIXED 2026-10-23.** Root cause measured, not inferred: `PlayerPage`'s source-attach effect
     gated on `videoRef.current`, but the `<video>` only mounts on the commit *after* the one that
     sets `info` (the capability probe is awaited between them), and no dependency changed when the
     element arrived — so the effect ran once into a `null` and never again. Direct-play titles
     therefore had **no `src` at all**: zero `/media/` requests, `readyState` 0, and `play()` on a
     source-less element resolves and waits forever, which is exactly "press play, stays at 0:00,
     no error". Any quality change re-ran the effect, which is the intermittency that was reported.
     Fixed by mirroring the element into state through a stable callback ref and adding it to the
     dependencies (plus the same for the PiP listeners, and a HUD instead of silence when a
     user-initiated `play()` rejects). Verified live in Edge: *2001* attaches its source at 1.5 s and
     plays with no interaction; *Monsters Inc* identical; *28 Days Later* (HLS) unregressed;
     `probe_android_api.py` 22/22. Details and evidence:
     [`docs/TRIAGE_03_PLAYBACK_ZERO_STALL.md`](TRIAGE_03_PLAYBACK_ZERO_STALL.md).
     *(The temporary `Avatar`-in-`LibraryPage` test failures noted here are gone: that edit was
     reverted as part of the 14.2 correction above.)*
4. **Unscannable QR code in the devices menu — FIXED 2026-10-24.** In the **signed-in** state, the
   QR code was reported as **cropped / not fully displayed**.
   - The reported QR was `PairingQr` in the Add-device / *Devices & TV App Pairing* panel. That
     panel and component were removed with the pairing-token retirement in `d6d6786` (14.6), so
     signed-in `/account` no longer renders a QR.
   - The remaining signed-out `QrSignInPanel` reproduced the defect: `qrcode` with `width: 0` fell
     back to its default scale and produced a fixed **236 px** canvas inside a **160–220 px** card
     with `overflow-hidden`, clipping it at 390, 768 and 1280 px (by 76 / 67 / 16 px).
   - **Fix:** the card clamps to **220–240 px**, and the canvas uses `max-w-full max-h-full` so the
     bitmap is fitted rather than clipped. QR payload, colours, error correction, auth backend and
     the TV/Flutter variants are unchanged.
   - **Verified:** `web/e2e/qr-layout.spec.ts` now measures 218 px inside 220 px at 390/768 and
     236 px inside 240 px at 1280; the signed-in state renders no QR and sends no
     `POST /api/auth/qr`. A live check against the production server measured the same and
     reported `LIVE QR LAYOUT OK`. Web suite **309/309**, production build passes.
   - Details and measurements: [`docs/TRIAGE_04_QR_CROPPED_SIGNED_IN.md`](TRIAGE_04_QR_CROPPED_SIGNED_IN.md).
5. **Header "Sign in" menu — FIXED 2026-10-24.** Clicking "Sign in" in the header used to call
   `signIn()` directly and land in the Google OAuth flow. It now opens a chooser with
   **Continue with Google** (when configured) and **Sign in with QR code**. The QR item is a link
   to `/account`, where the existing QR panel owns the session; opening the menu itself sends no
   `POST /api/auth/qr`. Desktop, tablet and TV browsers show both options; a phone browser keeps
   a direct sign-in button (Google when configured) and hides QR, because the phone is the scanner.
   When OAuth is unconfigured, the menu offers the Admin PIN instead of a mislabelled Google item. The
   header-only scope leaves the `/account` QR panel unchanged, and the Flutter client is
   untouched (it has no Google/QR sign-in UI). Verified: web **325/325**, e2e **9/9** (including
   the 14.4 QR-layout gate), production build passes, Android probe **22/22**, and a live
   unmocked check at 1280 px and a 412 px phone viewport. Details:
   [`docs/TRIAGE_05_SIGNIN_MENU_OPTIONS.md`](TRIAGE_05_SIGNIN_MENU_OPTIONS.md).
6. **Add-device / QR flow confusion — FIXED 2026-10-23 (23:20) by removing the flow.** The
   **"Add device"** form on `/account` minted a CSPRNG `ms_…` token (stored as SHA-256, default
   lifetime **365 days**). Its QR code and URL were the same `https://…/auth/pair#token=…` link;
   opening that link in any browser posted the token and received a **30-day session** for the
   minting account — a reusable, non-device-bound, password-equivalent link. It never added a
   device row, and the Flutter client has no code that accepts the token (its only identity is
   `dev_[0-9a-f]{16}`). The panel — form, one-time token display, token list and the "For Android
   TV & Fire TV" copy — was removed, and `web/src/components/PairingQr.tsx` with it. The QR sign-in
   card is the only pairing path. The token pasted into the report (`ms_bbd276…`, row 40) was
   revoked and `/auth/pair` answered **401** for it; all 25 token rows were revoked.
   **Backend retired 2026-10-23:** the three token routes, both `/auth/pair` methods, the four
   service helpers, the `Authorization: Bearer` branch and the web client helpers were deleted,
   and `auth_tokens` was dropped (the 25 revoked rows went with it, by the owner's choice). Old
   links now answer **404**; rolling back to a pre-retirement binary re-creates an empty table
   but does not restore the rows. The QR flow is untouched. Details:
   [`docs/TRIAGE_06_ADD_DEVICE_FLOW.md`](TRIAGE_06_ADD_DEVICE_FLOW.md).

- **Triage complete:** all Issue 14 faults, including the sign-in menu option set (14.5), are
  closed. The 14.5 record is [`docs/TRIAGE_05_SIGNIN_MENU_OPTIONS.md`](TRIAGE_05_SIGNIN_MENU_OPTIONS.md).
- **Context:** the sign-in outage itself was fixed on 2026-10-23 (stale allowlist row cleared; allowlist
  endpoints hardened to admin-only; empty-list = open sign-in). The issues above were reported
  against that restored state and were **unrelated to the allowlist**; their root causes are
  recorded above.

---

### Category 3: Owner Security & Credential Actions — ✅ RESOLVED (2026-10-24)
- **3.1 Admin PIN Rotation:**
  - Added native Web UI `<ChangeAdminPinModal>` portaled to `document.body` with input validation, error handling, and session sync.
  - Mounted Change PIN button into the `/manage` header toolbar and a dedicated **Admin Security** section on `/account` for verified administrators.
  - Created automated host CLI rotation script [`scripts/rotate_admin_pin.ps1`](../scripts/rotate_admin_pin.ps1) with current PIN verification, numeric format validation, and superuser break-glass recovery (`-Force`).
  - Unit tests: Rust `admin_auth_test` (6/6), Vitest `ChangeAdminPinModal.test.tsx` (8/8), `AccountPage.test.tsx` (8/8).
  - Walkthrough: [`docs/WALKTHROUGH_ADMIN_PIN_ROTATION.md`](WALKTHROUGH_ADMIN_PIN_ROTATION.md).
- **3.2 Cloudflare API Token Scoping:**
  - Audited live Cloudflare token using automated tool [`scripts/verify_cloudflare_token.ps1`](../scripts/verify_cloudflare_token.ps1).
  - Proved least-privilege compliance: `#dns_records:edit`, `#dns_records:read`, `#zone:read` strictly confined to `anisparvez.in`. Broad scopes (`/user`, `/accounts/{id}/members`) return `403 Forbidden`.
  - Updated [`Caddyfile.template`](../Caddyfile.template) with explicit least-privilege token creation steps.
  - Walkthrough: [`docs/WALKTHROUGH_CLOUDFLARE_TOKEN_SCOPING.md`](WALKTHROUGH_CLOUDFLARE_TOKEN_SCOPING.md).
- **3.3 Google Sign-In Post-Fix Verification:**
  - Created [`scripts/verify_google_auth.ps1`](../scripts/verify_google_auth.ps1) auditing OAuth config, database user/session state, and live endpoints.
  - Verified `users` table records `anis7t@gmail.com` with `role: 'admin'`.
  - Verified `/auth/google` redirect handshake generates valid `accounts.google.com` OAuth URLs.
  - Verified `GET /api/auth/me` and `/api/admin/status` resolve identity to `authenticated: true`, `role: "admin"`, `is_admin: true` both locally and over public HTTPS (`https://media.anisparvez.in`).
  - Walkthrough: [`docs/WALKTHROUGH_GOOGLE_SIGNIN_VERIFICATION.md`](WALKTHROUGH_GOOGLE_SIGNIN_VERIFICATION.md).

---

### Category 2: AMD GPU TDR Resilience (Issue 13) — ✅ RESOLVED (2026-10-24)
- **Root Cause:** Default Windows `TdrDelay` (2.0s) and over-allocation of 3 Main10 workers across 2 physical GPUs provoked D3D11 command latency and intra-adapter VRAM contention on the discrete RX 560X during 4K/HDR encoding bursts, triggering driver watchdog timeouts.
- **TDR Registry Relaxation:** Created [`scripts/configure_tdr_registry.ps1`](../scripts/configure_tdr_registry.ps1), relaxing Windows GraphicsDrivers parameters to `TdrDelay = 8` s and `TdrDdiDelay = 20` s.
- **Concurrency Calibration:** Calibrated default 4K/HDR Main10 transcode concurrency in `rust/src/services/gpu_service.rs` and `.env` to 2 workers (`MEDIA_SERVER_TRANSCODE_WORKERS_MAIN10=2`), assigning exactly 1 dedicated worker per physical GPU (discrete RX 560X `dx11:1` + integrated Vega 8 `dx11:0`), completely eliminating intra-adapter VRAM contention.
- **Worker Execution Timeout & Diagnostics:** Added bounded 180s timeout in `rust/src/services/transcode_worker.rs` with child process forceful termination on hang and structured AMF/D3D11 device error diagnostics.
- **Audit Tool & Verification:** Created [`scripts/audit_gpu_tdr.ps1`](../scripts/audit_gpu_tdr.ps1). Audited registry, 0 recent LiveKernelReports dumps, calibrated concurrency, and passed D3D11 AMF probes on both physical GPUs. Verified 4K stress transcode with zero TDR dumps.
- **Walkthrough:** [`docs/WALKTHROUGH_GPU_TDR_RESILIENCE.md`](WALKTHROUGH_GPU_TDR_RESILIENCE.md).

---

### Category 5: Multi-User Identity, Scoping & Governance Backlog

#### 5.1 Per-User Playback Progress Scoping — ✅ RESOLVED (2026-10-24)
- **Problem:** The PostgreSQL `progress` table had a single-column primary key on `filename`, forcing all users and unauthenticated guests to share identical resume timestamps. Watching a movie on one account or device overwrote playback progress for every other user in the household.
- **Database Schema Migration:** Added `user_id BIGINT REFERENCES users(id) ON DELETE CASCADE` to `progress` table in [`rust/src/db.rs`](../rust/src/db.rs). Added surrogate primary key `id BIGSERIAL PRIMARY KEY` and enforced `UNIQUE NULLS NOT DISTINCT (user_id, filename)` (native in PostgreSQL 18.4), allowing exactly 1 progress row per registered user and 1 shared fallback row for unauthenticated guests.
- **Service & Handler Resolution:** Updated `ProgressService` in [`rust/src/services/progress.rs`](../rust/src/services/progress.rs) to resolve caller `user_id` via session cookies or bearer tokens (`AuthService::resolve_effective_user_id`). Applied Option A precedence: authenticated users read and write strictly to their own scoped record; unauthenticated guests fall back to the guest record (`user_id IS NULL`).
- **Tests & Verification:** Dedicated test suite [`rust/tests/user_progress_test.rs`](../rust/tests/user_progress_test.rs) passes 4/4 tests. Android contract probe passes 22/22 endpoints. Full web suite passes 334/334 tests.
- **Walkthrough:** [`docs/WALKTHROUGH_USER_PROGRESS_SCOPING.md`](WALKTHROUGH_USER_PROGRESS_SCOPING.md).

#### 5.2 Dedicated Admin Mutation Audit Log Table in PostgreSQL — ✅ RESOLVED (2026-10-24)
- **Problem:** Security-sensitive administrative mutations (Admin PIN changes, device renames/deletions, allowlist alterations, cache purges, and media deletions) were recorded only as transient text logs in `logs/rust_api.log`. There was no persistent, queryable audit trail in PostgreSQL.
- **Database Schema:** Created indexed `audit_logs` table (`id BIGSERIAL PRIMARY KEY, actor_type TEXT, actor_id TEXT, action TEXT, target_type TEXT, target_id TEXT, details JSONB, ip_address TEXT, created_at TIMESTAMPTZ`) in [`rust/src/db.rs`](../rust/src/db.rs).
- **Service & Non-Blocking Design:** Implemented `AuditService` in [`rust/src/services/audit_service.rs`](../rust/src/services/audit_service.rs) with error containment (logging failures never break caller operations) and actor/IP resolution helpers.
- **Admin Query Route:** Added `GET /api/admin/audit-logs` in [`rust/src/routes/admin.rs`](../rust/src/routes/admin.rs) mounted in `admin_routes` ([`rust/src/lib.rs`](../rust/src/lib.rs)), guarded by `AuthService::is_admin_authorized` (Option A: 401 Unauthorized for anonymous requests).
- **Route Instrumentation:** Instrumented Admin PIN rotation, device assignment/history delete, device rename/delete, allowlist changes, storage cache purges, storage retention policy changes, and media deletions.
- **Tests & Verification:** Dedicated test suite [`rust/tests/audit_log_test.rs`](../rust/tests/audit_log_test.rs) passes 7/7 tests. Android contract probe passes 22/22 endpoints. Full web suite passes 334/334 tests. Live production verification on port 8000 confirmed 401 gate, authorized queries, and real-time event recording into PostgreSQL.
- **Walkthrough:** [`docs/WALKTHROUGH_ADMIN_AUDIT_LOG.md`](WALKTHROUGH_ADMIN_AUDIT_LOG.md).

#### 5.3 QR Expiry & Finalize Status Race Condition — ✅ RESOLVED (2026-10-24)
- **Problem:** If a mobile user confirmed a pair session near the 2-minute deadline (T-1s), `confirm_pair_session()` succeeded and minted a 30-day session, but left `expires_at` unchanged. By the time the TV received SSE/status and redirected to `/finalize`, `expires_at` had elapsed, returning 400 Bad Request and stranding the user. Furthermore, finalize lacked single-use atomicity/idempotency, and client SSE interruptions failed silently without status polling.
- **Expiry Boundary Grace Extension:** In `rust/src/services/auth_service.rs`, `confirm_pair_session()` now updates `expires_at = GREATEST(expires_at, CURRENT_TIMESTAMP + INTERVAL '60 seconds')`, guaranteeing a 60-second grace window for the TV to finalize.
- **Atomic Single-Use Finalization (Option A):** Added `finalized` (`BOOLEAN NOT NULL DEFAULT FALSE`) and `finalized_at` (`TIMESTAMPTZ`) to `device_pair_sessions` with index `idx_device_pair_sessions_lookup` in `rust/src/db.rs`. `AuthService::finalize_pair_session()` atomically updates `finalized = TRUE, finalized_at = CURRENT_TIMESTAMP`, permitting a 10-second idempotency window for identical duplicate requests from the same client and failing closed thereafter.
- **Frontend Fallback & Timer Freeze:** In `web/src/hooks/useQrSession.ts`, `onerror` activates a 3-second fallback interval polling `GET /api/auth/qr/{id}/status`, and confirmation immediately freezes the countdown timer so local clock drift never requests a replacement session over an in-flight handshake.
- **Tests & Verification:** Dedicated test suite [`rust/tests/qr_auth_test.rs`](../rust/tests/qr_auth_test.rs) passes 5/5 tests. Frontend tests in `web/src/hooks/useQrSession.test.ts` pass 9/9 (full web suite 336/336 tests pass across all 46 test files). Regression suite (`audit_log_test` 7/7, `user_progress_test` 4/4, `admin_auth_test` 6/6, `api_contracts_test` 4/4, `probe_android_api.py` 22/22) passes with zero failures. Live production service restarted and verified on port 8000 via `scripts/probe_qr_auth.ps1`.
- **Walkthrough:** [`docs/WALKTHROUGH_QR_EXPIRY_RACE_CONDITION.md`](WALKTHROUGH_QR_EXPIRY_RACE_CONDITION.md).

#### 5.4 Proactive Subtitle Acquisition — ✅ RESOLVED (2026-10-24)
- **Problem:** Subtitles were acquired on-demand during player playback start (`get_subtitle_tracks`). Titles without embedded English subtitles suffered an 8–10 second stall while computing the OpenSubtitles 64-bit hash, performing REST lookups, downloading gzip archives, and decompressing VTT files. Titles with no matches repeated this network lookup on every playback.
- **24-Hour Negative-Match Caching (`.nomatch`):** In `rust/src/services/subtitle_service.rs`, `fetch_online_subtitle()` checks for a 24-hour negative-match marker (`cache/subtitles/online/{short_hash}.nomatch`). If present and younger than 24h, the lookup terminates in < 1ms. If an external query yields no results, a `.nomatch` marker is written. When subtitles are successfully acquired, any existing `.nomatch` marker is unlinked.
- **Local & Embedded Precedence:** Added `SubtitleService::has_english_subtitles()` checking directory sidecars (`list_tracks`), cached `.vtt` files, and container embedded tracks (`probe_embedded_subtitles`). Online requests are bypassed if English tracks are already present.
- **Native Ingestion Hook & Polite Library Sweep:** Integrated `ensure_subtitles_for_movie()` into new media ingestion in `rust/src/scanner/engine.rs`. Added `ScannerEngine::proactive_subtitle_sweep()` to politely sweep existing library titles lacking English tracks with a 500ms delay between consecutive OpenSubtitles queries.
- **Telemetry:** Added `subtitles_acquired: usize` to `ScannerReport` and `ScanResponse` (`GET /api/scan`).
- **Tests & Verification:** Dedicated test suite [`rust/tests/subtitle_test.rs`](../rust/tests/subtitle_test.rs) passed 5/5 tests. Full regression suite (`qr_auth_test` 5/5, `audit_log_test` 7/7, `user_progress_test` 4/4, `admin_auth_test` 6/6, `api_contracts_test` 4/4, `probe_android_api.py` 22/22) passed. Deployed release binary to port 8000.
- **Walkthrough:** [`docs/WALKTHROUGH_PROACTIVE_SUBTITLE_ACQUISITION.md`](WALKTHROUGH_PROACTIVE_SUBTITLE_ACQUISITION.md).

#### 5.5 Off-Host Database Backups — ✅ RESOLVED (2026-10-24)
- **Problem:** Both the live PostgreSQL database (`E:\pgdata`) and daily backups (`E:\MediaServer\backups\postgres`) resided on the same physical SSD drive `E:`. A drive hardware failure or corruption would result in total, catastrophic data loss.
- **Cross-Volume Secondary Replication (Option A):** In [`scripts/backup_postgres.ps1`](../scripts/backup_postgres.ps1), backups are automatically replicated to `D:\Flicks\.backups\postgres` on the secondary high-capacity HDD using atomic `.tmp` file copying and byte-size verification before promotion.
- **Pre-Replication Integrity Verification:** Runs `pg_restore --list` directly on the new `.dump` file to ensure archive header and table of contents are valid prior to rotation pruning or secondary replication.
- **Independent 14-Day Cold Recovery Retention (Option A):** Prunes secondary backups on `D:` independently from `E:`, maintaining a 14-day cold disaster recovery window.
- **Disaster Recovery Fallback in Restore Tool:** In [`scripts/restore_postgres.ps1`](../scripts/restore_postgres.ps1), if the primary backup directory on `E:` is missing or empty, the restore tool automatically falls back to searching `D:\Flicks\.backups\postgres`.
- **Media Scanner Ignore Rule:** Added `.backups` to directory ignore filter in `ScannerEngine::discover_video_files` ([`rust/src/scanner/engine.rs`](../rust/src/scanner/engine.rs)).
- **Extensible Sync Hook:** Added `-PostBackupCommand` and `MEDIA_SERVER_POST_BACKUP_CMD` support to chain external cloud or off-site synchronization tools.
- **Walkthrough:** [`docs/WALKTHROUGH_OFFHOST_DATABASE_BACKUPS.md`](WALKTHROUGH_OFFHOST_DATABASE_BACKUPS.md).

---

