# Session Handoff: 2026-10-16 19:45 IST

| | |
|---|---|
| **Date** | 2026-10-16 19:45 IST (2026-10-16 14:15 UTC) |
| **Agent** | opencode (`space-bunny-free`) |
| **Taking over** | Antigravity harness, Gemini 3.8 Flash |
| **Workspace** | `E:\MediaServer` |
| **Branch** | `feat/rust-transcode-worker` — **pushed**, tracking `origin/feat/rust-transcode-worker`, 100 commits ahead of `origin/main` |
| **Governing plan** | **`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`** — the shape and per-phase exit gates that every phase doc below defers to. Read it first. |
| **Current phase** | **Phase C — retiring the Flask proxy bridge, endpoint by endpoint.** Matrix and exit gates in `docs/MIGRATION_STATUS.md`; detail in `docs/PHASE_7_FLASK_RETIREMENT.md` |
| **Code state** | **C4-pre CORS scoping, C4a native DLNA, and C4b native Google Cast are COMPLETE and verified live.** Every remaining `/api/cast/*` capability works against a real Samsung DU7000: discovery, LOAD, resume at a position, play/pause, seek after a dropped session, volume, mute, and quit-app teardown. DLNA equivalent verified separately. Bridge reduced to **6 route groups**. |
| **Verified** | **228 / 228 Rust tests passing.** Live-verified against the DU7000: play, resume `pos=600.0`, seek-after-drop recovery, volume ramp tracking exactly (100→100.0, 10→10.0, 20→20.0, 50→50.0, 30→30.0), mute state tracking (True/False), teardown to IDLE in **1.0 s**, and DLNA play/pause/seek 1800→`pos=1806.269`/volume/mute/stop. `probe_android_api.py` 22/22 on both `:8000` and `:8001`. |
| **Pushed** | **Yes** — the branch is on GitHub. Pushing is no longer reserved for the user. |
| **Commits described** | `6c017e9` → `e75dfe2` (24 commits; the Cast series). Named rather than a single `HEAD`, per `AGENTS.md` §1 — a handoff citing its own hash is wrong the moment it is committed. |

> This header names the **code** commits rather than a single `HEAD`: the next handoff should
> cite this file, `Handoffs/2026-10-16_19-45_opencode_phase-c-cast-complete_handoff.md`, and
> let it supersede `2026-10-16_00-40_opencode_watchdog-and-recon-complete.md`.

---

## Paste-ready prompt

Copy everything inside the block to start the next session.

---

