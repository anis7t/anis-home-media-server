# Phase A — Flutter Client Contract Baseline & Flask Retirement Inventory

**Date:** 2026-10-16
**Branch:** `feat/rust-transcode-worker`
**Status:** Phase A complete (read-only inventory + guardrail repair)
**Related:** `AGENTS.md` §0, `docs/PHASE_6_RUST_WORKER_PLAN.md`

---

## 1. The three findings that changed the plan

### 1.1 The guardrail had never tested Rust

`scripts/probe_android_api.py` hardcoded `BASE = "http://127.0.0.1:8000"`.
Every "18/18 per contract" recorded in the docs therefore validated **Flask**,
not the migration target. On `:8001` eight of those endpoints are proxied
straight back to `:8000`, so the probe could pass while measuring nothing at
all about Rust.

Fixed: the probe takes `--base` (default unchanged at `:8000`, so existing
invocations and any Task Scheduler entry keep working). Both origins now
report independently.

### 1.2 The probe silently omitted four shipped endpoints

Cross-checking the client source rather than trusting the probe's own
docstring found real coverage holes:

| Endpoint | Declared in | Was probed before |
|---|---|---|
| `POST /api/scan` | `ApiEndpoints.scan` | **no** |
| `POST /api/transcode/start` | `ApiEndpoints.transcodeStart` | **no** |
| `POST /api/cast/play` | `cast_repository.dart:54` | **no** |
| `POST /api/cast/control` | `cast_repository.dart:67` | **no** |

All four are shipped, user-reachable features (manual scan, manual transcode,
casting). The probe is now 22 endpoints, not 18.

### 1.3 The probe was not side-effect free

Adding the mutating endpoints exposed a hazard: `POST /api/transcode/start`
was originally probed against a real title. On an **untranscoded** film that
starts a real multi-GPU transcode of the user's library. The first run was a
no-op only because *2001 A Space Odyssey* happened to be already complete —
luck, not design, and the probe picks `movies[0]` arbitrarily.

Fixed: the mutating transcode call now targets the synthetic filename
`rust_probe_nonexistent_title.mkv`, which exercises the route contract without
touching content. Verified: 404 on both origins, nothing written to
`cache/hls`.

---

### Phase C3a — device registration and keepalive, native

| Endpoint | Rust status |
|---|---|
| `POST/GET /api/devices/heartbeat` | **native** |
| `POST /api/devices/client-hints` | **native** |
| `GET /api/devices` | proxied (C3b) |
| `POST /api/devices/rename`, `/api/devices/delete` | proxied (C3b) |

C3b is deferred, not forgotten: those three are gated by
`is_admin_authorized()`, which resolves through the Google session in
`/auth/*` — the last slice. Porting them before auth would mean porting the
admin gate first, which is a larger change than it looks.

**The device id is the load-bearing detail.** It is cookie → `X-Device-Id` →
`sha256("<ip>|<ua>")` first 16 hex chars prefixed `dev_`, and every
`devices` row is keyed on it. Any divergence — a different separator, a
different hash slice — silently fragments the fleet view into duplicate
devices, one per client per change, with no error anywhere. It is pinned by
a test against the Python formula rather than trusted.

**`ConnectInfo` is required, not cosmetic.** Flask classifies the connection
from `remote_addr`. Without the peer address every client is `127.0.0.1` and
`connection_type` reads "Localhost" for every real device. The router is now
served with `into_make_service_with_connect_info::<SocketAddr>()`.

In axum 0.8 `Option<ConnectInfo<_>>` **does not compile** — `Option<T>` now
requires `OptionalFromRequestParts`, which `ConnectInfo` does not implement.
It is taken directly and placed before the final extractor.

**`/proc/net/arp` is Linux-only.** `resolve_mac_address` reproduces the
Windows behaviour Flask already has ("LAN (ARP Pending)") rather than
implementing an ARP read that would change what the dashboard displays.

**GeoIP keeps Flask's 1.5 s budget** and stays best-effort: a lookup failure
degrades to the default label and never turns a keepalive into a failed
request.

