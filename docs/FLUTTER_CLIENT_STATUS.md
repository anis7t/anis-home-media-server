# Flutter Client — Phase Status & Handoff

> **Last updated:** 2026-09-24
> **Active branch:** `feat/flutter-player-poc`
> **Source conversations:** `8478b150-1239-4291-9a25-9155d6f2ad87` (Phase 1 & 2 work), `995057c0-0007-447a-93e5-ea547828e71c` (2B/2C/2D timing fix)
> **Purpose:** Persistent handoff document. Read this before touching the Flutter client.

---

## Phase Overview

| Phase | Title | Status |
|-------|-------|--------|
| 1 | Flutter Client Foundation | COMPLETE — committed (`5b0b1fa`, `eadb257`) |
| 2 | Video Player Proof-of-Concept | IN PROGRESS — fix committed (`6de915a`), **awaiting live battery re-run on LAN + WAN** |
| 3 | (TBD — production player UI) | Not started |

---

## Phase 1 — Flutter Client Foundation (DONE)

Committed on `feat/flutter-player-poc`:

```
eadb257  feat: initialize Flutter media client with connection screen,
               media player POC, and core architecture
5b0b1fa  feat: add Flutter client foundation
```

### What was built

- `flutter_client/` — standalone Flutter project (Windows desktop target)
- `lib/core/` — shared utilities, device identity, server config
- `lib/features/connection/` — server connection screen + live registration
- `lib/features/player_poc/` — player POC feature (see Phase 2)
- `flutter_client/test/` — 24 passing unit + integration tests
- `pubspec.yaml` — `media_kit` + `media_kit_video` + `media_kit_libs_windows_video`

### Verified at sign-off

- `flutter doctor -v` — Windows toolchain green
- `flutter analyze` — zero issues
- 24/24 `flutter test` pass (including live server HTTP contract tests)
- Live server connection from Flutter app to `http://192.168.1.16:8000` confirmed

---

## Phase 2 — Video Player Proof-of-Concept (IN PROGRESS)

**Goal:** Technical validation only — not a production player. Proves that
`media_kit`/libmpv can handle all server media types and network topologies
before any production UI is built.

### Architecture

```
PlayerPocScreen  (UI harness + automated test battery)
    |
PlayerControllerInterface  (pure abstract contract)
    |
MediaKitPlayerAdapter  (wraps media_kit Player + VideoController)
    |
media_kit / libmpv
    |
Media Server  (RFC 7233 range, HLS, seek-preview, device auth)
```

### Key files

| File | Role |
|------|------|
| `flutter_client/lib/features/player_poc/domain/player_controller_interface.dart` | Abstract player contract |
| `flutter_client/lib/features/player_poc/infrastructure/media_kit_player_adapter.dart` | media_kit implementation |
| `flutter_client/lib/features/player_poc/presentation/player_poc_screen.dart` | Harness UI + automated test battery |
| `flutter_client/tool/wan_player_probe.dart` | Standalone CLI WAN probe (headless) |
| `flutter_client/tool/runtime_player_validator.dart` | Runtime validator tool |

### Test candidates (real library media)

| # | Candidate | Route type | Filename |
|---|-----------|------------|----------|
| 1 | Batman Knightfall Pt 1 2026 | Direct MP4 | `Batman Knightfall Part 1 2026 1080p WEBRip x264 AAC5 1-[YTS GG - YTS BZ].mp4` |
| 2 | Spider-Man: Brand New Day 2026 | HLS / multi-GPU | `Spider-Man- Brand New Day 2026.1080p.HQ Pre.Multi.AAC 2.0.x264.mkv` |
| 3 | Lust Stories 3 2026 | HLS + external SRT | `Lust Stories 3 2026.1080p.NF.WEB-DL.Multi.DD+ 5.1.x264-KIN.mkv` |
| 4 | I Want Your Sex 2026 | HLS + HEVC 10-bit + EAC3 | `I.Want.Your.Sex.2026.1080p.WEBRip.10Bit.DDP5.1.x265-NeoNoir.mkv` |

### Stage status (pre-fix results)