```text
Continue work on Anis' Home Media Server at E:\MediaServer.

READ FIRST, IN THIS ORDER
1. AGENTS.md                          -- the rules. s0 standing rules, s4 admin-auth
                                         invariants, s6 Cast/DLNA invariants, s7 testing,
                                         s9 Rust invariants
2. docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md
                                      -- GOVERNING PLAN. Per-phase shape and exit gates.
                                         Every phase doc defers to it.
3. docs/MIGRATION_STATUS.md           -- P0-P7 matrix. Items marked *(reported)* have
                                         never been re-verified under authorization and
                                         must be treated as untested code, not progress.
4. docs/PHASE_7_FLASK_RETIREMENT.md   -- Phase C endpoint matrix + the Cast lessons
5. docs/PROJECT_STATUS.md             -- primary current handoff
6. Handoffs/2026-10-16_19-45_opencode_phase-c-cast-complete_handoff.md  -- THIS session

STANDING RULES (AGENTS.md s0) - DO NOT SKIP
- Plan first, then ASK FOR APPROVAL. State scope, exit criteria, risks, open decisions.
- Flask is DEPRECATED. No new route/service/page/worker in app/. Every new requirement is a
  Rust (:8001) requirement. Prefer retiring a Flask responsibility over bridging to it.
- The rollback artifact is a TAGGED COMMIT, not a live code path. Do not gate retirement
  behind "feature flags so Flask stays viable".
- The Flutter/Fire TV client is a first-class constraint. /api/* shapes it must not change
  underneath it.

STATE
- Branch feat/rust-transcode-worker, PUSHED, tracking origin, 100 commits ahead of
  origin/main. Clean tree.
- Services:
    MediaServer      (Waitress/Flask, DEPRECATED)  0.0.0.0:8000  Automatic
    MediaServerRust  (Axum)                        0.0.0.0:8001  Automatic
    MediaServerPG    (PostgreSQL 18.4)             127.0.0.1:5432 NetworkService
    Cloudflared      named tunnel -> 127.0.0.1:8000 (still Flask)
  NSSM at C:\MediaServer\bin, PG binaries at C:\postgres, PG data E:\pgdata.
  MediaServerRust MUST stay bound to 0.0.0.0 - it was briefly 127.0.0.1 and that is a
  critical bug (loopback-only looks healthy from its own machine and is invisible to the
  suite AND to every other device).
  Firewall rule "MediaServerRust (media-server-api.exe)" is created idempotently by
  scripts/install_rust_service.ps1. Required for LAN access and for the port swap.
- Rust suite: 228/228 green. One known-flaky test:
  media_info_test.rs::test_repeated_requests_are_served_from_the_probe_cache (timing).
- Storage: E:\MediaServer (app, media.db, HLS scratch, previews); D:\Flicks (raw media,
  .archive, .uploads, .deleted); E:\pgdata (PG); C: holds nothing for this project.
- The watchdog scheduled task is DELIBERATELY REMOVED (2026-10-16). Do not re-arm it.

DONE THIS SESSION
- C4-pre CORS: path-scoped middleware instead of a blanket CorsLayer. Matches Flask exactly
  (/media/ + /hls/ only; /api/* unreadable cross-origin). Verified live on both engines.
- C4a native DLNA: SSDP discovery, UPnP SOAP, 4 /api/cast/* routes. Verified live against
  the DU7000 including a 206 byte-range TimeSeekRange reply.
- C4b native Google Cast: hand-rolled protobuf CastMessage (byte-exact), eureka discovery
  via the ARP neighbour table, TLS via Schannel, LOAD + transport controls.
  Verified live end to end. Teardown clears the TV in 1.0s.
- Proxied count 7 -> 6 groups.

ELEVEN CAST BUGS FIXED, ONE SHAPE (read the handoff s6 - this is the valuable part)
Every one was ACKNOWLEDGED by the receiver, returned ok:true, and did nothing. A green test
suite caught none of them:
  - rustls rejects the self-signed X.509 v1 cert -> native-tls / Schannel
  - media namespace needs the app's per-session transportId (not receiver-0, not the
    documented constant), and you must CONNECT to it after LAUNCH CC1AD845
  - currentTime is a TOP-LEVEL SIBLING of media in LOAD; nested is silently ignored
  - streamType must be BUFFERED, not LIVE, or the artifact is unseekable
  - MEDIA_STATUS.status may be a LIST or an object -> one status_object() helper
  - volume/mute go on the RECEIVER namespace, not the media session
  - a cached dead Cast connection must be redialled, and redial must redo the app session
  - stop must NEVER retry: a retried stop re-launches the app it just closed
  - SET_VOLUME_MUTED does not exist -> SET_VOLUME with a muted field
  - STOP_APP does not exist -> STOP with sessionId
  - status.volume.level and status.volume.muted are NESTED; reading status.volume as a
    scalar returned the 100.0 default on every call and was mis-documented as a protocol
    limitation in three places

THE RULE: before concluding a device lacks a feature, diff the payload against the WORKING
implementation. The ground truth is pychromecast, already installed at
E:\MediaServer\venv\Lib\site-packages\pychromecast. Flask's app/services/cast_service.py is
the working reference. All eleven were answered in minutes by reading those, after live
experiments had already failed to explain them.

Two more rules from the same session:
  - An ack, an echoed field and a returned success are statements about the PROTOCOL, not
    about whether anyone can hear or see the result.
  - A value that never changes is the signature of a lookup that never matches. A field that
    is never found reports its DEFAULT, not an error.
  - Write test fixtures from a CAPTURED payload, never from imagination. Every one of these
    bugs was shielded by a unit test whose fixture had the same wrong shape as the code.

NEXT OBJECTIVE - propose a plan and ASK FOR APPROVAL first
Phase C5: port POST /api/scan natively, then delete its mount at rust/src/lib.rs:343.
  Small, self-contained, no auth dependency. Details and a ready plan in handoff s9.
  - MUST preserve Flask's admin-gate semantics; verify before writing code.
  - Exit criteria and risks are in the handoff. Do not proceed unapproved.

AFTER THAT - the bridge backlog (handoff s7). This list IS the debt backlog; retire each
natively and delete its mount. Do not extend it.
  1. /auth, /auth/*                 Google session - BLOCKS 2, 3 and 4
  2. /api/auth, /api/auth/*
  3. /api/devices, /api/devices/*   C3b list/rename/delete (register, heartbeat and
                                     client-hints are already native)
  4. /api/admin, /api/admin/*       ADMIN-GATED DESTRUCTIVE SURFACE - highest risk.
                                     Read AGENTS.md s4 "Admin authorisation invariants"
                                     and docs/AUTHENTICATION_PLAN.md first.
  5. /api/storage, /api/storage/*
  6. /api/scan                      (C5, above)

VERIFIED GAPS TO CLOSE
- POST /api/transcode/start/{*filename} exists in Flask (app/routes/api.py:357) and DOES NOT
  EXIST IN RUST AT ALL - it 404s into the SPA fallback. Harmless today (the Flutter client
  resolves :8000), but it kills the client's manual-transcode button AFTER the port swap.
  flutter_client/.../library_repository.dart:100 calls it. Recommend a shim delegating to
  JobService rather than changing the client.
- scripts/probe_android_api.py accepts 404 for /api/scan and /api/transcode/start. The
  AGENTS.md carve-out about not "fixing" /api/app/* 404s into 200s is correct for genuinely
  absent routes and WRONG for these two shipped features - tighten once they exist.

DO NOT DO THE PORT SWAP YET
The agreed end state is Rust on :8000 with Flask moved to a secondary port for rollback.
Order: retire the bridge -> transcode worker (Phase 6C) -> Flask retirement.
Installed Flutter APKs default to :8000. Repointing the tunnel alone breaks every installed
app.

HOW TO BUILD, TEST, DEPLOY
  # test (~4 min)
  Start-Process cmd.exe -ArgumentList '/c','scripts\cargo.bat test --manifest-path
    rust\Cargo.toml > C:\Users\anis7\AppData\Local\Temp\opencode\test.log 2>&1'
    -WorkingDirectory E:\MediaServer -WindowStyle Hidden
  # deploy (approve UAC)
  powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList
    '-NoProfile','-ExecutionPolicy','Bypass','-File','E:\MediaServer\scripts\
    restart_rust_service.ps1','-Wait' -Wait"
  # VERIFY THE DEPLOY BY ARTEFACT TIMESTAMP, NEVER BY HEALTH CHECK ALONE
  (Get-Item rust\target\release\media-server-api.exe).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
  git log -1 --format=%cd --date=format:'%Y-%m-%d %H:%M:%S'
  # client contract probe
  python scripts/probe_android_api.py --base http://127.0.0.1:8001
  python scripts/probe_android_api.py --base http://127.0.0.1:8000
  # live cast harness (starts playback on the real TV; teardown is in a finally)
  .\venv\Scripts\python.exe scripts\verify_cast_live.py --volume-ramp

TRAPS (full list in handoff s13)
- Never run bare `flutter test`; use scripts/run_flutter_tests.ps1. It purges media_kit's
  orphaned temp state, which otherwise hangs whole test files.
- Probe PostgreSQL with a TCP connect to 127.0.0.1:5432, NEVER `pg_ctl status`.
- Repo .ps1 files must stay pure ASCII; PowerShell 5.1 mangles UTF-8 punctuation.
- git commit messages containing backticks break under PowerShell; write to a temp file
  and use `git commit -F -`.
- Axum forbids overlapping wildcards under one prefix; one wildcard plus internal prefix
  dispatch. Getting it wrong PANICS THE ROUTER AT STARTUP and takes down every suite.
- Do not resolve `conftest` by module name in Python tests.
- Always disconnect live Cast sessions, in a `finally`.
```

