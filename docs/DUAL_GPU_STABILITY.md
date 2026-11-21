# Dual-GPU Transcoding Stability

The Rust transcode service runs at most one rendition job on each physical
adapter. In dual mode the RX 560X handles 1080p and higher; the Vega 8 handles
720p. 4K stays on the RX 560X alone. When dual mode is unavailable, the RX lane
can process all supported qualities.

## Enable dual mode

Dual mode is opt-in. Set these values in the service environment, then restart
the Rust service:

```dotenv
MEDIA_SERVER_ENABLE_DUAL_GPU=1
MEDIA_SERVER_GPU_MAX_TEMP_C=85
MEDIA_SERVER_GPU_CRITICAL_TEMP_C=92
MEDIA_SERVER_GPU_COOLDOWN_TEMP_C=75.0
MEDIA_SERVER_CHUNK_BREATHER_MS=1000
MEDIA_SERVER_4K_CHUNK_BREATHER_MS=5000
MEDIA_SERVER_REQUIRE_HWINFO_FOR_4K=1
MEDIA_SERVER_GPU_TEMP_RX_MATCH=560X
MEDIA_SERVER_GPU_TEMP_VEGA_MATCH=Vega 8
```

In HWiNFO, enable Shared Memory Support and keep sensor publishing active. HWiNFO 8.60 Portable is installed at `C:\HWiNFO\HWiNFO64.exe` with preconfigured `HWiNFO64.INI` and Windows Startup integration (`HKCU:...\Run`). The server requires fresh Celsius readings for both adapters. Sensor group names must contain the configured match strings, and the reading label must identify a temperature. Missing, malformed, stale (older than 15 seconds), or over-limit data blocks dual dispatch. When several temperature readings match an adapter, the hottest reading is used.

### Thermal Protection Invariants:
1. **Unconditional Chunk Guarding**: Every transcode chunk (single-GPU and dual-GPU) is thermal-guarded. If the active GPU hits the critical limit (default 92°C) or sensor loss occurs, the active FFmpeg child process is immediately terminated via `taskkill /PID ... /F /T` and persistent diagnostic logs are retained.
2. **Heavy / 4K Workload Admission**: 4K sources and 4K targets strictly require active HWiNFO Shared Memory telemetry (`MEDIA_SERVER_REQUIRE_HWINFO_FOR_4K=1`). If HWiNFO is not running, heavy transcode jobs are safely paused with a warning to protect mobile laptop silicon from hardware thermal shutdowns.
3. **Dynamic Cooldown Breathers**: Heavy workloads apply a base 5,000ms breather between chunks (`MEDIA_SERVER_4K_CHUNK_BREATHER_MS`). In addition, before proceeding to the next chunk, workers dynamically poll the GPU temperature and wait until the adapter drops below `MEDIA_SERVER_GPU_COOLDOWN_TEMP_C` (default 75°C) to prevent thermal saturation across shared heatpipes.

If dual mode or telemetry is unavailable when the service starts, it starts in
single-RX mode. Restart the Rust service after correcting HWiNFO or sensor
configuration to start the two adapter lanes. No HWiNFO software is bundled by
the server.

On the Acer Nitro AN515-43, HWiNFO 8.61 reports the integrated group as
`iGPU [#0]: AMD Radeon Vega 8` and the discrete group as
`dGPU [#1]: AMD Radeon RX 460/560X`. The default `560X` match handles the
discrete group name reported by this machine.

## Quality floor

The advertised and scheduled HLS qualities are 720p, 1080p, 1440p, and 2160p.
Requests for 480p or 360p are rejected. On 2026-11-21, the local HLS cache was
cleaned of all 38 `360p` and `480p` rendition directories (74,908 files,
43,703,437,986 bytes). The 19 cached master playlists were rewritten to remove
those variants; each original master is retained beside it as
`master.m3u8.before-quality-cleanup.bak`. PostgreSQL's 44 completed
`hls:360p`/`hls:480p` job-history rows were also removed so they no longer appear
as completed low-resolution renditions. No 720p-or-higher cache directories or
movie catalog rows were removed. One cached master had no 720p-or-higher variant
after cleanup; its original is preserved in the backup.

## Validation

Completed locally on 2026-11-21:

- HWiNFO 8.61 Shared Memory v2 was read live. The mapping had 18 sensor groups
  and 225 readings, with the poll timestamp no more than two seconds old. The
  observed groups were `iGPU [#0]: AMD Radeon Vega 8` and
  `dGPU [#1]: AMD Radeon RX 460/560X`.
- The hardware-gated Rust probe read both temperatures and passed dual admission,
  adapter-specific limits, and critical-temperature checks. Readings during the
  checks ranged from 56°C to 64°C.
- Sequential one-second 720p `h264_amf` scratch encodes passed on `dx11:1` (RX
  560X) and `dx11:0` (Vega 8). FFprobe verified both outputs as 1280×720 H.264.
  Scratch outputs are under
  `cache/release-build/dual-gpu-validation/scratch/`.
- The corrected release build is running in the local NSSM service. The service
  returned HTTP 200 after restart; `MEDIA_SERVER_ENABLE_DUAL_GPU=0` remains set.

The concurrent RX 560X + Vega 8 scratch run is pending explicit readiness. Also
pending are validation of sensor-loss behavior during a chunk, 4K RX-only work,
and complete-playlist publication after validated segment coverage. No sustained
dual-GPU load has been run.
