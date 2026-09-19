# Windows Permanent Purge Investigation / Session Handoff

Last updated: 2026-09-15

## Purpose

This document records the latest controlled Windows reproduction of the permanent media purge failure. It is intentionally separate from the general project status so future agents do not mistake the current purge branch for a completed fix.

## Current status

**Windows permanent purge is NOT fixed.**

The failure is reproducible when an actively transcoding MKV/HEVC movie is deleted through the web UI. The browser reports **`Failed to fetch`**, and the Waitress process subsequently exits without a Python traceback or normal Waitress shutdown message. The server therefore stops listening on `127.0.0.1:8000`.

The failure has now been reproduced more than once.

## Controlled reproduction performed on 2026-09-15

Environment:

```text
OS:              Windows
Project:         C:\MediaServer
Media root:      C:\Flicks
Python:          3.14.3
FFmpeg:          9.0.1 essentials build with AMF
WSGI:            Waitress
Origin:          127.0.0.1:8000
Test movie:      The Odyssey (2026)
TMDb ID:         1368337
```

The test was deliberately performed from a clean cache state.

### 1. Clean baseline

Before adding the movie:

```powershell
Get-ChildItem C:\MediaServer\cache\hls -Recurse -File -ErrorAction SilentlyContinue
Get-ChildItem C:\MediaServer\cache\transcodes -Recurse -File -ErrorAction SilentlyContinue
```

Both returned no files.

Waitress was started manually with:

```powershell
python -m waitress --listen=127.0.0.1:8000 app:app
```

The application loaded normally.

### 2. Safe media ingestion

To avoid the scanner seeing a partially copied file, the movie was first copied to a temporary location outside the monitored media root. After the copy completed, the finished file was moved into the configured media directory.

The movie appeared correctly in the library and was identified as **The Odyssey (2026)**.

### 3. Active HLS transcode

Playback was started so that the purge test occurred while FFmpeg was actively writing HLS output.

Observed cache state included:

- `hls.progress`
- `playlist.m3u8`
- 93 HLS `.ts` segments at the time of inspection
- segment sizes in the roughly 0.4–4.4 MB range

FFmpeg was confirmed running. Example PID during the test was `18148`.

This proves the purge test exercised a live FFmpeg/file-lock condition rather than an already-idle cache.

### 4. Purge failure

While playback/transcoding was active, **Delete & Purge** was clicked once.

The browser reported:

```text
Failed to fetch
```

The Waitress terminal showed queue activity and a client disconnect while serving the source media request, followed by return to the PowerShell prompt:

```text
WARNING:waitress.queue:Task queue depth is 1
...
INFO:waitress:Client disconnected while serving /media/...
WARNING:waitress.queue:Task queue depth is 2
WARNING:waitress.queue:Task queue depth is 1
...
(venv) PS C:\MediaServer>
```

There was **no Python traceback** and no explicit Waitress shutdown message.

After the process exited, the application was no longer reachable on port 8000.

### 5. Important causal observation

The server does **not** fail merely because the movie exists or because FFmpeg is transcoding.

The observed sequence is consistently:

```text
Waitress healthy
  -> movie indexed
  -> active FFmpeg/HLS transcode
  -> Delete & Purge requested
  -> browser: Failed to fetch
  -> Waitress process exits
  -> port 8000 no longer listening
```

Therefore the purge path is the primary suspect. Do not treat this as a generic Waitress startup/stability problem.

## What worked

The cache cleanup portion has also been observed to succeed in at least one purge attempt. After a failed/attempted purge, these commands returned no files:

```powershell
Get-ChildItem C:\MediaServer\cache\hls -Recurse -File -ErrorAction SilentlyContinue
Get-ChildItem C:\MediaServer\cache\transcodes -Recurse -File -ErrorAction SilentlyContinue
```

This means the implementation can successfully remove the HLS/transcode cache in some executions. The unresolved problem is the **failure path and server/process lifecycle**, not simply whether `shutil.rmtree()` can ever delete the directory.

Do not change cache accounting based on historical dashboard totals yet. Repeated uploads/purges may have polluted the accounting baseline. First make purge deterministic, then measure physical cache from a clean baseline.

## Current purge implementation under investigation

The active work branch is:

```text
fix/windows-purge-reliability
```

Relevant commits currently known locally:

```text
9aa71c2  fix: restore Windows AMF configuration
b67d7e9  fix: make media purge reliable on Windows
```

`9aa71c2` is a local commit on the branch and had not yet been pushed at the time of this handoff.

The current implementation:

1. Identifies/captures the HLS directory where possible.
2. Calls `stop_transcodes_for_media()`.
3. Attempts Windows process termination using `taskkill /PID <pid> /T /F`.
4. Waits for the PID to exit.
5. Removes the HLS tree with bounded retries.
6. Removes direct/compat MP4/progress/part cache files.
7. Removes subtitle/artwork/metadata records.
8. Deletes database records.
9. Deletes the source media file.
10. Invalidates the media path cache and triggers a library scan.

The implementation no longer uses Unix-only `signal.SIGKILL` on Windows, and HLS deletion is verified rather than merely logged as successful.

## Known implementation weaknesses to investigate

### A. Process termination must be isolated first

`stop_transcodes_for_media()` can call `Popen.terminate()` and separately invoke `_terminate_pid()`. On Windows `_terminate_pid()` uses:

```text
taskkill /PID <pid> /T /F
```

The next investigation must determine whether process-tree termination, FFmpeg shutdown, or a related subprocess interaction can terminate or destabilize the Waitress process/request.

Do not assume this is proven yet.

### B. Purge path currently depends on source-file metadata for some cache paths

`transcode_cache_path()` and `hls_cache_dir()` derive deterministic names using `path.stat()`.

The media purge path currently calculates/captures the HLS directory before deleting the source, which helps the HLS case. However, direct/compat cache paths are still calculated later from the source path. If the source has already disappeared, those paths cannot be recomputed.

The robust design should capture **all relevant cache paths before any source deletion**, or persist/cache the identity independently of the source file.

### C. Scanner triggering after destructive deletion needs examination

`purge_media()` invalidates `_paths` and calls `trigger_library_scan()` after deleting the source. The scanner is asynchronous.

This is probably not the immediate cause because the Waitress process exits during/after the purge request, but it must remain in the diagnostic sequence and should not be allowed to obscure purge errors.

### D. Browser/player requests continue during purge

The Waitress logs showed queue-depth changes and a client disconnect while serving the movie. This is expected to some degree when deleting a movie currently being played, but the interaction must be made safe.

A robust purge should not require the browser to stop requesting the deleted media before the server can complete the deletion.

## Next diagnostic plan

Do **not** keep repeatedly testing the destructive UI flow until the server-side failure is isolated.

The next session should:

1. Inspect the exact local branch state and confirm `9aa71c2` is present.
2. Preserve the known-good baseline and do not merge the purge branch yet.
3. Add temporary, clearly scoped diagnostic logging around each purge stage.
4. Record entry/exit around `stop_transcodes_for_media()` and every subprocess operation.
5. Determine whether Waitress exits during FFmpeg termination, cache deletion, DB deletion, source deletion, or scanner triggering.
6. If needed, test the Windows `taskkill` behavior independently against the FFmpeg child process while Waitress is running, but only after FFmpeg is actively transcoding.
7. Verify whether the Waitress PID remains alive after FFmpeg termination without invoking the full purge route.
8. Capture the actual HTTP request/response status from the purge endpoint if possible, rather than relying only on the browser's generic `Failed to fetch` message.
9. Make the purge operation idempotent and safe when the source, cache, or process has already disappeared.
10. Ensure a purge failure cannot take down the WSGI server and returns a controlled JSON error.
11. Only after deterministic success should cache accounting be reconsidered.
12. Run the relevant test suite and add Windows-specific purge regression tests where feasible.

## Do not forget

- Do not use `signal.SIGKILL` on Windows.
- Do not hide deletion failures with `ignore_errors=True`.
- Do not log an HLS purge as successful unless the directory is actually gone.
- Do not assume the browser's `Failed to fetch` message identifies the root cause.
- Do not assume that a successful cache deletion means the entire purge operation succeeded.
- Do not repeatedly click Delete & Purge as a diagnostic method; one controlled reproduction is sufficient until the server-side stage is isolated.
- Keep the Windows AMF changes separate from the purge diagnosis.
- Do not push/merge the current purge branch as fixed based on the current tests.

## Related documentation/issues

- `docs/PROJECT_STATUS.md` — general project handoff and work queue.
- `docs/DEVELOPMENT_STATUS.md` — detailed development/session state; verify its branch information because it contains older AMF-branch wording.
- `docs/WINDOWS_SETUP.md` — Windows deployment/setup documentation; it currently contains a stale reference to a nonexistent `run_production.py` and should be corrected separately.
- GitHub Issue #7 — original permanent media purge failure.
- GitHub Issue #11 — authoritative implementation brief for Windows purge race/process termination/cache cleanup reliability.
- GitHub Issue #9 and #10 — duplicate purge-fix issues; do not treat them as separate root causes.