---

## 1. Executive summary

1. **Cast and DLNA are now fully native.** `C4a` (DLNA) and `C4b` (Google Cast) are complete
   and every capability was verified against a real Samsung DU7000 — discovery, playback,
   resume at a position, seek after a dropped session, volume, mute, and quit-app teardown.
   The proxy bridge is down to **6 route groups** from 7.

2. **Eleven protocol defects were found and fixed, all with one shape:** the receiver
   *acknowledged the message, returned success, and did nothing*. A green test suite caught
   none of them. Three came from the documentation, two from my own reasoning, and **all
   eleven were answered in minutes by reading `pychromecast` in the venv** — after live
   experiments had already failed to explain them.

3. **Two of my own conclusions were flat wrong, and both were documented as fact.**
   I recorded that *"`status.volume` is the application's volume, not the speaker volume;
   it can't be fixed, the protocol doesn't expose it"* in `AGENTS.md`, in
   `docs/PHASE_7_FLASK_RETIREMENT.md`, and on the parser itself. It was a parser reading
   `status.volume` as a scalar when the field is **nested** (`status.volume.level`), so every
   call returned the documented 100.0 fallback. Verified live, it now tracks exactly.
   Similarly, I attributed a lingering "blank screen" to a harmless redraw lag; the quit
   message was simply `STOP_APP`, which is not a real message type.

4. **A pattern is now a standing rule:** write test fixtures from a captured payload, never
   from imagination. Every one of these bugs was shielded by a unit test whose fixture had
   the *same* wrong shape as the code it was testing.

5. **Verified gap found:** `POST /api/transcode/start/{*filename}` exists in Flask and is
   **entirely absent from Rust**. Harmless today because the Flutter client resolves `:8000`,
   but it kills the client's manual-transcode button **after the port swap**.

---

## 2. Active services and ports

| Service | Port | State | Notes |
|---|---|---|---|
| `MediaServer` (Waitress/Flask) | `0.0.0.0:8000` | Running, Automatic | **Deprecated.** Public origin today |
| `MediaServerRust` (Axum) | `0.0.0.0:8001` | Running, Automatic | `RUST_HOST` defaults to `0.0.0.0`. **Must not** be `127.0.0.1` |
| `MediaServerPG` (PostgreSQL 18.4) | `127.0.0.1:5432` | Running, NetworkService | Data `E:\pgdata`, binaries `C:\postgres`, restart-x3 |
| `Cloudflared` | — | Running | Named tunnel `media.anisparvez.in` → `127.0.0.1:8000` |
| `MediaServerWatchdog` task | — | **Deliberately removed 2026-10-16** | Do not re-arm; it flashed a console every 5 min |

NSSM is at `C:\MediaServer\bin\nssm.exe` so it survives `E:` absence.

**A loopback-only bind looks healthy from its own machine** and is invisible to the entire
test suite *and* to every other device on the network. Both Python clients bypass loopback
media hosts, so a loopback bind can silently fall through to the production connection
provider. Verify listener addresses before debugging anything that "works locally".

---

## 3. Key files changed this session

**Rust — Cast**
- `rust/src/services/cast_proto.rs` — hand-rolled protobuf `CastMessage` (byte-exact wire
  encoding), `status_object()` shape normaliser, `parse_receiver_status()`
- `rust/src/services/cast_transport.rs` — Schannel TLS (`native-tls`), framing,
  `requestId` correlation, PING→PONG, `app_transport()`, `close()`
- `rust/src/services/cast_control.rs` — `load` (BUFFERED, top-level `currentTime`),
  play/pause/seek/stop, `quit_app` (STOP+sessionId), `set_volume`/`set_muted`,
  `status_payload`, live tests
- `rust/src/services/cast_registry.rs` — device cache, scan, `redial()`, `cast_action()`
  (never retries `stop`), `cast_status()`
- `rust/src/services/cast_discovery.rs` — eureka probe over DLNA hosts ∪ cached hosts ∪
  neighbour table (`GetIpNetTable`)
- `rust/src/services/dlna_service.rs` — SSDP, SOAP, DIDL metadata, `DLNA_CONTENT_FEATURES`