Two defects were caught while building this slice:

1. **UA model extraction was greedy across `;` segments.** Python's regex
   `;\s*([^;]+?)\s+Build/` stops at the first `;` and yields `SM-A536E`; a
   naive "text between the first `; ` and the marker" yielded
   `Android 13; SM-A536E`, which matched no make rule and collapsed every
   Android device to "Generic Client".
2. **A pre-existing proxy test used `/api/devices/heartbeat` as its example
   of a proxied POST.** Once that endpoint went native the test kept passing
   while testing the wrong thing. It now uses `/api/devices/rename`, which
   is still proxied. This is the general hazard: a proxy test pins a path,
   and the path moving is silent.

#### A third defect, found only by comparing the two live engines

The unit test for the device id was named
`deterministic_id_matches_python_formula` and asserted prefix, length and
self-determinism. **It never compared against Python.** It passed while the
formula diverged, because the name claimed a parity nobody checked.

Querying both live engines with identical inputs settled it:

| Engine | Matches Python's formula |
|---|---|
| Flask `:8000` | **7/7** |
| Rust `:8001` | **6/7** |

The failing case was a User-Agent containing an obs-text byte. Rust read
headers with `HeaderValue::to_str()`, which accepts only visible ASCII, so
`café-tracker/1.0` failed to decode and was treated as **absent** — then
hashed as the empty string and given a different `device_id`. Werkzeug
decodes those bytes as latin-1, so Flask hashed the real string.

Consequence: every such client splits into **two device rows**, with no
error anywhere, because rows are keyed on this value.

Headers are now decoded by mapping each byte to the code point of the same
value, matching Werkzeug exactly. ASCII behaviour is unchanged. The unit
test is replaced by **golden values captured from the live Flask engine**,
and a request-level test covers the latin-1 case — the hash function was
always correct, so only a request-level test could have caught this.

> **The lesson generalises past this slice:** a green test named after a
> parity claim is not evidence of that parity. When porting, assert against
> values captured from the *old engine*, not against shape.

### Phase C4a — DLNA native, verified against the live DU7000

Discovery is byte-identical to Flask (`id`, `control_url`, `model`,
`location`). Full transport sequence confirmed **from the renderer's own
reported state**, never from our UI, with the TV fetching from Rust's own
port — no `origin` override:

| Command | TV reported |
|---|---|
| `play` | `buffering` → `playing`, `pos=1.081` |
| `pause` | `state=paused` |
| `seek 1800` | `pos=1806.269` |
| `play` (resume) | `state=playing`, `pos=1838.128` |
| `volume 45` | `volume=45.0` |
| `mute true` / `false` | `muted=True` / `False` |
| `stop` | `state=stopped` |

Client contract probe 22/22 on both origins; 174/174 Rust tests.

#### Three defects that only a live TV could find

1. **`/api/cast/pause` and `/stop` were unusable.** They returned
   `"pause needs a numeric value"`. Only `seek`, `volume` and
   `subtitle_offset` carry a number; for transport actions a missing value is
   normal. The contract tests never issued those two without a value — the
   live test did, on its first try.

2. **`MediaServerRust` bound `127.0.0.1`.** Flask binds `0.0.0.0`. A cast
   receiver must fetch media from this host, and the Cloudflare tunnel must
   reach it once it takes `:8000`. It hid because every test and probe goes
   through `127.0.0.1`, so the service looked healthy from this machine while
   being invisible to every other device on the network.

3. **No Windows Firewall inbound rule for `media-server-api.exe`.** Flask has
   one for `python.exe`. Without it the TV cannot reach `:8001` even though
   the host can, and a DLNA renderer answers `SetAVTransportURI` with an
   **empty HTTP 500** when it cannot fetch the URL it was just given — so it
   presents as a cast bug rather than a firewall one. Proven by re-casting
   with `origin` pointed at `:8000`, which played immediately. The rule is
   created idempotently by the installer, and is required for the port swap.

