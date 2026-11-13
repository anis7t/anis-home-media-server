# Implementation Plan — Container Phase 0 Verification & Hardening

**Branch:** `codex/container-phase-0`  
**Target:** Local Linux container pilot hardening, automated regression verification, and Phase 0 exit criteria sign-off  
**Reference Docs:**
- Roadmap: [`docs/CONTAINER_KUBERNETES_CLOUD_ROADMAP.md`](CONTAINER_KUBERNETES_CLOUD_ROADMAP.md) §4 (Phase 0)
- Pilot Notes & Tracker: [`docs/CONTAINER_DEPLOYMENT.md`](CONTAINER_DEPLOYMENT.md)
- Regression Suite: [`scripts/phase0/phase0-regression.ps1`](../scripts/phase0/phase0-regression.ps1)

---

## 1. Scope

### What Changes:
- **Docker Desktop Environment:** Start `com.docker.service` / Docker Desktop with WSL2 backend (`E:\DockerData\DockerDesktopWSL`) and enable local Kubernetes.
- **Automated Regression Verification:** Execute [`scripts/phase0/phase0-regression.ps1`](../scripts/phase0/phase0-regression.ps1) covering all 8 exit criteria for Phase 0:
  1. Clean, cache-independent Docker image build (`Dockerfile`).
  2. Isolated Docker Compose startup, health, database recreation, and volume persistence.
  3. Media scan, direct-play byte range (RFC 7233), CPU HLS transcoding, WebVTT subtitle streaming, and seek hover preview thumbnail generation.
  4. Graceful container shutdown under active FFmpeg transcoding (child process termination within grace period).
  5. Authenticated upload/archive and positive authentication flow using the test OAuth seam (`rust/src/phase0_oauth_mock.rs`).
  6. Helm chart linting, template rendering, and local Kubernetes rollout verification (API-only service selector, PVC binding, pod readiness, restart persistence).
  7. Security / negative regressions (no secrets in image layers/logs, no production paths mounted, unauthorized access rejected with 403).
  8. Repeatable end-to-end execution from a clean source checkout snapshot.
- **Documentation:** Update [`docs/CONTAINER_DEPLOYMENT.md`](CONTAINER_DEPLOYMENT.md) exit criteria matrix with concrete evidence, timings, and results; update [`docs/PROJECT_STATUS.md`](PROJECT_STATUS.md).

### What Deliberately Does NOT Change:
- **Production Windows Services:** `MediaServerRust` (:8000), `MediaServerPG` (:5432), and `MediaServerCaddy` (:80/:443) remain running on the host untouched.
- **Production Storage:** `D:\Flicks` (media library) and `E:\pgdata` (production PostgreSQL data) are strictly isolated and never mounted into test containers. All container tests use disposable temporary fixtures.
- **Cloud Infrastructure:** No remote cloud infrastructure, registries, or billable cloud resources will be provisioned in Phase 0.

---

## 2. Exit Criteria

- [ ] Docker Desktop daemon (`docker-desktop` WSL2) and local Kubernetes cluster are running and healthy.
- [ ] Clean, cache-independent Docker image builds successfully without Windows-specific path dependencies.
- [ ] [`scripts/phase0/phase0-regression.ps1`](../scripts/phase0/phase0-regression.ps1) completes with exit code 0 (`RESULT: PASS`).
- [ ] All 8 Phase 0 criteria in [`docs/CONTAINER_DEPLOYMENT.md`](CONTAINER_DEPLOYMENT.md) have recorded passing evidence.
- [ ] Production services and host data directories remain 100% unaffected.

---

## 3. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Port Conflict on :8000** | Compose API fails to bind because native `MediaServerRust` owns port 8000 | Compose configuration uses isolated private loopback port `18001` via `MEDIA_DOCKER_HTTP_PORT=18001` |
| **Accidental Production Storage Contamination** | Containers write to or delete production media | Default media directory is strictly bound to `.docker/local-data/media` or a random `$env:TEMP` path; D:\ and E:\ paths are explicitly forbidden in test runners |
| **Docker Desktop Cold Boot Delay** | Docker daemon takes 30–60s to initialize WSL2 VM | Bounded polling loop checks Docker engine readiness via `docker info` before launching regression scripts |
| **Child Process Leaks on Container Shutdown** | Interrupted FFmpeg processes remain orphaned | Verify Linux SIGTERM propagation and init process (`tini`/Compose `init: true`) cleans up all child workers |

---

## 4. Open Decisions

1. **Docker Desktop Startup Method:**
   - **Option A (Recommended):** Start Docker Desktop automatically via PowerShell command (`Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe"`) and wait for the daemon pipe to become ready.
   - **Option B:** User manually opens Docker Desktop from the Start menu / system tray.

---

## 5. Execution Steps

1. **Boot Docker Desktop:**
   - Start Docker Desktop Service and executable.
   - Poll `docker info` until Docker engine responds.
   - Verify `kubectl cluster-info` reaches the local Kubernetes cluster.
2. **Execute Automated Regression Suite:**
   - Run `.\scripts\phase0\phase0-regression.ps1` with logging.
   - Monitor test progression across build, compose, media ops, shutdown, and helm phases.
3. **Analyze Results & Update Documentation:**
   - Verify all test assertions pass cleanly.
   - Update `docs/CONTAINER_DEPLOYMENT.md` Phase 0 exit-criteria table.
   - Update `docs/PROJECT_STATUS.md`.
4. **Commit & Push:**
   - Commit verified Phase 0 deliverables to `codex/container-phase-0`.
   - Push branch to `origin/codex/container-phase-0`.