**Rust — routing**
- `rust/src/lib.rs:330-347` — the proxy mounts. **This list is the debt backlog.**

**Scripts / docs**
- `scripts/verify_cast_live.py` — live harness; teardown in a `finally`, exits non-zero if
  the receiver is still playing
- `AGENTS.md` — Cast and DLNA invariants, extended with the fixture rule
- `docs/PHASE_7_FLASK_RETIREMENT.md` — C4a/C4b sections, endpoint matrix, standing lessons

---

## 4. Where the migration stands

The governing plan is **`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`**. Phase shape
and per-phase exit gates are defined there and every phase doc defers to it. Current position:

```
P0-P2   architecture audit, React SPA, Vite proxy, SQLite->PostgreSQL     complete
P3      PostgreSQL schema + SQLAlchemy repository mapping + data migration complete
P4      Rust API foundation                                            complete
P5A-D   progress, media streaming, subtitles, previews                  complete
P5E     transcoding                                                    ported
P6A     transcode job model + durable queue, /api/transcode-status      complete
P6C     transcode worker (spawns FFmpeg)                                NOT STARTED
P7      Flask retirement — Phase C bridge retirement                    IN PROGRESS (this work)
```

Matrix, risks and resumption sequence: `docs/MIGRATION_STATUS.md`.
**Items marked *(reported)* in that matrix have never been re-verified under authorization
and must be treated as untested code, not as progress.**

The agreed end state is a **port-ownership swap**: Rust serves `:8000`, Flask moves to a
secondary port purely for rollback. Order: retire the bridge → transcode worker (Phase 6C) →
Flask retirement.

**⚠️ Do not do the swap before the bridge is retired.** Installed Flutter APKs default to
`:8000`; repointing the tunnel alone breaks every installed app.

---

## 5. The proxy bridge — the retirement backlog

`rust/src/lib.rs:330-347` mounts `proxy_handler` for exactly these groups.

**Per `AGENTS.md` §0.2 and §9, this bridge is temporary hybrid-hosting scaffolding and now
contradicts the Native Independence Invariant. Its endpoint list is the debt backlog — to be
paid down natively and deleted, not extended.**

| # | Route group | Status | Notes |
|---|---|---|---|
| 1 | `/auth`, `/auth/*` | 🔴 proxied | Google session. **Blocks #2, #3, #4** |
| 2 | `/api/auth`, `/api/auth/*` | 🔴 proxied | Depends on #1 |
| 3 | `/api/devices`, `/api/devices/*` | 🔴 proxied (C3b) | List / rename / delete. **Register, heartbeat and client-hints are already native** |
| 4 | `/api/admin`, `/api/admin/*` | 🔴 proxied | Admin-gated **destructive** surface — see §7.2 |
| 5 | `/api/storage`, `/api/storage/*` | 🔴 proxied | Retention policy, orphan audit/purge, storage telemetry |
| 6 | `/api/scan` | 🔴 proxied | Manual library scan trigger. **Recommended next task** |

**Verified behaviour today** (probed this session):

```
:8000  POST /api/scan -> 403                :8001  POST /api/scan -> 403   (proxied, identical)
:8000  POST /api/transcode/start/{f} -> 404 :8001  POST /api/transcode/start/{f} -> 404
       (Flask route exists; 404 is its own abort on a non-video name)
       Rust has NO such route -> SPA fallback, Content-Type application/json
```

### 5.1 Already native — do not re-port

```
GET  /health, /api/health, /api/system-status
GET  /api/movies, /api/movie/{*filename}
     progress routes, /media/**, /subtitles/**, /preview/**, /hls/**
GET  /transcode/{*filename}, /api/transcode-status/{*filename}
GET  /api/transcode/jobs, POST /api/transcode/jobs/{*path}
     /poster/**, /tmdb-poster/{id}, /tmdb-backdrop/{id}, /api/media-info/{*filename}
POST /api/devices/register, /heartbeat, /client-hints
POST /api/cast/play, /api/cast/control   GET /api/cast/status, /api/cast/devices, /api/cast/scan
     SPA fallback
```

---

## 6. The Cast findings — the most valuable part of this handoff

Eleven defects, one recurring shape: **the receiver accepted the message, returned success,
and did nothing.** A green test suite did not catch a single one.

Ground truth is `E:\MediaServer\venv\Lib\site-packages\pychromecast`; Flask's
`app/services/cast_service.py` is the working reference implementation.

### 6.1 TLS: rustls cannot talk to Cast — use Schannel

The DU7000 presents a self-signed **X.509 v1** certificate (`subject == issuer`). `rustls-webpki`
accepts only v3 and rejects v1 **while extracting the public key**, before any custom verifier
runs — no verifier configuration works around it. Use Schannel via `native-tls`. Only the trust
*chain* is bypassed; the handshake signature is still verified, so a passive attacker cannot
impersonate the receiver.

**Never connect to a host supplied by a request.** Take it from the discovery cache.

### 6.2 The media namespace needs the app's per-session `transportId`

The largest source of confusion. The sequence:

1. `CONNECT` to `receiver-0` (`urn:x-cast:com.google.cast.receiver`)
2. `LAUNCH` `CC1AD845` (default media receiver)
3. **Poll** for the app's `transportId` — a **per-session UUID**, at `status.transportId` *or*
   `status.applications[].transportId` depending on receiver
4. `CONNECT` **to that transport**
5. Only then send media-namespace messages

`urn:x-cast:com.google.cast.media-receiver` is the *documented constant* and it is wrong here.
Addressing either the constant or `receiver-0` is answered with `CLOSE`.