> **An empty 500 from a renderer means "I could not fetch that URL".** That is
> a reachability question, not a cast bug, and the empty body gives no hint of
> it. Two separate layers (bind address, then firewall) produced the same
> symptom, which is why the second was only found by isolating `origin`.

### Phase C4b — Google Cast native (in progress)

Four milestones, three of them verified against the live receiver.

| Milestone | State |
|---|---|
| Protobuf `CastMessage` + framing | ✅ byte-exact, unit-tested |
| Eureka discovery | ✅ live `ssdp_udn`, id matches Flask exactly |
| TLS transport, `CONNECT`, request/response | ✅ **verified live** |
| `LAUNCH` + app `transportId` session | ✅ **verified live** |
| `LOAD` → playback | ✅ **verified live** (`PLAYING`, 1920×864) |
| Resume at a position | ✅ **verified live** (`pos=600.0` from the receiver) |
| Seek after a dropped session | ✅ **verified live** — recovers by redialling |
| Volume | ✅ **verified live** by watching/listening; `receiver` namespace only |
| Mute | ✅ **verified live** — `SET_VOLUME` with a `muted` field, not `SET_VOLUME_MUTED` |
| Quit-app teardown | ✅ **fixed** — `STOP` + `sessionId`, not the non-existent `STOP_APP` |

`scripts/verify_cast_live.py` runs the whole sequence against real hardware.
Its `stop` lives in a `finally` and it exits non-zero if the receiver is still
playing, because a verification harness that can leave a film playing on
someone's television is not a verification harness.

#### Quit-app is `STOP` + `sessionId`, and `STOP_APP` never existed

The teardown was sending `{"type": "STOP_APP"}` on the `receiver` namespace.
`STOP_APP` is not a real message type. The receiver accepts it, answers, and
leaves the app running — the television sits on the blank receiver screen while
`stop` returns `ok: true`.

pychromecast, which backs the working Flask path, sends:

```python
def stop_app(self, *, callback_function=None) -> None:
    return self.send_message({MESSAGE_TYPE: "STOP"}, inc_session_id=True, ...)
# socket_client.send_message:  if inc_session_id: data["sessionId"] = self.session_id
```

So the message is **`STOP`**, and it carries **`sessionId`** — read from
`applications[].sessionId` in `RECEIVER_STATUS`, the same entry that carries
`transportId` (`receiver.py:296`).

I initially attributed this to a screen-redraw lag and documented it as a
harmless residual. That was wrong: there was no lag to tolerate, and the message
had never worked. The earlier run that reported the app gone was the receiver's
own idle timeout firing during the wait, not the quit landing.

Two habits were worth the detour:

- **The wrong message type is reported as success.** Every invented type in this
  port — the media `transportId`, `SET_VOLUME_MUTED`, `STOP_APP` — was
  acknowledged. An ack proves the receiver understood the *envelope*.
- **Reading the working client beats hypothesising.** All three of these were
  found in about a minute in `venv/Lib/site-packages/pychromecast`, which was on
  disk the entire time, after two rounds of live experiments had failed to
  explain them. When a control fails on an otherwise healthy connection, diff
  its payload against the implementation that works before concluding the device
  lacks the feature.

#### The list-shaped `status` caused three separate bugs

`MEDIA_STATUS.status` is a **list** on this receiver and an object elsewhere.
Reading it directly produced three unrelated symptoms:

| Symptom | Reality |
|---|---|
| Position reported as `0` on a playing cast | Working, at 600 s |
| `seek` refused with "no media session yet" | Session existed and was playing |
| "STILL PLAYING" after a successful `stop` | Receiver idle (Flask agreed) |

Two of the three read as *"casting is broken"* when casting was working
perfectly. The consolidation into one `status_object` helper is what ended the
pattern — the individual fixes did not, because the same shape assumption had
been written in a second and third place.

#### Mute: there is no `SET_VOLUME_MUTED`

`SET_VOLUME_MUTED` is accepted with `ok: true` and does nothing — which reads
as "this receiver has no mute", and is what I concluded before being corrected.
The real cause is that **the message type does not exist**. pychromecast, which
backs the working Flask path, sends:

