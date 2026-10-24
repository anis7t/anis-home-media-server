# Handoff — Anis' Home Media Server

| | |
|---|---|
**Date** | 2026-10-04 13:56 local (2026-10-04 08:26 UTC) |
**Agent** | OpenCode |
**Model** | space-bunny-alpha |
**Workspace** | `E:\MediaServer` |
**Branch** | `feat/flutter-production-player` |
**HEAD** | `d889dee` — 4 commits ahead of origin, **not pushed** |
**Verified** | 361 passed / 1 skipped (`pytest tests/`) |
**Pushed** | **No** — per `GEMINI.md` §6, pushing is reserved for the user |

---

## Paste-ready prompt

Copy everything inside the block below to start the next session.

---

```
Continue work on Anis' Home Media Server at E:\MediaServer.

STATE
- Branch feat/flutter-production-player, HEAD d889dee, 4 commits ahead of origin (NOT pushed).
  Pushing is reserved for the user - see GEMINI.md s6.
- Working tree is clean except files I did not create and must not touch:
  .gitignore, .opencode/{db,skills}, docs/AGENT_EXTENSIONS.md, opencode.json
- Live host: MediaServer + Cloudflared NSSM services running, media server on
  127.0.0.1:8000 (LAN 192.168.1.16:8000). Fire TV Stick 4K (AFTMM) paired at
  192.168.1.70:5555; Vivo phone at 192.168.1.6:41019.
- Verified: 361 passed / 1 skipped. Use .\scripts\run_flutter_tests.ps1 for Flutter,
  NEVER bare `flutter test` (see below).

READ FIRST
- Load the `media-server-verify` skill.
- AGENTS.md - authoritative invariants. Section 6 covers HLS cache integrity and now
  documents the frame-accounting model in full.
- docs/PROJECT_STATUS.md section 0 has dated entries for 2026-10-04.
- docs/FLUTTER_CLIENT_STATUS.md covers the Flutter client and the media_kit runner.

WARNINGS THAT WILL BITE YOU
1. NEVER bare `flutter test`. media_kit's NativeReferenceHolder writes to
   ...NativeReferenceHolder.$pid, creates it empty before writing, never deletes it.
   Windows PID reuse makes a new process inherit a dead run's file and hang the whole
   file ("did not complete"). 415 orphans caused 2 failures in 6 runs INCLUDING one
   --concurrency=1 run, so serial is NOT a fix. Use .\scripts\run_flutter_tests.ps1.
2. NEVER call source_video_duration(path, fallback=<not None>). Any non-None fallback
   disables its container-duration fallback and returns 0; plan_chunks(0) is [] so the
   cache is judged VACUOUSLY complete. This shipped twice and left a fully-rendered film
   unsealed.
3. Never point tests at :8000 or at D:\Flicks. tests/conftest.py isolates cache/db/uploads
   through the ENVIRONMENT before app import, and pytest_runtest_setup re-asserts per test.
   After ANY conftest change, snapshot the library list, the movies rows and cache/hls
   (+ a hash each) before and after - all three must be identical.
4. Never os.kill(pid, 0) on Windows. Use app.services.transcode_service.is_pid_alive.
5. Never os.rename() across volumes. Use shutil.move with a pre-unlink.
6. The service runs as SYSTEM: you cannot read its child process command lines, and a
   background shell you start is killed if the service restarts.
7. Heavy sweeps (ffprobe over the cache) MUST stay at <= 4 workers. At 8 they saturate
   all cores and visibly drop GPU utilisation during a live transcode. Verify no ffmpeg is
   running before starting one.

OPEN WORK, in priority order
1. tests/test_storage_retention.py:68 writes TestActiveMovie.2026.mkv into
   app.config.MEDIA_ROOT (= D:\Flicks, the LIVE library). The running server then caches
   it; the test deletes the file and orphans the cache dir. purge_orphaned_caches() cleans
   up, so it is cosmetic, but every suite run plants one. Fix: use a path under the temp
   fixture tree.
2. scripts/hls_frame_audit.py has no layout guard. It shares the strided window now, but
   on the 4 legacy dense caches per-chunk windows are meaningless (the server judges
   whole-cache there deliberately). Add cache_uses_strided_layout() handling.
3. ADB direct-intent: `--es mediaUrl <url>` does not survive the shell (the URL value is
   mangled, so /player falls back to its hard-coded Batman entry). Working form:
   `--es route '/movie-details?filename=<name>'`. Worth adding to GEMINI.md s21.
4. E: is a "Micro PS SD" reader holding app + media.db + the entire HLS cache + venv.
   D: is a 1TB HDD, C: a 256GB SSD. Healthy and fast, but removable. Needs a decision.
5. Production concurrency tuning (long-standing, unchanged).

METHOD NOTES - I got things wrong repeatedly; learn from these
- Measure, do not infer. I twice announced conclusions from a log tail that the terminal
  state contradicted (a cache "not sealed" that was sealed; a transcode "finished short"
  that had completed). Read the authoritative end-state - progress=end, ENDLIST, totals.
- Never truncate a hash when naming a path. Doing so made me briefly report a live cache
  directory as "no playlist" twice.
- MPEG-TS makes ffprobe print a video stream's nb_read_packets TWICE (once per program).
  Take the FIRST parseable line. Summing all lines double-counts; reading a stream that
  prints nothing yields 0, which silently turns into "the whole film is missing".
- The chunk-54 experiment (a fresh render losing exactly 15 frames at the window head) is
  NOT what the cache contains. The cache has been re-rendered and serially repaired many
  times since and measures 0-12 frames per chunk, scattered 1-4 frames inside segments,
  with clean seams. Do not generalise from a fresh render to the stored cache.
- Add a sanity assertion to any measurement script (e.g. total within 10% of expected)
  and refuse to report when it fails.

BEFORE ANYTHING ELSE
git status and git log to confirm the state above, then tell me which of the five open
items you want and proceed. Do not restart MediaServer or Cloudflared without asking.
```