**`LAUNCH_STATUS: USER_ALLOWED` is not "the app is up".** Both replies arrive seconds later.
Sequence on a poll, never on the ack.

### 6.3 `LOAD`: `currentTime` is a sibling of `media`, and `streamType` is `BUFFERED`

```json
{ "type": "LOAD", "media": { ... }, "currentTime": 600.0,
  "streamType": "BUFFERED", "autoplay": true }
```

- `currentTime` nested inside `media` is **ignored completely**: the load succeeds, the
  receiver plays from zero, reports no error, and a resume cast *appears* to work while
  losing the user's position.
- `streamType: "LIVE"` tells the receiver the artifact is unseekable — both our seeks and a
  phone scrub do nothing.

**Whoever sends `LOAD` owns playback.** The local phone player is deliberately paused for the
whole cast; its play/pause, scrub and skip controls must forward to the TV.

### 6.4 `MEDIA_STATUS.status` may be a list or an object

Google specifies an object. **The DU7000 sends `{"status":[{...}]}`, and `[]` while idle.**
Indexing it directly produced three unrelated bugs: a zero position on a playing cast, a
refused `seek`, and a phantom "still playing" after teardown.

Every reader of receiver `status` **must** go through `cast_proto::status_object`. Keep the
shape assumption in exactly one function — fixing each site individually did not work,
because the same assumption had been written in a second and third place.

### 6.5 Volume and mute: receiver namespace, and the nested read

**Control — works, verified by the user watching and listening:**

```json
{"type": "SET_VOLUME", "volume": {"level": 0.4}}   // 0.0-1.0 float, receiver namespace
{"type": "SET_VOLUME", "volume": {"muted": true}}   // mute is a FIELD, not a message type
```

- Volume must go on the **receiver** namespace as platform/master volume. The media-namespace
  alternative with a `mediaSessionId` is accepted and echoed back while changing nothing audible.
- **`SET_VOLUME_MUTED` does not exist.** I invented it. Accepted with `ok: true`, did nothing —
  indistinguishable from "this receiver has no mute".

**Read — was broken until the final commit of this session:**

```json
{"status": {"volume": {"level": 0.25, "muted": false, "controlType": "attenuation"}}}
```

pychromecast reads it as `status_data.get("volume", {})` then `.get("level")` / `.get("muted")`
— exactly what Flask reports as `cast.status.volume_level` / `volume_muted`.

My parser read `status.volume` as a scalar and `status.muted` at top level. **Both lookups
missed on every call** and returned the documented fallbacks — 100.0 and unmuted. Verified live:

```
asked 100/10/20/50/30 -> receiver reports 100.0/10.0/20.0/50.0/30.0   TRACKS
asked muted=True/False -> receiver reports muted=True/False
```

> **Write fixtures from a captured payload, never from imagination.** The unit test passed
> because its fixture had the *same* wrong shape as the code. That is how every one of these
> bugs survived a green suite. Where a fallback default exists, add a test that the real shape
> does *not* land on it.

### 6.6 Quitting the app is `STOP` + `sessionId`

```json
{"type": "STOP", "sessionId": "..."}    // receiver namespace, receiver-0
```

pychromecast: `self.send_message({MESSAGE_TYPE: "STOP"}, inc_session_id=True)` →
`data["sessionId"] = self.session_id`. The `sessionId` comes from `applications[].sessionId` in
`RECEIVER_STATUS` — the same entry that carries `transportId`.

**`STOP_APP` does not exist.** Measured: the app now leaves the receiver **1.0 s** after the
message lands. Before, it never did — only the receiver's own ~60 s idle timeout closed it,
which made one earlier run look like it had worked.

**Also removed:** a `CLOSE` I had added on teardown addressed to `receiver-0`. pychromecast
sends `CLOSE` only from `disconnect_channel`, to the app's transport id, with an `origin`
object. Teardown is now quit-the-app, then drop the socket — what Flask does.

### 6.7 Connection liveness: never cache without a redial path

A receiver resets the socket on its own. A cached dead socket fails every later command
identically, so a playing cast becomes **permanently uncontrollable** (`os error 10053`, no
retry). **Every action must redial and retry once**, and redial must re-run the whole app
session, because the transport id is per-session.

**`stop` is the one action that must never retry** — a retried `stop` redials and
**re-launches the app it just closed**.

A scan replaces the device map, so connections are cached per device and survive a scan.
mDNS/ARP windows miss the DU7000 in roughly one scan in three.

### 6.8 Miscellaneous

- A receiver may **`PING` and expects `PONG`**. Unanswered, it tears the virtual connection down.
- **An absent or empty media `status` means stopped, not buffering.** Inferring buffering from
  "the app is running" left a finished cast showing `buffering` forever.
- **Read status from the receiver on demand, never from a cached push** — receivers emit
  `MEDIA_STATUS` on transitions only, measured minutes apart while playing.
- **A receiver in standby reports no volume field.** Default to 100; inventing 0 tells the user
  their television is muted.
- **Live verification must tear down in a `finally`.** It exits non-zero if still playing.

### 6.9 The general rule

> An ack, an echoed field and a returned success are statements about the **protocol**, not
> about whether anyone can hear or see the result.
>
> Three of the message-type bugs came from the **documentation**, two from **my own
> reasoning**. The ones fixed fastest came from either reading a working client's source, or
> the user reporting what they saw and heard.
>
> **When a control fails on an otherwise healthy connection, diff its payload against the
> working implementation before concluding the device lacks the feature.**
>
> Where a human can watch the outcome, the human is the better oracle — and a test that cannot
> measure the thing must say so rather than guess.