```python
self.send_message({MESSAGE_TYPE: "SET_VOLUME", "volume": {"muted": muted}})
```

Mute is a field on `SET_VOLUME`, not a separate message type. A wrong type is
acknowledged and ignored, so the failure is indistinguishable from an
unsupported feature unless you compare the payload against a working client.

**`status.volume` is the application's volume, not the television's speaker
volume.** It reads 100 no matter what is set, even while the speakers are
demonstrably moving. It must not be presented as the audible level, and no test
may assert on it — that reports false failures for a command that works, and
would equally pass a broken one.

> This is the fourth time in this port that "the receiver confirms it" turned
> out to be evidence about the receiver rather than about playback. An ack, an
> echoed field and a returned success are statements about the protocol, not
> about whether anyone can hear or see the result. Where a human can watch the
> outcome, the human is the better oracle — and a test that cannot measure the
> thing must say so rather than guess.

#### Two places the wire disagrees with the documentation

Both were found by looking the spec up, and **both fail silently** — the
receiver accepts the message, plays, and reports no error.

**1. `currentTime` is a sibling of `media`, not a member of it.**

```
| media       | MediaInformation | ...
| autoplay    | boolean | optional
| currentTime | double  | optional  Seconds since beginning of content.
```

Nesting it inside `media` — where it reads more naturally — is ignored
entirely: the LOAD succeeds, playback starts from zero, and a resume cast
appears to work while losing the user's position. 210 green tests did not catch
it; watching the television did.

**2. `MEDIA_STATUS` carries `status` as a list on this receiver.**

Google specifies an object. The DU7000 sends
`{"type":"MEDIA_STATUS","status":[{"playerState":"PLAYING",...}]}`, and `[]`
while idle. Parsing it as an object returned nothing at all, so a *perfectly
playing* cast reported `state=unknown`, `position=0`, with no error — which
reads exactly like "casting is broken" when it is working perfectly. Both
shapes are now accepted.

> Combined lesson: **a receiver that disagrees with the documentation does so
> silently.** Neither of these produced an error, a fault, or a missing field
> — only a wrong value, in a system where every other signal says success.

#### A cached dead connection is worse than a missing heartbeat

Playback worked, then stopped being controllable: `seek`, `volume` and `mute`
all failed with `os error 10053`, and **`stop` failed too** — so the cast was
permanently unstoppable until the service was restarted. Verified live: a
dropped session left the television playing and `stop` could not be delivered.

The connection cache held a dead socket indefinitely. A receiver resets the
socket on its own, and a cached dead socket fails every later command
identically. The cast looks fine and is inert.

That reframes the heartbeat question. pychromecast does:

```python
self.heartbeat_controller.ping()
...
if self.heartbeat_controller.is_expired():
    logger.info("Heartbeat timeout, resetting connection")
    reset = True
```

The heartbeat's real job is **detecting a dead connection and reconnecting**,
not merely keeping one warm. Missing that detection turned a dropped session
into a permanent outage.

Every action and every status read now runs at most twice: on failure the dead
connection is dropped, the session is redialled, and the action is retried
once. Redialling re-runs the whole app session — launch, read the
`transportId`, `CONNECT` — because that id is per-session, and reusing a stale
one is exactly what produced the original `CLOSE`.

#### The media namespace must be addressed at a per-session UUID

`LOAD` was answered with a `CLOSE` on the connection namespace and no reply,
against real hardware. Root cause:

The documented address for the media namespace is the constant
`urn:x-cast:com.google.cast.media-receiver`, and that is what the port
originally sent. **It is wrong in practice.** A receiver reports a
**per-session UUID** as the launched application's `transportId`, and that is
the only address a media message may be sent to. Addressing the constant is
equivalent to addressing an application that does not exist, so there is no
virtual connection to it — and the receiver says so by closing the connection.

Measured on the DU7000:

```
DIAG media receiver transportId=d6588793-2fd5-4d73-9d3c-a0ed1f584088
MEDIA_STATUS requestId=77 -> playerState PLAYING, videoInfo 1920x864
```