---

## What was committed this session

| SHA | Scope |
|---|---|
`672d491` | Flutter test isolation from the live server + `scripts/run_flutter_tests.ps1` (media_kit temp-state purge) |
`78b5490` | Storage-topology documentation correction (E: runtime, D: media, C: unused) |
`d3600c2` | Frame-exact chunk accounting shared with the audit tool + 18 new tests |
`d889dee` | Documentation of the above into `AGENTS.md` and `docs/PROJECT_STATUS.md` |

**Not committed — not created by this agent, deliberately untouched:** `.gitignore`, `.opencode/db/refresh-snapshot.ps1`, `.opencode/skills/media-server-verify/SKILL.md`, `docs/AGENT_EXTENSIONS.md`, `opencode.json`.

---

## Environment reference

### Storage topology (corrected this session)

| Role | Path | Device |
|---|---|---|
Application, runtime, venv | `E:\MediaServer` | **`Micro PS SD` reader** |
Database | `E:\MediaServer\media.db` | — |
Cache (`hls`, `previews`, `posters`, `backdrops`, `subtitles`, `transcodes`) | `E:\MediaServer\cache` | — |
Media library | `D:\Flicks` | `WDC WD10SPZX` 1TB HDD |
OS | `C:\` | `HFM256GDJTNG` 256GB SSD |
Archive / uploads / deleted staging | `D:\Flicks\.archive`, `.uploads`, `.deleted` | — |

Storage Pool telemetry aggregates `D:\` + `E:\` with a per-drive breakdown.

`C:` holds nothing for this project. Several documents previously claimed `C:\Flicks`; all corrected.

### Services and devices

- `MediaServer` (NSSM → Waitress, `WAITRESS_THREADS=16`) and `Cloudflared`, both Running/Automatic
- Fire TV Stick 4K `AFTMM` (mantis, Android 7.1.2) — `192.168.1.70:5555`
- Vivo phone `I2217` (Android 16) — `192.168.1.6:41019`
- Flutter client is pointed at **LAN** `192.168.1.16:8000` (was the public tunnel)

### Concurrency model

| Tier | Mechanism | Count | Limit |
|---|---|---|---|
HTTP serving | Waitress threads | 16 | 16 requests |
Background | daemon threads | 4 +1 GPU sampler | 1 each, by timer |
GPU encode | thread → subprocess | 2 | **1 ffmpeg per GPU — hard cap 2** |
Serial repair | thread → subprocess | 1 | 1 GPU only |
Transcodes | `TRANSCODE_LOCKS` | per-media | parallel across titles |

Serial repair is single-worker **by design** (`test_repair_pass_rerenders_deficient_chunks_serially`): two chunks encoding concurrently can each lose a GOP at the head of a seek. This is why one GPU idles during that phase.

---

## Frame-accounting model as implemented

All helpers live in `app/services/chunk_transcode_service.py` and are shared by
`chunk_content_deficits()` and `scripts/hls_frame_audit.py`:

| Helper | Purpose |
|---|---|
`frame_index_at(t, fps)` | `round(t * fps)` |
`expected_frames_for_window(start, dur, fps)` | difference of two indices — always an integer |
`chunk_boundary_frame_tolerance(fps)` | `ceil(0.7 * fps)` frames — fixed alignment slack |
`aggregate_loss_ceiling_frames(fps, dur)` | `max(10s, 0.1% of runtime)` in frames |

**Why 0.7 s is measured:** a fresh render of a 4K HDR/AMF chunk (3840×2160 HEVC, 24fps) loses exactly
**15 frames (0.625s) at the head of the window**, and the loss is **identical for 60s, 61s and 65s
windows** — decode-pipeline priming, not a seek-position error. Seeking 1s earlier and extending `-t`
by 1s recovers it (1440 → 1449 frames). A 2-frame tolerance made this an unbounded re-render loop over
the same chunk ids; repeated serial repair converges it away.

**Whole-cache ceiling:** per-chunk allowances multiply (17 × 157 chunks ≈ 111s), so the ceiling bounds
it. It fires only when **no** chunk was flagged — its purpose is the case the per-chunk check cannot
see. Applied to both layouts so dense and strided are judged by one standard. All 7 dense caches measure
1 frame or negative, so tightening from 73–115s to 10s triggers no re-renders.

**Accepted loss is recorded:** `_finalize()` writes `hls.loss.json` (frames, seconds, chunks, both
thresholds, timestamp, reason) when sealing a short cache. Deliberately not `hls.progress`, which is
ffmpeg's own `-progress` file.

---

## Library state at handoff

- **21 caches, all sealed with ENDLIST**, none re-rendering
- 20 of 21 at **0 frame loss**
- *Project.Hail.Mary* (4K HDR reference): 157/157 chunks rendered, chunk **seams clean** (0–3 frames,
  ~0.46s across 10 boundaries), residual ~133 frames (5.5s over 156 min) scattered as **1–4 frame
  (42–167 ms)** shortfalls inside individual segments. No stall is possible (no data missing from the
  playlist) and no cut is visible at that scale. Verified on the Fire TV over LAN.
- *Teenage Sex and Death at Camp Miasma* (user upload): transcoded first-pass, 6721.6s of 6721.6s,
  **zero deficit**
- *Sample.mkv* purged completely — file, HLS cache, two cached transcode MP4s, cached subtitle, cached
  poster/backdrop, and its TMDb metadata row

---

## Mistakes made this session, recorded so they are not repeated

| Mistake | Consequence | Correction |
|---|---|---|
Asserted a cache was unsealed from a log tail reading "98.0%" | Wrong; it had sealed at 100% | Read terminal state (`progress=end`, ENDLIST, totals) |
Truncated sha256 dir names twice | Briefly reported a live cache as "no playlist" | Always print resolved paths in full |
Summed all ffprobe stdout lines | Doubled counts; reported 12min of phantom loss on Stalker | Take the first parseable line (MPEG-TS prints twice) |
Indexed playlist labels by position, packets by file index | Compared segments against wrong labels | Map via the playlist's own URIs |
Claimed ~15 frames lost at every chunk boundary | Refuted by seam measurement (0.46s total) | Measure seams before generalising |
Built a deficit map with a helper that returned 0 for everything | Reported "entire film missing" | Added a sanity assertion (total within 10% of expected) |
Claimed the scan was killed by a service restart | No evidence; the user correctly pushed back | Do not attribute a failure without checking |
Used an 8-worker sweep during a live transcode | Saturated all cores, dropped GPU utilisation | Cap at `cores//2`; verify no ffmpeg first |

---

## Remote-control protocol

Before sending ADB key events to the Fire TV or Android TV, say exactly:
**"Please do not touch the remote..."**
When finished, say exactly: **"The app is free from your control."**

Verified working deep-link form (extras with query parameters survive; a URL *value* does not):

```
adb -s 192.168.1.70:5555 shell "am start -n in.anisparvez.media_server_client/.MainActivity \
  --es route '/movie-details?filename=<exact filename>'"
```