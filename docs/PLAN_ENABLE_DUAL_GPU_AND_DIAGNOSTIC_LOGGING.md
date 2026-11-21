# Implementation Plan: Enable Dual-GPU Concurrent Transcoding & Diagnostic Logging

## 1. Overview & Context
This plan completes the remaining deployment and activation work started in the OpenAI Codex session (Turn 34):
- Commit the unstaged GPU diagnostic logging and thermal monitoring enhancements in Rust.
- Deploy the newly compiled `media-server-api.exe` release binary to the Windows Service `MediaServerRust`.
- Configure NSSM service parameters to enable `MEDIA_SERVER_ENABLE_DUAL_GPU=true` and targeted GPU debug logging.
- Restart `MediaServerRust` via elevated UAC privileges and verify healthy dual-worker initialization.
- Prepare the media server for high-load validation with the user's 24 GB 4K HEVC 10-bit x265 file.

---

## 2. Scope

### In Scope
1. **Version Control**:
   - Create a clean feature branch: `feat/dual-gpu-diagnostics`.
   - Commit the working tree changes:
     - `.gitignore` (router documentation isolation).
     - `rust/src/services/media_pipeline/gpu_service.rs` (structured D3D11 AMF probe error and timeout logging).
     - `rust/src/services/media_pipeline/gpu_thermal.rs` (structured thermal admission and monitoring telemetry).
     - `rust/src/services/media_pipeline/transcode_worker.rs` (bounded persistent on-disk FFmpeg stderr diagnostic logging).
2. **Binary Deployment**:
   - Safely stage the fresh release binary `rust/target/release/media-server-api.exe` into `E:\MediaServer\cache\release-build\dual-gpu-validation\release\media-server-api.exe` while preserving the previous binary as a `.bak` fallback.
3. **NSSM Service Configuration (`MediaServerRust`)**:
   - Update `AppEnvironmentExtra` in `HKLM:\SYSTEM\CurrentControlSet\Services\MediaServerRust\Parameters`:
     - Add `MEDIA_SERVER_ENABLE_DUAL_GPU=true`.
     - Update `RUST_LOG` to `info,media_server_api::services::media_pipeline::gpu_service=debug,media_server_api::services::media_pipeline::transcode_worker=debug,media_server_api::services::media_pipeline::gpu_thermal=debug`.
4. **Service Restart & Validation**:
   - Stop and restart `MediaServerRust` via an elevated script (`Start-Process -Verb RunAs`).
   - Monitor `logs/rust_api.log` to confirm startup, D3D11 adapter probing, dual-worker registration (RX 560X discrete dx11:1 + Vega 8 integrated dx11:0), and HWiNFO sensor health.
   - Verify `/api/system/status` returns HTTP 200 OK.

### Deliberately Out of Scope
- Modifying transcode quality ladder tier allocations (Vega 8 remains constrained to 720p; RX 560X handles 1080p and 4K).
- Altering thermal safety thresholds (admission limit remains 85.0°C; critical threshold remains 92.0°C fail-closed).
- Touching `MediaServerCaddy` or `MediaServerPG` services (both are healthy and unchanged).

---

## 3. Exit Criteria
- [ ] Feature branch `feat/dual-gpu-diagnostics` created with clean commit of the four modified files.
- [ ] Service `MediaServerRust` is `Running` using the updated release binary.
- [ ] Registry parameters confirm `MEDIA_SERVER_ENABLE_DUAL_GPU=true` and targeted GPU debug logging in `AppEnvironmentExtra`.
- [ ] Service logs demonstrate dual GPU initialization:
  - Adapter 0: AMD Radeon Vega 8 (dx11:0) registered.
  - Adapter 1: AMD Radeon RX 560X (dx11:1) registered.
  - Dual transcode worker initialized without errors.
- [ ] `/api/system/status` and `/api/health` respond with HTTP 200.
- [ ] Server ready for immediate 24 GB 4K HEVC movie upload and transcoding.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation / Control |
| :--- | :--- | :--- |
| **Executable File Lock on Copy** | Cannot overwrite running binary | The deployment script stops `MediaServerRust` before copying the executable, backs up the old binary, copies the new binary, updates registry values, and starts the service. |
| **Elevation Failure (UAC)** | Service parameters unchanged | The script uses `Start-Process powershell -Verb RunAs` to trigger the native Windows UAC prompt. If denied, the script aborts cleanly without corrupting the existing service state. |
| **Disk Space Growth from FFmpeg Logs** | Disk saturation in `logs/gpu/` | Bounded logging: each chunk log is capped at 4 MiB, directory capped at 256 MiB total with a 14-day TTL. Successful chunks delete their log immediately upon completion. |
| **Dual GPU Thermal Overheating** | Laptop thermal throttling or system crash | Strict HWiNFO telemetry gate: admission blocked if either GPU \(\ge 85^\circ\text{C}\); running chunks aborted if either GPU \(\ge 92^\circ\text{C}\) or if telemetry becomes stale (>15s). |

---

## 5. Open Decisions

1. **Service Binary Location**:
   - **(Recommended) Deploy to `cache/release-build/dual-gpu-validation/release/`**: Keeps the production Windows Service decoupled from `rust/target/release/`, ensuring local development and future `cargo build` commands do not fail due to Windows OS executable file locks.
   - **Alternative**: Point NSSM directly to `rust/target/release/media-server-api.exe`. (Not recommended due to file-locking conflicts during future development).
