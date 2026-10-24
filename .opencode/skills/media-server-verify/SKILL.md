---
name: media-server-verify
description: Run and verify changes in Anis' Media Server correctly - Python pytest suite, Flutter/Android client suite, cache-isolation proof, and HLS cache audits. Use before claiming any backend or client change is verified, when running the test suites, when touching transcode_service/chunk_transcode_service/preview_service, when editing Flutter player code, or when investigating a stuck or corrupted HLS cache.
---

# Media Server: verification protocol

This project has two test suites and a set of hard-won invariants. Running the
wrong command, or running a suite without isolation, causes **real damage**:
a full pytest run once deleted the live transcode cache and wrote fixture rows
into the production database.

Read `AGENTS.md` and `docs/PROJECT_STATUS.md` before non-trivial work. This skill
covers the mechanical part: how to run things and how to prove nothing was harmed.

## Non-negotiable: never point tools at production state

| Thing | Never | Use instead |
| --- | --- | --- |
| HLS cache | `cache/hls` (real transcodes) | the throwaway tree `tests/conftest.py` builds |
| Database | `media.db` | the throwaway test DB; or `.opencode/db/media.snapshot.db` for read-only inspection |
| Media library | `D:\Flicks` | fixtures |
| Services | live `MediaServer` / `Cloudflared` NSSM services | local dev server |

`tests/conftest.py` redirects cache/DB/upload/archive paths onto a throwaway tree
**through the environment before `app` is imported**. That ordering is the whole
protection. If you ever need to change it, re-verify isolation the hard way
(below) before doing anything else.

## Python backend

```powershell
python -m py_compile app/config.py app/services/transcode_service.py app/services/chunk_transcode_service.py app/services/gpu_service.py
.\venv\Scripts\python.exe -m pytest tests/
```

Run py_compile on any file you touched even if pytest passes - pytest will not
catch a syntax error in a module nothing imports.

## Flutter / Android client

```powershell
.\scripts\run_flutter_tests.ps1
```

**Never a bare `flutter test`.** The script purges media_kit's orphaned
`...NativeReferenceHolder.$pid` temp files before and after the run; Windows
recycles PIDs, so a stale file makes a new test process inherit a dead heap
pointer and every `add()`/`remove()` hangs. Measured: 415 orphaned files caused
failures in 2 of 6 runs, including a `--concurrency=1` run, so serial is not a
fix. Details in `docs/FLUTTER_CLIENT_STATUS.md`.

Do not re-add `MediaKit.ensureInitialized()` to tests that do not need native
playback. Ordinary tests must never reach the live server - they use the
`HttpOverrides` allowlist in `test/support/test_network_guard.dart`; tests that
genuinely need it stay behind `liveServerSkip`.

Static analysis and analysis of Dart changes:

```powershell
cd flutter_client
dart analyze lib test
flutter analyze
```

## Proving isolation held (required after any conftest change)

Snapshot these three before and after a full `pytest tests/` run; all must be
byte-identical:

1. the library file list (`D:\Flicks`)
2. the production `movies` rows
3. the `cache/hls` directory list **plus a hash of each**

If any changed, the suite was not isolated - stop and fix that before running
anything else.

## HLS cache integrity audits

Never judge an HLS cache by `#EXTINF` label sums. Use the frame-count tooling:

```powershell
.\venv\Scripts\python.exe scripts\hls_frame_audit.py
.\venv\Scripts\python.exe scripts\hls_content_gap_inventory.py
.\venv\Scripts\python.exe scripts\hls_gop_matrix.py
```

Rules that these scripts exist to enforce:

- Segment indices are **strided per chunk** (`SEGMENTS_PER_CHUNK_STRIDE = 32`).
  Never walk them densely from 0; glob and sort, and bound a chunk's run by
  `start_seg + 32`.
- A frame count of `-1` means **unknown** (unreadable / still being written),
  never "empty". Treating it as empty makes good caches look deficient and causes
  infinite re-renders.
- `#EXTINF` labels are honest. `ffprobe -show_entries format=duration` on a
  segment includes the audio pre-roll (measured 4.33 s container vs 2.4 s video)
  - relabelling from container durations hides real frame loss.
- Completeness divides by `source_video_duration()` (video-stream end), never the
  container duration.
- `#EXT-X-TARGETDURATION` must cover the longest `#EXTINF`;
  `honest_target_duration()` derives it.

## Android / Fire TV device interaction

Before sending ADB remote-control key events to a connected Fire TV Stick or
Android TV, say exactly: **"Please do not touch the remote..."**
When finished, say exactly: **"The app is free from your control."**

This is a strict invariant in `AGENTS.md`, not a courtesy.

Player remote invariants worth re-checking after any TV change:

- 1st Back press reveals controls + refocuses the timeline; 2nd exits. Never pop
  directly when controls are hidden.
- Configure `hwdec: 'mediacodec-copy'` for `AFTMM` devices. Zero-copy
  `mediacodec` deadlocks the MediaTek MDP fence on non-16-byte-aligned widths
  (e.g. 1916px).
- Keep `fallbackToSoftwareDecoder()` (sets `hwdec: 'no'`) and its 4-second
  first-frame timeout.

## Reporting

State what was actually verified vs inferred. For delegated work, re-check claims
of absence or safety with the cheapest decisive command rather than trusting them.