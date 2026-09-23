# Flutter Client — Phase Status & Handoff

> **Last updated:** 2026-09-24
> **Active branch:** `feat/flutter-player-poc`
> **Source conversation:** `8478b150-1239-4291-9a25-9155d6f2ad87`
> **Purpose:** Persistent handoff document. Read this before touching the Flutter client.

---

## Phase Overview

The Flutter migration is structured in phased milestones. Each phase must be explicitly approved before the next begins.

| Phase | Title | Status |
|-------|-------|--------|
| 1 | Flutter Client Foundation | COMPLETE — committed (`5b0b1fa`, `eadb257`) |
| 2 | Video Player Proof-of-Concept | IN PROGRESS — stages 2A-2E implemented, 2B/2C/2D failing on WAN; 2C failing on LAN |
| 3 | (TBD — production player UI) | Not started |

---

## Phase 1 — Flutter Client Foundation (DONE)

Committed as two sequential commits on `feat/flutter-player-poc`:

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
- `flutter_client/test/` — 15 passing unit tests
- `pubspec.yaml` — `media_kit` + `media_kit_video` + `media_kit_libs_windows_video`

### Verified at sign-off

- `flutter doctor -v` — Windows toolchain green
- `flutter analyze` — zero issues
- 15/15 `flutter test` unit tests pass
- Live server connection from Flutter app to `http://192.168.1.16:8000` confirmed

---

## Phase 2 — Video Player Proof-of-Concept (IN PROGRESS)

**Goal:** Technical validation only — not a production player. Proves that `media_kit`/libmpv can handle all server media types and network topologies before any production UI is built.

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

### Stage status

| Stage | Description | LAN | WAN |
|-------|-------------|-----|-----|
| 2A | Direct MP4 playback (Batman) | PASS | PASS |
| 2B | HLS multi-GPU stream (Spider-Man) | PASS | FAIL |
| 2C | Seeking + checkpoint resume | FAIL | FAIL |
| 2D | Subtitles (Lust Stories 3) + HEVC 10-bit (I Want Your Sex) | PASS (HEVC) | FAIL |
| 2E | Seek-preview frame scrubbing | PASS | not tested |
| 2F | Full WAN acceptance report | not started | not started |

### Root cause of 2B/2C/2D failures (unresolved — context was lost here)

All failures share the same root cause:

> The automated battery uses fixed `Future.delayed()` waits that are too
> short for actual playback startup and seek-settle times, especially over WAN
> where HLS startup latency is substantially higher than LAN.

Specific failures:

- 2C LAN: Position check fires before position settles after seek -> reads 0 -> false FAIL
- 2B WAN: HLS startup over Cloudflare tunnel exceeds fixed 5s delay -> position still 0 -> false FAIL
- 2C WAN: Same seek timing issue compounded by WAN latency
- 2D WAN: Media opens but position check fires too early

### Fix required (NEXT ACTION for the next agent/conversation)

Replace all fixed `await Future.delayed(const Duration(seconds: N))` calls in
the stage runners inside `player_poc_screen.dart` with polling loops:

```dart
Future<bool> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  Duration interval = const Duration(milliseconds: 300),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future.delayed(interval);
  }
  return false;
}
```

Apply to every stage:

| Stage | Old fixed delay | Polling condition |
|-------|----------------|-------------------|
| 2A | `Future.delayed(4s)` | `_position > Duration.zero` |
| 2B | `Future.delayed(5s)` | `_position > Duration.zero` |
| 2C (seek 0:00) | `Future.delayed(1500ms)` | `_position < Duration(seconds: 2)` |
| 2C (seek 300s) | `Future.delayed(2s)` | `(_position - 300s).abs() < 5s` |
| 2C (resume 305s) | `Future.delayed(3s)` | `(_position - checkpoint).abs() < 2s` |
| 2D subtitles | `Future.delayed(3s)` | `_position > Duration.zero` |
| 2D HEVC | `Future.delayed(4s)` | `_position > Duration.zero` |
| 2E preview | `Future.delayed(1200ms)` | `_previewMeta != null` |

Use 30s startup timeout and 15s seek settle timeout universally (WAN-safe, fine on LAN too).

---

## Stage 2F — WAN Validation (not started)

After 2B/2C/2D pass on both LAN and WAN, run a final WAN pass via
`https://media.anisparvez.in` and produce the acceptance report answering all
16 acceptance criteria (PASS / FAIL / NOT TESTED / N/A) with an architectural
verdict (GO / GO WITH CHANGES / BLOCKED).

---

## Running the app

```powershell
cd C:\MediaServer\flutter_client
# Debug
& "D:\src\flutter\bin\flutter.bat" run -d windows
# Release
& "D:\src\flutter\bin\flutter.bat" run -d windows --release
```

libmpv-2.dll is bundled automatically by media_kit_libs_windows_video on build.
Expected path: `build\windows\x64\runner\Release\libmpv-2.dll`

---

## Open questions for Phase 3

1. Phase 3 scope TBD. Phase 2 acceptance verdict drives the Phase 3 plan.
2. Cloudflare WAN delivery policies for large video files need review before
   treating the tunnel as a scalable distribution path.
3. Authentication must be added to the Cloudflare hostname before wider sharing.