There are therefore **two** steps, not one: launch the app, then `CONNECT` to
its reported `transportId`, then send `LOAD`. Connecting only to `receiver-0`
is not enough. VLC's implementation is explicit:

```c
m_appTransportId = json_get_str_view(p_app, "transportId");
m_communication->msgConnect( m_appTransportId );
```

> This was found by **looking the protocol up**, after several rounds of
> hypothesising from a live trace were not enough. The lesson is not "be
> cleverer at guessing" — it is that a documented constant in an example is
> evidence about the *documentation*, not about the wire.

The documented constant is retained only as a fallback for a receiver that
reports no transport id, and is not used in the working path.

#### Two related faults fixed alongside

- **The running app is reported as `status.appId` on some receivers and under
  `status.applications[]` on others.** Reading only the former reported an
  already-launched app as absent and waited out the whole timeout for
  something that had already started.
- **A receiver may `PING` us and expects `PONG`.** Unanswered, it tears the
  virtual connection down, which surfaces as a `CLOSE` mid-request.

And `LAUNCH_STATUS: USER_ALLOWED` is not the same as "the app is up": both the
status ack and the matching `RECEIVER_STATUS` arrive *seconds* after the
request, so sequencing on the ack puts the next message into a gap the receiver
has not opened yet.

#### rustls cannot talk to a Cast receiver

The DU7000 presents a **self-signed X.509 v1** certificate:

```
subject : CN=72d252f1-e63a-4248-5c46-ad2ad74229c8
issuer  : CN=72d252f1-e63a-4248-5c46-ad2ad74229c8
version : 1
```

`rustls-webpki` accepts **only v3**, and rejects a v1 certificate while
extracting its public key — *before* any custom verifier runs. No verifier
configuration can work around it; this is structural. C4b therefore uses the
Windows Schannel stack through `native-tls`, which accepts v1 and needs no C
toolchain.

Only the trust *chain* is bypassed. Schannel still verifies the handshake
signature against the certificate's public key, so a passive third party cannot
simply impersonate the television.

#### `cargo.bat` never set `INCLUDE`

It set `PATH` and `LIB` for MSVC, which is everything a pure-Rust build needs,
so the omission was invisible for months. The first crate with C sources
(`ring`) failed with the least informative error available — `cl.exe` ran and
returned exit 2 — and the real cause was `fatal error C1083: Cannot open
include file: 'stddef.h'`. Any crate with C code would have hit this, not just
TLS.

#### Discovery is deliberately not mDNS

Flask's primary path is mDNS/zeroconf. C4b uses the eureka endpoint
(`http://<host>:8008/setup/eureka_info`) over a candidate set built from three
sources: DLNA hosts just found, Cast hosts a previous scan saw, and the IPv4
neighbour table read natively via `GetIpNetTable` rather than shelling out to
`arp -a`.

This was verified against the live receiver *before* the code was written —
the eureka endpoint returns `ssdp_udn=72d252f1-…`, byte-identical to the device
id Flask reports.

**Known coverage reduction:** a Cast device absent from the neighbour table
*and* not visible to SSDP would be found by Flask and missed here. Recorded
rather than buried.

#### Two behaviours that are each a previously-diagnosed bug

- **`streamType: BUFFERED`.** pychromecast defaults to `LIVE`; a receiver told
  the stream is live treats it as unseekable — "the TV ignores seeks".
- **`currentTime` inside `LOAD`.** A receiver rejects a `Seek` sent in the gap
  before its media session exists ("Failed to execute seek 180.0"), which is
  how a resume cast silently started from the beginning.

#### A receiver in standby reports no volume

The live `GET_STATUS` reply is
`{"status":{"isActiveInput":false,"isStandby":false}}` — no volume field. Volume
is only reported while an app is active, so the default must be **100, not 0**;
inventing 0 would tell the user their television is muted.

## Standing lessons from the port

Things that cost real time and are not visible from the code. Each was found
by doing the thing for real, not by reading it.

