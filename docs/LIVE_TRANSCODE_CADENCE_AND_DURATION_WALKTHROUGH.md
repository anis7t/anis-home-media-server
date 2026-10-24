# Walkthrough — Live Transcode Cadence and Duration Display

**Status:** Completed & Verified  
**Date:** 2026-10-17  
**Host:** Windows 10/11 (Dual AMD GPU: Discrete RX 560X + Integrated Vega 8)  
**Backend:** Rust/Axum (`MediaServerRust` on `:8001`)  
**Frontend:** React / Vite (`web/dist/`)  

---

## 1. Overview & Objective

Following user approval under **`AGENTS.md` §0.1** and **`GEMINI.md` §0**, this task delivered:
1. **Live Duration Tracking:** Real-time complete vs encoded duration display (`encoded_str / duration_str`, e.g. `69:23 / 106:00`) on the React homepage active transcode card.
2. **1.5-Second Cadence Progress Updater:** Ported the continuous progress updater daemon from Flask to Rust (`rust/src/services/transcode_worker.rs`), polling disk segments and computing trailing-window rates every 1.5 seconds.
3. **Responsive Speed & ETA:** Replaced static batch-waiting (~80-second freezes) with rolling rate estimation over a 90-second window (15-second minimum span), ensuring immediate speed and ETA visibility upon start or service restart.
4. **Child Process Teardown Safety:** Added process group termination guards to prevent orphaned `ffmpeg.exe` processes from holding hardware AMF locks on Windows.

---

## 2. Changes Delivered

### Backend API (`rust/src/routes/jobs.rs`)
- Enhanced `active_transcodes_handler` (`GET /api/transcodes`):
  - Queries `movies.runtime` (in minutes) from PostgreSQL for each active transcode job.
  - Computes `duration_sec = runtime * 60` and formats `duration_str` (e.g. `"106:00"`).
  - Calculates `encoded_sec = (progress / 100) * duration_sec` and formats `encoded_str` (e.g. `"69:23"`).
  - Provides a robust mathematical fallback from `eta` and `speed` if a title has not yet completed TMDb indexing.
  - Injects `encoded_str` and `duration_str` into the JSON payload.

### Transcode Worker Engine (`rust/src/services/transcode_worker.rs`)
- Implemented an asynchronous cadence monitor task (`tokio::spawn`) ticking every 1.5 seconds during active job execution:
  - Scans newly written HLS `.ts` segments on disk in real time.
  - Maintains a rolling sample buffer (up to 120 samples) over a 90-second trailing window.
  - Smoothly updates `JobService::update_progress` in PostgreSQL and writes `hls.progress`.
  - Added clean termination using `AtomicBool` and safe Windows `taskkill` cleanup on abort/cancel to eliminate orphaned FFmpeg processes.

### Frontend UI (`web/src/features/library/ActiveTranscodes.tsx`)
- Updated the fallback data mapper to forward `encoded_str` and `duration_str`.
- Bound `{t.encoded_str} / {t.duration_str}` directly into the active telemetry row next to percentage, speed, and ETA.
- Built production assets into `web/dist/` (`npm run build`).

---

## 3. Verification & Live Results

### Live API Verification (`GET /api/transcodes`)
```json
{
  "transcodes": [
    {
      "duration_str": "106:00",
      "encoded_str": "69:23",
      "eta_str": "27m 0s",
      "filename": "Ghost.in.the.Cell.2026.2160p.NF.WEB-DL.DDP5.1.H.265-PandaQT/Ghost.in.the.Cell.2026.2160p.NF.WEB-DL.DDP5.1.H.265-PandaQT.mkv",
      "mode": "HLS Transcode",
      "percent": 65.45,
      "poster_url": "/poster/Ghost.in.the.Cell...",
      "speed": "1.2x",
      "status": "running",
      "title": "Ghost in the Cell 2026 2160p NF WEB-DL DDP5 1 H 265-PandaQT"
    }
  ]
}
```

### Automated Rust Test Suite
- `chunk_transcode_test.rs`: 4 passed (100% OK)
- `progress_contracts_test.rs`: 4 passed (100% OK)
- Frontend Vite build: 100 modules transformed, production bundle built cleanly in 2.66s.