---

## 7. Open risks and known gaps

### 7.1 `/api/transcode/start/{*filename}` is absent from Rust

Flask: `app/routes/api.py:357`. Rust: **no such route**, so it 404s into the SPA fallback with
`Content-Type: application/json` — a clean degradation, but still a missing contract.

`flutter_client/lib/features/library/data/repositories/library_repository.dart:100` calls it.
Harmless today because the client resolves `:8000`; **dead after the port swap.**

Rust's own admission path is `POST /api/transcode/jobs/{*path}`. **Recommend a shim**
delegating to `JobService` rather than changing the client — changing the client is a separate
compatibility surface, and the probe asserts the old path.

### 7.2 The admin-gated destructive surface is still entirely in Flask

`AGENTS.md` §4 applies in full, and those routes are reachable from the public internet through
the Cloudflare tunnel. Treat as the **highest-risk item** in the backlog:

- The Admin PIN **fails closed and has no default**. `get_setting('admin_pin', '')`, never a
  literal. There *was* a hard-coded `'6361'`, which made "no PIN configured" mean "anyone who
  guesses four digits may delete the library". Unset must mean the PIN channel is **closed**,
  leaving only a Google admin session, which is what sets the first PIN deliberately.
- **Never accept the PIN from a query string.** `?pin=` writes the secret into Waitress access
  logs, Cloudflare's edge logs, browser history and `Referer` headers. Header (`X-Admin-Pin`)
  and JSON body only.
- **A closed probe is not a closed door.** Any test asserting the PIN is refused must also
  assert a destructive route returns 403 —
  `tests/test_admin_auth.py::test_no_configured_pin_means_no_pin_is_accepted`.
- **Do not weaken `is_admin_authorized()` to make a test pass.** The `PYTEST_CURRENT_TEST`
  pass-through is a test seam, not a model for production auth.

Porting this natively means porting the authorisation **correctly**, not mechanically.

### 7.3 The client contract probe has a real weakness

`scripts/probe_android_api.py` accepts `404` for `POST /api/scan` and
`POST /api/transcode/start/{...}`. The `AGENTS.md` carve-out — *"do not "fix" `/api/app/*`'s
404 into a 200"* — is correct for genuinely absent routes (`/api/app/*` when nothing is
published, `/api/cast/status` 400 while idle). It is **wrong** for these two: real shipped
features where a `404` means the probe passes while the feature is absent. Tighten once the
routes exist.

### 7.4 Residual

- Teardown screen lag: `app_running=false` now lands in 1.0 s, but a human dismissed the
  receiver screen once on an early run. Treat `app_running=false` as "gone from the receiver's
  application list", not "the screen is clear".
- The reported volume proves the receiver recorded the request; it says nothing about what came
  out of the speakers. Keep a human watching.
- Rust HLS-cache **success path is implemented but only the error path is verified**. Mark any
  claim about it unverified.

---

## 8. Recommended next task — Phase C5, `POST /api/scan`

Small, self-contained, no auth dependency. **Propose this as a plan and get approval first.**