1. **An empty HTTP 500 from a DLNA renderer means "I could not fetch that
   URL."** It is a reachability question wearing a cast bug's clothes, and the
   empty body gives no hint. Two separate layers produced it — the service
   binding `127.0.0.1`, then a missing Windows Firewall rule for
   `media-server-api.exe`. Only re-casting with `origin` pointed at a
   known-good port separated them.

2. **A service that binds loopback looks perfectly healthy from the machine it
   runs on.** Every test, probe and health check goes through `127.0.0.1`, so a
   loopback-only bind is invisible to the entire test suite while being
   invisible to every other device on the network — and to the Cloudflare
   tunnel.

3. **A green test named after a parity claim is not evidence of that parity.**
   `deterministic_id_matches_python_formula` asserted prefix, length and
   self-determinism. It passed while the formula diverged from Python's. Assert
   against values captured from the *old engine*, not against shape.

4. **A discarded `Future` compiles.** On a tokio `UdpSocket`, `let _ =
   sock.send_to(..)` builds a future and drops it, so no datagram is ever sent
   and discovery returns an empty list with no error. A green suite and a
   well-formed empty response both look like success.

5. **Measure, then assert.** "eureka works" was believed for two milestones
   before being measured. When it was measured, the first measurement said
   *nothing answered* — and that measurement was itself wrong, because
   `Start-Job` launches separate PowerShell processes whose startup time blew
   the timeout. Sequential probing found the receiver immediately. A wrong
   number is worse than no number.

6. **rustls cannot speak to Cast.** X.509 **v1** certificates are rejected by
   `rustls-webpki` during key extraction, before any verifier runs. Measure
   the peer's certificate rather than assuming.

7. **`scripts/cargo.bat` omitted `INCLUDE`.** Invisible for every pure-Rust
   build; the first crate with C sources failed with `cl.exe ... exit 2` and
   the real message, `C1083: Cannot open include file: 'stddef.h'`, was buried
   in a warning.
8. **A receiver's field layout is not uniform.** The running Cast app appears
   as `status.appId` on some receivers and under `status.applications[]` on
   others; reading only one path reports a working app as absent and then
   waits out the whole timeout for something that already launched.
9. **"Accepted" is not "running".** `LAUNCH_STATUS: USER_ALLOWED` and the
   matching `RECEIVER_STATUS` both arrive seconds after the request. Sequencing
   on the ack alone puts the next message into a gap the receiver has not yet
   opened.
10. **A constant in the documentation is evidence about the documentation.**
    `urn:x-cast:com.google.cast.media-receiver` is what the docs and most
    examples show; the wire actually wants the per-session `transportId` the
    receiver reports. Several rounds of hypothesising from a live trace did not
    find this. Looking the protocol up did, in one step.
11. **A receiver that disagrees with the docs does so silently.** `currentTime`
    nested in `media` instead of beside it, and `status` arriving as a list
    instead of an object, were both accepted with no error and a wrong result.
    In a system where every other signal reads "success", a wrong value is the
    only symptom — and no test that asserts on *shape* will ever see it.

### Phase C2 — `/api/media-info/{f}` native (verified)

| Check | Result |
|---|---|
| Status parity, 36 titles | 36/36 identical |
| Response key sets | 36/36 identical |
| Field-by-field values, 17 fields × 36 titles | identical except `rating` (see below) |
| Duration | **identical on all 36** |
| Latency, full sweep | Flask 9.7 s vs Rust 4.9 s cold (**2.0×**); ~34× once the probe cache is warm |

Three real defects were found by this sweep and fixed, none of which the
unit tests had caught:

1. **All metadata silently null.** `vote_average` is a PostgreSQL `real`
   (float4); decoding into `f64` failed the entire row and the swallowed
   error produced an all-null block — every title reported no title, genres,
   rating or runtime.
2. **Duration 57 ms long.** Matroska writes its video-end signal as a
   timestamp (`DURATION-eng` = `"01:40:06.042000000"`), and on a real MKV
   both `stream.duration` and `duration_ts` were absent, so that tag was the
   only source. Parsing it as a float failed silently and fell through to the
   container duration.