| Stage | Description | LAN (before fix) | WAN (before fix) |
|-------|-------------|------------------|------------------|
| 2A | Direct MP4 playback (Batman) | PASS | PASS |
| 2B | HLS multi-GPU stream (Spider-Man) | PASS | FAIL (was timing) |
| 2C | Seeking + checkpoint resume | FAIL (was timing) | FAIL (was timing) |
| 2D | Subtitles + HEVC 10-bit | PASS (HEVC) | FAIL (was timing) |
| 2E | Seek-preview frame scrubbing | PASS | not tested |
| 2F | Full WAN acceptance report | not started | not started |

### Fix applied — commit `6de915a`

Root cause: all stage runners used fixed `Future.delayed()` waits too short
for actual playback startup and seek-settle times, especially over WAN.

Fix: replaced every fixed delay with a `_waitFor()` polling helper that polls
every 300ms until a condition is met or a timeout fires. WAN-safe timeouts
are used universally (they resolve near-instantly on LAN too).

Polling conditions per stage:

| Stage | Polls for | Timeout |
|-------|-----------|---------|
| 2A | `_position > 0` | 30s |
| 2B | `_position > 0` (HLS startup) | 40s |
| 2C 0:00 seek | `_position < 3s` | 15s |
| 2C 300s seek | `_position` within 8s of 300 | 15s |
| 2C resume | `_position > 290s` then delta check | 30s |
| 2D-sub playback | `_position > 0` | 40s |
| 2D-sub tracks | `subtitleTracks.isNotEmpty` | 10s |
| 2D-hevc | `_position > 0` | 40s |
| 2E metadata | `!_previewMetaLoading && _previewMeta != null` | 20s |
| 2E image | `_previewImageUrl != null` | 5s |

All stages also now record actual startup latency (ms) via `Stopwatch` in
their detail string, giving empirical LAN vs WAN timing data.

### NEXT ACTION — live battery re-run required

The fix is committed and compiles clean (0 analyze issues, 24/24 tests pass).
The battery has NOT yet been re-run against the live server to confirm the fix.

**Steps for next agent/session:**

1. Kill any existing `flutter run` process
2. Run fresh: `& "D:\src\flutter\bin\flutter.bat" run -d windows --release`
   from `C:\MediaServer\flutter_client`
3. The battery auto-starts after a 3s countdown when the app opens
4. First run on LAN (toggle off) — verify 2A through 2E all PASS
5. Toggle WAN switch on (top-right) — re-run battery — verify 2A through 2E all PASS
6. Record timing values from the on-screen detail strings for the acceptance report

---

## Stage 2F — WAN Validation + Acceptance Report (not started)

After 2A–2E pass on both LAN and WAN, produce the final acceptance report
answering all 16 acceptance criteria (PASS / FAIL / NOT TESTED / N/A) with
an architectural verdict (GO / GO WITH CHANGES / BLOCKED).

The 16 acceptance criteria are:
1. Direct MP4 playback starts within acceptable latency on LAN
2. Direct MP4 playback starts within acceptable latency on WAN
3. HLS stream plays across chunk boundaries without stalling
4. HLS stream plays on WAN
5. Seeking to 0:00 works without freeze
6. Seeking to arbitrary position works
7. Resume convergence within tolerance (<5s delta)
8. Playback speed adjustment (0.5x–2.0x) works
9. External SRT subtitle track is discovered
10. Subtitle track selection renders correctly
11. HEVC 10-bit decodes correctly
12. E-AC-3 5.1 multichannel audio plays
13. X-Device-Id header is sent and accepted by server
14. Seek-preview metadata endpoint delivers frames
15. Rapid seek-preview scrub is independent of video player state
16. No architectural blocker prevents production player implementation

---

## Running the app

```powershell
cd C:\MediaServer\flutter_client
# Release (production-like performance)
& "D:\src\flutter\bin\flutter.bat" run -d windows --release
# Debug (hot-reload available for development)
& "D:\src\flutter\bin\flutter.bat" run -d windows
```

libmpv-2.dll is bundled automatically by `media_kit_libs_windows_video` on build.
Expected path: `build\windows\x64\runner\Release\libmpv-2.dll`

---

## Open questions for Phase 3

1. Phase 3 scope TBD — Phase 2 acceptance verdict drives the Phase 3 plan.
2. Cloudflare WAN delivery policies for large video files need review before
   treating the tunnel as a scalable distribution path.
3. Authentication must be added to the Cloudflare hostname before wider sharing.
