# Walkthrough: Dual-GPU Concurrent Transcoding & Diagnostic Logging Activation

## Overview
This walkthrough confirms the complete deployment and operational activation of **Dual-GPU Concurrent Transcoding** and **Bounded On-Disk Diagnostic Logging** for Anis' Media Server (`MediaServerRust`).

The system is now actively running both the discrete AMD Radeon RX 560X (`dx11:1`) and integrated AMD Radeon Vega 8 (`dx11:0`) worker lanes with continuous HWiNFO thermal admission monitoring (<85°C admission limit) and targeted FFmpeg stderr diagnostic retention.

---

## Deliverables & Changes

### 1. Version Control & Feature Branch
- **Branch**: `feat/dual-gpu-diagnostics`
- **Commits**:
  - `fea79d5`: `feat(gpu): enable persistent FFmpeg diagnostic logging and structured thermal telemetry`
  - `7867c96`: `chore(scripts): add automated dual-gpu service deployment script`

### 2. Core Enhancements

| File | Changes Made |
| :--- | :--- |
| [`gpu_service.rs`](file:///e:/MediaServer/rust/src/services/media_pipeline/gpu_service.rs) | Enhanced D3D11 AMF probe error handling. Adapter timeouts and probe failures capture FFmpeg stderr into structured `tracing::error!` and `warn!` logs. |
| [`gpu_thermal.rs`](file:///e:/MediaServer/rust/src/services/media_pipeline/gpu_thermal.rs) | Structured thermal telemetry tracking for `dual_gpu_thermal_safe()`, `adapter_temperature_safe()`, and `critical_temperature_or_sensor_loss()`, recording exact RX 560X/Vega 8 temperatures, sensor age, and limit thresholds. |
| [`transcode_worker.rs`](file:///e:/MediaServer/rust/src/services/media_pipeline/transcode_worker.rs) | Bounded persistent on-disk FFmpeg stderr diagnostic capture (`logs/gpu/job-{id}-adapter-{name}-chunk-{id}-{ts}.log`). Files are capped at 4 MiB, rotated/pruned against a 256 MiB directory limit, and cleaned up automatically upon successful chunk completion while retaining logs on failures/crashes. |
| [`.gitignore`](file:///e:/MediaServer/.gitignore) | Isolated local router configuration documents and `.codex-attachments/` from Git tracking. |
| [`deploy_dual_gpu_service.ps1`](file:///e:/MediaServer/scripts/deploy_dual_gpu_service.ps1) | Automated operations script to safely stop the service, backup/replace the binary, enforce dual-GPU flags in `.env` and NSSM `AppEnvironmentExtra`, and restart the service. |

---

## Verification & Test Outcomes

### 1. Hardware Integration Test
Ran the live dual-adapter hardware test with real D3D11 AMF encoding and live HWiNFO sensor shared-memory validation:
```text
cargo test --manifest-path rust/Cargo.toml live_dual_gpu_chunk_transcode_and_diagnostic_capture -- --ignored --nocapture
```
**Result**:
- Concurrent chunk transcode passed on both RX 560X and Vega 8.
- Temperatures during run: RX 560X: `64.0°C`, Vega 8: `60.0°C`, sensor age: `1s`.
- Both temporary diagnostic stderr logs verified and cleaned up upon success.

### 2. Production Service Runtime Logs (`MediaServerRust`)
Inspected live service startup and background polling from `E:\MediaServer\logs\rust_api.log`:
```text
2026-11-21T08:53:29.989223Z  INFO media_server_api: Listening on http://0.0.0.0:8000
2026-11-21T08:53:33.293866Z  INFO media_server_api::services::media_pipeline::gpu_service: Detected 2 hardware GPU encoder(s): ["Radeon RX 560X Series", "AMD Radeon(TM) Vega 8 Graphics"]
2026-11-21T08:53:33.294677Z DEBUG media_server_api::services::media_pipeline::gpu_thermal: Dual-GPU thermal admission check rx_temp_c=63.0 vega_temp_c=61.0 telemetry_age_secs=2 limit_c=85.0 admitted=true
2026-11-21T08:53:33.294828Z  INFO media_server_api::services::media_pipeline::transcode_worker: Dual-GPU job lanes enabled: one rendition job per physical adapter
2026-11-21T08:53:35.392378Z DEBUG media_server_api::services::media_pipeline::gpu_thermal: Dual-GPU thermal admission check rx_temp_c=64.0 vega_temp_c=61.0 telemetry_age_secs=2 limit_c=85.0 admitted=true
```

### 3. Service Health & Status Verification
- **HTTP `/api/health`**:
  ```json
  {"engine":"rust","service":"media-server-api","status":"healthy","version":"0.1.0"}
  ```
- **HTTP `/api/system-status`**:
  ```json
  "gpu": {
    "available": false,
    "percent": 0,
    "card": "d3d11",
    "label": "Graphics Engine",
    "display": "Standby · RX 560X & Vega 8"
  }
  ```

---

## Current Status & Next Steps

The media server is fully deployed, healthy, and idling with both dual-GPU worker lanes enabled. You can now proceed to upload the **24 GB 4K HEVC 10-bit x265 file**. 

During transcode execution:
- RX 560X will handle higher renditions (1080p, 4K/2160p).
- Vega 8 will handle 720p chunks concurrently.
- If any chunk fails or crashes, its full stderr trace will be automatically captured and preserved in `E:\MediaServer\logs\gpu\`.