3. **Duration 4.25 s long on one title.** `source_video_duration` has three
   tiers and only two were ported. A library MKV has neither a stream
   duration nor any DURATION tag, so only a *packet scan* answers — jumping
   to the container midpoint and reading forward to the last video packet.
   Without it the container duration is reported, overstating the
   denominator by however much audio outlives the picture.

**Remaining difference is data, not code.** `rating` differs on 9 of 36
titles: SQLite stores `6.4` where PostgreSQL stores `6.389`. Verified
directly in both databases. This is pre-existing divergence between the two
stores, and PostgreSQL holds the more precise value; Flask simply reads the
other store.

> **Updated 2026-10-16, after Phase C1a + C1b + C2 + C3a.** All three
> artwork endpoints, `/api/media-info/{f}` and both device keepalive
> endpoints are now native and removed from the proxy map, leaving
> **7 proxied** (was 10) and **2 absent**:
>
> | Endpoint | Rust status now |
> |---|---|
> | `GET /poster/{*filename}` | **native** (C1a) |
> | `GET /tmdb-poster/{id}` | **native** (C1b) |
> | `GET /tmdb-backdrop/{id}` | **native** (C1b) |
> | `GET /api/media-info/{f}` | **native** (C2) |
> | `POST /api/devices/heartbeat` | **native** (C3a) |
> | `POST /api/devices/client-hints` | **native** (C3a) |
> | `GET /api/devices` | proxied (C3b, needs auth) |
> | `POST /api/devices/rename`, `/api/devices/delete` | proxied (C3b, needs auth) |
> | `GET/POST /api/cast/*` | proxied |
> | `POST /api/scan` | proxied |
> | `POST /api/transcode/start/{f}` | **absent** |
> | `GET /api/app/update`, `/api/app/download` | **absent** (not proxied either) |
>
> Verified live against Flask: byte-identical artwork, identical
> `Content-Length` and identical `Last-Modified` (so cached copies survive the
> port swap), traversal refused on both, download failure is 404 and never
> 500. TMDb download behaviour was measured before choosing the retry policy:
> 420 requests across 70 distinct assets at concurrency 12 over 6 rounds,
> 420/420 × 200, p95 0.66 s, no `Retry-After`, no throttling — so retries
> cover transient network errors, not rate limits.
>
> **Pre-existing limitation, inherited rather than introduced:** artwork cache
> files are keyed only on `tmdb_id`, so if TMDb re-encodes an image the cache
> never refreshes it. Observed live: two posters differed from their
> previously-cached copies at the same 500×750 dimensions, and a Python fetch
> of the identical URL returned exactly the bytes Rust wrote — i.e. upstream
> drift, not a defect. Flask behaves identically.

Probe run 2026-10-16, both origins, 22 endpoints.

| Endpoint | Flask :8000 | Rust :8001 | Rust status |
|---|---|---|---|
| `GET /api/movies` | 200 | 200 | native |
| `GET /api/movie/{f}` | 200 | 200 | native |
| `GET /api/system-status` | 200 | 200 | native |
| `GET /api/devices` | 200 | 200 | **proxied** |
| `POST /api/devices/heartbeat` | 200 | 200 | **native** (C3a) |
| `POST /api/devices/client-hints` | 200 | 200 | **native** (C3a) |
| `GET /api/transcode-status/{f}` | 200 | 200 | native |
| `GET /api/progress` | 200 | 200 | native |
| `GET /api/media-info/{f}` | 200 | 200 | **proxied** |
| `GET /api/cast/devices` | 200 | 200 | **proxied** |
| `GET /api/cast/status` | 400 (idle) | 400 (idle) | **proxied** |
| `POST /api/cast/play` | 400 | 400 | **proxied** |
| `POST /api/cast/control` | 400 | 400 | **proxied** |
| `POST /api/scan` | 403 | 403 | **proxied** |
| `POST /api/transcode/start/{f}` | 200 | **404** | **absent** |
| `GET /api/app/update` | 404 | 404 | **absent (not proxied either)** |
| `GET /api/app/download` | 404 | 404 | **absent (not proxied either)** |
| `GET /tmdb-poster/{id}` | 200 | 200 | **proxied** |
| `GET /media/{f}` | 200 | 200 | native |
| `GET /hls/{f}/playlist.m3u8` | 200 | 200 | native |
| `GET /subtitles/{f}` | 404 | 404 | native |
| `GET /poster/...` | 404 | 404 | **proxied** |

