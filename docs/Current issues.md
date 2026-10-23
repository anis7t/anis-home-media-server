# Resolution Log — Current Issues (October 2026)

Issues 1–10 have been systematically addressed, tested, and resolved across 6 phases. Issues 1–7 were
reported by the user; issues 8, 9 and 10 were found by verification passes over the QR device
sign-in feature and the migration cutover. **Two are open:**

- **Issue 11** — three Flutter test files cannot run on this host because media_kit's Windows native
  libraries are absent.
- **Issue 12** — three loose ends from the Flask/Waitress era: the `media-db` MCP server still
  serves the retired SQLite database, the stopped `MediaServer` service is still registered, and
  the dev server's proxy origins are stale.
- **Issue 13** — the AMD graphics stack is chronically unstable and the **AMF transcode pipeline
  provokes GPU TDRs**; a hard system reset on 2026-10-20 was triggered by headless-Chromium GPU
  compositing. The Playwright harness now runs with the GPU disabled. The driver decision is the
  owner's.

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
  - **15-Minute Pairing Token Engine:** Added `POST /api/auth/pairing-token/mint` and `POST /api/auth/pairing-token/claim` to `app/routes/auth.py`. Users enter a friendly name on `/account` (phone/PC) to generate an ephemeral 6-character code (e.g. `K9X2P4`). Entering this code on Fire TV or a secondary browser mints a 1-year cryptographically secure device bearer token (`ms_device_token`).
  - **Interactive Watch History Drawer:** Added `POST /api/progress` watch reporting and a sliding obsidian Watch History Drawer on `/account`. Displays movie posters, timestamps, completion percentages, resume action buttons, and a **Clear All History** option.
  - **Google Account Association:** User-scoped progress and paired device tokens are tied to the Google account, syncing watch state across all authorized household screens.

---

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

### Issue 12: The Flask/Waitress Era Left Three Live Loose Ends (2026-10-20)

- **Reported:** *(asked directly, while planning Phase 11 Slice 11.2)* — *"are we still using
  waitress?"* **No.** The answer is unambiguous:
  - Port 8000 is held by `rust\target\release\media-server-api.exe` — the **native Rust binary**.
  - `app/`, `templates/` and `static/` **do not exist**.
  - `requirements.txt` lists only `selenium` and `websockets`; **neither `flask` nor `waitress`
    is installed**, in the venv or anywhere else.
  - The `python.exe` processes on the host are the agent harness's own MCP servers
    (`fastmcp-sqlite`, `postgresql-mcp`, `serena`) — not a web server.
- **What was wrong:** the *system* had moved on; **the documentation and one shipped UI string had
  not.** Three loose ends remained, and two of them are now fixed in the same commit as this
  entry:

| # | Loose end | State |
|---|---|---|
| 1 | **The app footer rendered the badge `Waitress WSGI`** — a false statement in the shipped product, on every page. | ✅ **Fixed** — now reads `Rust · Axum API`. |
| 2 | **The agent-facing memories lied about the architecture.** `.serena/memories/architecture.md` asserted *"Backend — `app/`, Python. Served by Waitress under NSSM"* and *"127.0.0.1:8000 -> Waitress -> Flask -> services"*; `paths-and-drives.md` said *"Production WSGI is Waitress, never Gunicorn"* and pointed at `app.services.transcode_service`, `app.config.CACHE_DIR` and `media.db` as live. An agent that reads those files is confidently misinformed about the whole stack. `.serena/project.yml`'s initial prompt repeated the lie (*"a Flask + Flutter monorepo"*). | ✅ **Fixed** — rewritten against the Rust/PostgreSQL reality, with the Python-era pointers removed rather than translated (guessing at Rust function names would have introduced *new* wrong pointers). **Note: `.serena/` is gitignored**, so these fixes are **local to this machine** — see the note below. |
| 3 | **The `media-db` MCP server serves retired data.** It is pointed at `.opencode/db/media.snapshot.db`, a snapshot of `E:\MediaServer\media.db` — the **SQLite database retired in Phase 3**. PostgreSQL 18.4 has been the system of record since. The `media-db` tools therefore report **stale pre-migration rows**, and nothing tells the caller. | ⏳ **Open.** The snapshot script's comment now says so, but the MCP server is still wired to the retired file. |
| 4 | **The `MediaServer` NSSM service is still registered.** `MediaServer` — the old Flask/Waitress service — is `Stopped` / `Manual` and still points at `venv\Scripts\python.exe run_production.py`, a file that **no longer exists**, so it cannot start. Inert, but it is a leftover. | ⏳ **Open — the owner's call.** It is a host-level registration; deleting it is not something to do unattended. |
| 5 | **The dev server's proxy origins are stale, and inverted relative to reality.** `web/vite.config.ts` sets `RUST_ORIGIN` to `:8001` (**nothing listens there** — Rust runs on `:8000`) and `FLASK_ORIGIN` to `:8000` (**which is actually Rust**). So in `npm run dev` the "Rust" routes point at a dead port and the "Flask" catch-all actually hits Rust. The names and the comments are both wrong. | ⏳ **Open.** A dev-only behaviour change: collapsing the two origins into one needs the "unmigrated" endpoint list confirmed first, so it does not belong in a documentation cleanup. |

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
sign-in was restored. **State: 14.2 and 14.3 are fixed; 14.1, 14.4, 14.5 and 14.6 remain open**
(14.4–14.6 have a chosen option and await implementation; 14.1's recorded "fix" was retracted — see
[`docs/TRIAGE_01_WATCH_HISTORY.md`](TRIAGE_01_WATCH_HISTORY.md) §9).

1. **Watch history not populated.** While signed in on the web browser and after playing media,
   **no played entry was listed in the devices menu**. Possibly a device-scoping / progress-source
   mismatch (`GET /api/devices` returns the caller's current device plus owned devices and embeds
   `watch_history` from the device/progress tables), or the history UI rendering. Needs a live,
   signed-in reproduction.
   - **Open.** The 2026-10-23 attempt recorded in `TRIAGE_01` as a fix is **behaviour-identical** to
     the code it replaced and is retracted (that document, §9). Re-investigation starts at whether
     the web player writes `POST /api/progress` at all, and whether the device id it writes with is
     the one `/api/devices` reads back.
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
4. **Unscannable QR code in the devices menu.** In the **signed-in** state, the QR code displayed in
   the devices menu is **cropped / not fully displayed**, making it unscannable.
5. **Header "Sign in" menu.** Clicking "Sign in" in the header lands **directly** into the Google
   sign-in flow instead of showing **both** the Google sign-in option and the QR scan option. The QR
   scan option should be **disabled only in the TV variant** of the app.
6. **Add-device / QR flow confusion.** In the devices menu, the **"Add device"** option: after
   entering a device name it shows a **QR code, a URL and a token**. Questions the owner has:
   - What am I supposed to do with the QR code?
   - The URL is **non-functional**.
   - Where was I supposed to enter the token?
   - Why does this whole thing exist, since QR login is already handled?

- **Open questions for triage:** watch-history source of truth and per-device scoping;
  playback root cause (autoplay / 0:00 / direct play vs HLS); QR display/scoping; sign-in menu
  option set; add-device token/QR flow.
- **Context:** the sign-in outage itself was fixed on 2026-10-23 (stale allowlist row cleared; allowlist
  endpoints hardened to admin-only; empty-list = open sign-in). The issues above were reported
  against that restored state and are presumed **unrelated to the allowlist**, pending reproduction.

---