**Scope**
- Add a native `POST /api/scan` (and `GET`, matching Flask's `methods=['GET','POST']`).
- Trigger the same background library ingestion as `app/services/scanner_service.py`.
- **Preserve Flask's admin-gate semantics.** Check what `/api/scan` actually requires; if it is
  admin-gated, a native implementation must not silently drop the gate.
- Delete the `/api/scan` mount at `rust/src/lib.rs:343`.

**Explicitly out of scope:** `/api/storage/*`, `/api/devices` list/rename/delete,
`/api/admin/*`, `/auth/*`.

**Exit criteria** (all checkable)
1. `POST /api/scan` on `:8001` returns the same status code and response shape Flask returns.
2. The proxy mount is gone from `lib.rs`.
3. A new scan ingests: a file added to a media root appears in `GET /api/movies` on `:8001`.
4. `python scripts/probe_android_api.py --base http://127.0.0.1:8001` still 22/22.
5. Full Rust suite still 228+ passing.
6. Docs updated: `docs/PHASE_7_FLASK_RETIREMENT.md` matrix row, `docs/MIGRATION_STATUS.md`,
   and any `/api/scan` reference in `AGENTS.md`.

**Risks**
- *Starting a scan against the live library.* Snapshot first (§9.4) and confirm idempotency.
- *Dropping the admin gate* would be a security regression. Verify before writing code.
- *Concurrent scans* — Flask may already guard this. Match the guard.

**Open decisions for the user**
- Should `/api/scan` remain admin-gated in Rust? (Probably yes; needs confirmation.)
- Is Phase 6C (transcode worker) or the port swap next after this?

---

## 9. Build, test, deploy and verification recipes

### 9.1 Test

```powershell
Start-Process -FilePath 'cmd.exe' -ArgumentList '/c','scripts\cargo.bat test --manifest-path rust\Cargo.toml > C:\Users\anis7\AppData\Local\Temp\opencode\test.log 2>&1' -WorkingDirectory 'E:\MediaServer' -WindowStyle Hidden
```

Use `scripts/cargo.bat` — it sets the MSVC environment including `INCLUDE`. Sum the
`test result:` lines. Expect **228 / 0**.

### 9.2 Deploy

```powershell
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','E:\MediaServer\scripts\restart_rust_service.ps1','-Wait' -Wait"
```

Approve the UAC prompt.

### 9.3 Verify the deploy by artefact timestamp — never by health check alone

A 200 from `/health` proves only that *some* build is running. The restart scripts have failed
their build with "Access is denied" and still reported success.

```powershell
Write-Output "exe:    $((Get-Item rust\target\release\media-server-api.exe).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Output "commit: $(git log -1 --format=%cd --date=format:'%Y-%m-%d %H:%M:%S')"
```

Compare **full timestamps including seconds**. Two comparisons of `HH:mm` alone have silently
produced false results on this host.

### 9.4 Client contract probe and live cast harness

```powershell
python scripts/probe_android_api.py --base http://127.0.0.1:8001     # expect 22/22
python scripts/probe_android_api.py --base http://127.0.0.1:8000     # expect 22/22

.\venv\Scripts\python.exe scripts\verify_cast_live.py                # full sequence
.\venv\Scripts\python.exe scripts\verify_cast_live.py --volume-ramp  # volume + mute
```

The harness starts playback on a real television; teardown is in a `finally` and it exits
non-zero if the receiver is still playing. Expected current output:

```
--- volume ramp: 100 -> 10 -> 20 -> 50 -> 30 (watch / listen) ---
  ....  asked 100 -> command ok=True, receiver reports 100.0  TRACKS
  ....  asked  10 -> command ok=True, receiver reports 10.0   TRACKS
  ....  asked  20 -> command ok=True, receiver reports 20.0   TRACKS
  ....  asked  50 -> command ok=True, receiver reports 50.0   TRACKS
  ....  asked  30 -> command ok=True, receiver reports 30.0   TRACKS
--- mute (listen: the audio should stop for ~8s) ---
  ....  asked muted=True  -> receiver reports muted=True
  ....  asked muted=False -> receiver reports muted=False
--- teardown (guaranteed) ---
  receiver after stop: state=stopped app_running=False -> IDLE
```

**Live Rust tests** are gated and print `SKIPPED` rather than passing silently — always confirm
you see real output:

```powershell
$u=[uri]::EscapeDataString('2001 A Space Odyssey (1968) [BluRay] [1080p] [YTS.AM]/2001.A.Space.Odyssey.1968.1080p.BluRay.x264-[YTS.AM].mp4')
$live="http://192.168.1.16:8001/media/$u"
# MEDIA_SERVER_CAST_LIVE_TESTS=1, MEDIA_SERVER_CAST_LIVE_HOST=192.168.1.8,
# MEDIA_SERVER_CAST_LIVE_URL=$live
scripts\cargo.bat test --manifest-path rust\Cargo.toml --lib live_teardown_timeline -- --nocapture
```

**Database hygiene:** live device-registration tests leave probe residue. Delete rows where
`client_ip='127.0.0.1'` and `last_seen` is recent. **Preserve real devices:** `Vivo iQOO Neo 7`,
`Laptop`, `web_*`.

**Before any live verification of isolation** (`AGENTS.md` §7): snapshot the library file list,
the production `movies` rows and the `cache/hls` directory list plus a hash of each, before and
after a full run — all three must be unchanged. This has bitten twice.

---

## 10. Document index

### Governing plan and current state — read in this order
| Doc | What it holds |
|---|---|
| **`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`** | **The governing plan.** Per-phase shape and exit gates that every phase doc defers to. Read before planning anything. |
| `AGENTS.md` | **The rules.** §0 standing rules, §4 admin-auth invariants, §6 Cast/DLNA invariants + HLS cache integrity, §7 testing protocol, §9 Rust invariants |
| `docs/MIGRATION_STATUS.md` | P0-P7 matrix, risks, resumption sequence. *(reported)* = untested code |
| `docs/PROJECT_STATUS.md` | Primary current handoff: completed work, known bugs, testing requirements, work queue |
| `docs/PHASE_7_FLASK_RETIREMENT.md` | **Phase C.** Endpoint retirement matrix, C4a/C4b sections, standing lessons from the port |
| `docs/PHASE_6_RUST_WORKER_PLAN.md` | Phase 6C — the next big structural item |

### Completed phase plans and walkthroughs
`docs/PHASE_0_ARCHITECTURE_AUDIT.md` · `docs/PHASE_2_REACT_STATUS.md` ·
`docs/PHASE_2R_A_VITE_PROXY_PLAN.md` (+ `_WALKTHROUGH`) ·
`docs/PHASE_2R_B_RUST_SPA_PLAN.md` (+ `_WALKTHROUGH`) ·
`docs/PHASE_2R_C_PROXY_BRIDGE_PLAN.md` (+ `_WALKTHROUGH`) ·
`docs/PHASE_2R_D_E2E_PLAN.md` (+ `_WALKTHROUGH`) ·
`docs/PHASE_2R_REACT_RUST_INTEGRATION_PLAN.md` ·
`docs/PHASE_3_POSTGRESQL_MIGRATION_PLAN.md` (+ `_WALKTHROUGH`) ·
`docs/PHASE_4_RUST_API_PLAN.md` (+ `_WALKTHROUGH`) ·
`docs/PHASE_5A_PROGRESS_API_PLAN.md`, `5B_MEDIA_STREAMING_PLAN.md`,
`5C_SUBTITLES_PLAN.md`, `5D_PREVIEWS_PLAN.md`, `5E_TRANSCODING_PLAN.md` (each + `_WALKTHROUGH`) ·
`docs/REPOSITORY_ASSESSMENT_AND_ROADMAP.md` ·
`docs/NATIVE_SUBTITLES_AND_CLEANUP_WALKTHROUGH.md` ·
`docs/POSTERS_AND_SEEKBAR_CONTROLS_PLAN.md` (+ `_WALKTHROUGH`)

### Transcode correctness — read before touching the pipeline
| Doc | What it holds |
|---|---|
| `AGENTS.md` §6 "HLS cache integrity" | **The most pitfall-dense section in this repository.** Frame accounting, strided segment layout, ENDLIST rules, the accepted-loss recorder |
| `docs/TRANSCODE_CORRECTNESS_AND_TELEMETRY.md` | Every number behind the transcode strategy, with measurements |
| `docs/MULTI_GPU_CHUNKED_TRANSCODING_PROPOSAL.md` | The multi-GPU chunk architecture |

Tools: `scripts/hls_frame_audit.py`, `scripts/hls_content_gap_inventory.py`,
`scripts/hls_gop_matrix.py`, `scripts/hls_restore_endlist.py`,
`scripts/final_verification_battery.py`, `scripts/snapshot_live_data.py`.

### Operations
`docs/WINDOWS_SETUP.md` · `docs/DEVELOPMENT_STATUS.md` ·
`docs/RUST_SERVICE_MANAGEMENT_PLAN.md` (+ `docs/RUST_SERVICE_WALKTHROUGH.md`) ·
`docs/SERVICE_WATCHDOG.md` (removed — do not re-arm) ·
`docs/BACKUP_AND_RESTORE.md` · `docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md` ·
`docs/STREAMING_BENCHMARK_REPORT.md` · `docs/LOAD_TESTING.md` ·
`docs/WINDOWS_PURGE_INVESTIGATION.md`

### Clients and auth
`docs/FLUTTER_CLIENT_STATUS.md` (**the `run_flutter_tests.ps1` rule lives here**) ·
`docs/FLUTTER_PLAYER_PARITY.md` · `docs/ANDROID_APP_DISTRIBUTION.md` ·
`docs/OPENING_SEQUENCE.md` · **`docs/AUTHENTICATION_PLAN.md` (required before `/auth/*` and
`/api/admin/*`)** · `docs/MANUAL.md`

### Earlier handoffs
Superseded by this one. Read the **newest** file in `Handoffs/` only; previous:
`Handoffs/2026-10-16_00-40_opencode_watchdog-and-recon-complete.md`,
`Handoffs/2026-10-15_05-15_Antigravity_Gemini 3.8 Flash.md`, and earlier.

---

## 11. Traps that will cost you time

1. **Never run bare `flutter test`.** Use `scripts/run_flutter_tests.ps1`. It purges
   media_kit's orphaned temp state before and after the run. Measured: 415 orphaned files caused
   2 failures in 6 runs *including a serial run*, so serial is not a fix.
2. **Never use `pg_ctl status`** to check PostgreSQL. Run by an admin account it cannot open the
   NetworkService postmaster and reports a healthy cluster as stopped. **Probe with a TCP
   connect to `127.0.0.1:5432`.**
3. **Repo `.ps1` files must stay pure ASCII.** PowerShell 5.1 mangles UTF-8 punctuation into
   parse errors.
4. **`git commit -m` with backticks breaks under PowerShell** — backtick is the escape
   character. Write the message to a temp file and use `git commit -F -`.
5. **Axum forbids overlapping wildcards** under one prefix. Register one wildcard and dispatch
   internally on string prefix (`/subtitles/{*path}` → `strip_prefix("embedded/")`). Getting
   this wrong **panics the router at startup** and takes down every other suite.
6. **Do not resolve `conftest` by module name** in Python tests — `tests/conftest.py` and
   `tests/integration/conftest.py` share a basename and whichever imports last wins.
7. **An empty HTTP 500 from a DLNA renderer means "I could not fetch that URL".** Check the
   listener address and the firewall rule before debugging cast logic.
8. **Always disconnect live Cast sessions, in a `finally`.** This was violated repeatedly
   earlier and is now enforced structurally.
9. **Git deploy verification compares full seconds**, not `HH:mm`.

---

## 12. Environment and live device reference

| Item | Value |
|---|---|
| Test receiver | Samsung DU7000 |
| IP | `192.168.1.8` (ports 8008 / 8009 / 9197 open) |
| This host's LAN IP | `192.168.1.16` |
| Cast device id | `cast:72d252f1-e63a-4248-5c46-ad2ad74229c8` |
| DLNA device id | `dlna:uuid:4a2c1cb1-4c46-403c-ac75-959805c43061` |
| Sample media | `2001 A Space Odyssey (1968) [BluRay] [1080p] [YTS.AM]/2001.A.Space.Odyssey.1968.1080p.BluRay.x264-[YTS.AM].mp4` |
| Public hostname | `media.anisparvez.in` (→ Flask `:8000`) |
| Storage | `E:\MediaServer` (app, `media.db`, HLS scratch, previews) · `D:\Flicks` (raw media, `.archive`, `.uploads`, `.deleted`) · `E:\pgdata` (PG) · `C:` unused by this project |

---

## 13. If you only remember five things

1. Read **`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`** and `AGENTS.md` §0/§6 before
   writing code.
2. When a Cast control misbehaves, **read pychromecast in the venv** before running an
   experiment. Eleven bugs, all found there in minutes after experiments had failed.
3. **Ack ≠ effect.** A returned success proves the receiver understood the envelope.
4. **A value that never changes means the lookup never matches**, not that the value is fixed.
5. Verify deploys by **artefact timestamp**, and push the branch.