**Proxied count has fallen 10 → 7 across C1a, C1b, C2 and C3a; 2 are absent
entirely.** Rust cannot serve `:8000` yet.

> **Updated after C4a and C4b.** Casting is now native for both device kinds —
> DLNA and Google Cast — so `/api/cast/*` no longer appears in this table.
> What remains proxied: `/auth/*`, `/api/auth/*`, `GET /api/devices` +
> rename/delete (C3b, admin-gated), `POST /api/scan`, and `/api/storage/*`.
> See the C4a and C4b sections for the live-TV verification and the defects
> only a real renderer or receiver could find.

### 2.1 A false green that must be closed

`POST /api/transcode/start` returns **404 on Rust** — the route does not
exist — yet the probe reports OK, because 404 is in the acceptable set for
mutating routes. `/api/app/*` is worse: the probe documents 404 as "route
present, nothing published for that channel", but on `:8001` it 404s because
**the route is missing**, so the in-app updater is simply absent and the probe
calls that a pass.

Before `:8001` becomes canonical these two must be tightened to distinguish
*route missing* from *route present, nothing published*. A guardrail that
cannot tell those apart stops being a guardrail.

---

## 3. Port ownership — the cutover constraint

The installed APK ships pointing at `http://127.0.0.1:8000`
(`settings_service.dart:32-34`, `player_poc_screen.dart:138`), overridable by
the user. Installed apps cannot be patched by us.

Therefore repointing the Cloudflare tunnel is **not** sufficient: it fixes new
sessions but leaves every already-installed app pointed at Flask. The plan
adopted is a **port-ownership swap** — Rust serves `:8000`, Flask moves to a
secondary port for rollback only. That keeps the client contract literally
unchanged and makes the probe validate whatever owns 8000 automatically.

This requires Phase C (full native parity) to complete **before** the swap;
B and C interleave rather than running strictly in sequence.

---

## 4. Flask surface still to be retired

From `app/routes/*.py` route decorators, beyond the client surface:

| Area | Routes | Client-visible |
|---|---|---|
| Transcoding | `/api/transcode/start`, `/api/transcodes`, `/api/media-readiness` | partially |
| Upload | `/api/upload`, `/api/upload/chunk/{init,<id>,<id>/complete}` | no (web) |
| Admin | `/api/admin/{verify,status,pin}` | no |
| Media delete | `DELETE /api/media/{f}`, `/api/media/delete/{f}` | no |
| Storage | `/api/storage/{audit,settings,purge-orphans,archive}` | no |
| Auth | `/auth/*`, `/api/auth/{me,tokens,tokens/<id>,allowlist}` | web only |
| Devices admin | `/api/devices/rename`, `/api/devices/delete` | no |
| Subtitles upload | `/api/upload-subtitle/{f}` | no (native in Rust) |
| Scanner | `scanner_service` + `cache-maintenance-worker` background loops | no |
| Metadata refresh | `metadata-refresh-worker` 4-hourly | no |

Background workers are the non-obvious part: `auto_transcoder_loop`,
`cache-maintenance-worker` and `metadata-refresh-worker` have no HTTP surface
and will not appear in any route inventory. They must be ported explicitly or
they will die silently with Flask.

---

## 5. Phase A exit criteria — met

- [x] Probe accepts `--base`, default unchanged.
- [x] Probe run against both origins, 22/22 each.
- [x] Client surface cross-checked against `ApiEndpoints`, `cast_repository`,
      `player_media_resolver` — not the probe's own docstring.
- [x] Per-endpoint native/proxied/absent matrix recorded.
- [x] Probe side effects removed and verified.
- [x] Known false-green documented for later tightening.