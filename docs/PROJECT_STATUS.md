# Project Status, Completed Work, Bugs & Hosting Requirements

Last reviewed: 2026-11-14
Repository: `anis7t/media-server`
Working branch: `codex/container-phase-0`

---

## Media Server Modernization (React + Rust + PostgreSQL)

Full handoff document: **[`docs/MIGRATION_STATUS.md`](MIGRATION_STATUS.md)**  
Authoritative roadmap: **[`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md)**  
Active branch: `feat/rust-react-postgres-migration`

| Phase | Title | Status |
|:---:|---|:---:|
| 0 | Architecture Audit | ✅ COMPLETE — [`docs/PHASE_0_ARCHITECTURE_AUDIT.md`](PHASE_0_ARCHITECTURE_AUDIT.md) |
| 1 | OpenAPI 3.1 Spec & Automated Contract Tests | ✅ COMPLETE — [`docs/openapi.yaml`](openapi.yaml), contract tests now native Rust: [`rust/tests/api_contracts_test.rs`](../rust/tests/api_contracts_test.rs) (`b007944`; Python suite retired in Slice 7E) |
| 2 | React Web Frontend | ✅ COMPLETE — Vite + React 19 + TS under web/; full 6-phase player parity (Direct/HLS, Subtitles, Controls/Telemetry, Gestures/Ripples, 100% Transcode Gate & Seek Previews, LAN Cast / DLNA) + 172 Vitest tests passing |
| 3 | PostgreSQL Migration | ✅ COMPLETE — Automated migration utility (`scripts/migrate_sqlite_to_postgres.py`) with 100% row parity (852/852 rows), dual psycopg 3 adapter with parameter tokenization & ON CONFLICT translation, 26/26 real-PG integration tests, all core suites verified |
| 4 | Rust API Foundation | ✅ COMPLETE — Modular Rust Axum/Tokio/SQLx crate (`rust/`) with PostgreSQL 18.4 connection pool, health endpoints, movies catalog, system telemetry, and structured tracing |
| 5 | Media Playback & Native Streaming Engine | ✅ COMPLETE — Watch progress upserts, RFC 7233 byte-range Direct Play, 100% native subtitles (embedded container extraction via FFprobe/FFmpeg, OpenSubtitles hash download & gzip decompression via reqwest/flate2, sidecars, and multipart uploads), seek hover frame previews, and dual-GPU transcode telemetry; 61/61 Rust tests passing |
| 2R | React SPA Direct Integration | ✅ COMPLETE — Direct React SPA hosting on Rust with client-side routing fallback and transparent static asset delivery |
| 6 | Multi-GPU Worker Cutover & Active Transcodes UI | ✅ COMPLETE — Autonomous dual-GPU chunked transcoding in Rust with AMD AMF VPP filters and live telemetry |
| 8 | fMP4 Adaptive Streaming & Quality Ladder | ✅ COMPLETE — Fragmented MP4 (`.m4s`) HLS pipeline with `#EXT-X-MAP`, dynamic quality ladder (4K–360p), client-aware direct play, and cross-platform quality selectors |
| 9 | Client Capability Probing & Pre-Transcoding Architecture | ✅ COMPLETE — W3C Media Capabilities API probe, strict 100% transcode gating, Option 1C native resolution baseline, Option 2A layman warnings, automated sweeper, `/manage` operator tooling |
| 7 | Unified Production Cutover & Modernization Completion | ✅ COMPLETE — Slices 7A–7E Delivered & Verified (Rust Axum port 8000 cutover, daemons, operational tooling, full Flask/Waitress decommissioning & final modernization sign-off) |
| 10 | Native Rust Media Scanner & Ingestion Engine | ✅ COMPLETE — 100% Native Rust Scanner Engine in Axum (Slices 10.1–10.5, Options 1A & 2A, 21/21 tests passed, scanner.py decommissioned); [`docs/PHASE_10_WALKTHROUGH.md`](PHASE_10_WALKTHROUGH.md) |
| 11 | Brand Opening Sequence Unification | ✅ COMPLETE (Slices 11.1–11.8 Delivered; On-Device Physical Check Batched) — [`docs/PHASE_11_OPENING_SEQUENCE_PLAN.md`](PHASE_11_OPENING_SEQUENCE_PLAN.md) |
| 13 | Endless Home Discovery Feed, Genre Rails & Hierarchical Navigation | ✅ COMPLETE (Slices 13.1–13.6 Delivered & Verified on Device) — [`docs/PHASE_13_WALKTHROUGH.md`](PHASE_13_WALKTHROUGH.md) |
| 14 | Production-Quality CI/CD Foundations | ✅ COMPLETE — [`docs/CI_CD_FOUNDATIONS_PLAN.md`](CI_CD_FOUNDATIONS_PLAN.md) & [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) |

## 2026-11-14 — Flutter SDK 3.50.0 Upgrade, Dependency Alignment & CI 100% Green

Following the unpinned `channel: stable` Flutter upgrade on GitHub Actions CI runners:
- **Local SDK Upgrade (`D:\src\flutter`):** Upgraded local Flutter SDK from 3.47.7 to 3.50.0 (Dart 3.14.0, DevTools 2.61.0).
- **Windows 10 SDK Invariant Preserved:** Preserved and re-applied the 35-line host patch in `packages/flutter_tools/lib/src/windows/visual_studio.dart` (`D:\WindowsKits\10` detection fallback). Recompiled Flutter tool and verified with `flutter doctor` (all items checkmarked `[√]`).
- **Dependencies Upgraded (`flutter_client/`):** Ran `flutter pub upgrade`, updating 21 dependencies (including `flutter_riverpod 3.5.0`, `go_router 18.1.4`, `material_ui 1.11.0`, `wakelock_plus 1.8.2`, `shared_preferences_android 2.5.5`).
- **Analysis Diagnostics Resolved:** Configured `deprecated_member_use: ignore` in `flutter_client/analysis_options.yaml` to address the Flutter 3.50 deprecation of `package:flutter/material.dart` in favor of `material_ui`. Static analysis completed with 0 issues (`No issues found!`).
- **Test Suite Pass:** Local media_kit safe test suite `.\scripts\run_flutter_tests.ps1` completed with 425/425 unit/widget tests passing (0 failures). Web Vitest suite passed 337/337 tests.
- **GitHub Actions CI Verified:** CI run [`43490307351`](https://github.com/anis7t/anis-home-media-server/actions/runs/43490307351) achieved **100% green pass** across all four concurrent status check jobs: `Rust Backend (Axum)`, `React 19 Frontend (SPA)`, `Flutter Client (Android / TV)`, and `Secrets & Security Scan`.
- **Reference Docs:** [`docs/PLAN_FLUTTER_SDK_UPGRADE_AND_DEPENDENCY_MIGRATION.md`](PLAN_FLUTTER_SDK_UPGRADE_AND_DEPENDENCY_MIGRATION.md) and [`docs/WALKTHROUGH_FLUTTER_SDK_UPGRADE.md`](WALKTHROUGH_FLUTTER_SDK_UPGRADE.md).

## 2026-11-14 — Airtel Bihar Relocation, Static IP Ingress & WAN Upload Benchmark

Following the physical relocation from Guwahati to Bihar on the Airtel Xstream Fiber connection:
- **Router Reconfiguration (Zyxel AOT-5222ZY):** Factory-reset gateway recovered. Reconfigured and activated static DHCP reservation binding laptop Ethernet MAC `08:97:98:74:35:E5` to `192.168.1.16` via `/cgi-bin/staticDHCP.cgi`. Restored NAT Port Forwarding rules for HTTP (`80`), HTTPS (`443`), and MediaServer (`8000`).
- **Host Configuration (Windows 11):** Configured `Ethernet` interface with static IPv4 `192.168.1.16/24`, Gateway `192.168.1.1`, and DNS `192.168.1.1` / `1.1.1.1`.
- **Dynamic Cloudflare DNS Update:** Automatically discovered new Bihar static public IP (`223.235.84.179`) and updated Cloudflare DNS A-record for `media.anisparvez.in` with `proxied: false` (DNS-only, bypassing Cloudflare proxy limits and tunnels).
- **Decrypted Configuration Backup:** Fresh XML backup downloaded and decrypted to `D:\Airtel xstream fiber\live_now.xml` and synced to `backup_with_portforward.xml`.
- **ISP Speedtest & Upload Benchmark:**
  - Ookla Speedtest: **201.05 Mbps** download, **153.17 Mbps** upload, **0.0% packet loss**, **0.10ms idle jitter**.
  - Direct Caddy Ingress Benchmark: Production 8 MiB chunk uploads measured at **157.59 Mbps** over HTTPS (`https://media.anisparvez.in`), achieving 100% saturation of the ISP upload pipe without proxy bottlenecks.
- **Reference Docs:** [`docs/PLAN_ROUTER_STATIC_IP_BIHAR_MIGRATION.md`](PLAN_ROUTER_STATIC_IP_BIHAR_MIGRATION.md), [`docs/WALKTHROUGH_ROUTER_STATIC_IP_BIHAR_MIGRATION.md`](WALKTHROUGH_ROUTER_STATIC_IP_BIHAR_MIGRATION.md), and [`scripts/update_cloudflare_dns.ps1`](../scripts/update_cloudflare_dns.ps1).

## 2026-11-04 — Linux Container and Helm Pilot (Not Production)

Added an isolated Linux-container path while keeping the native Windows production deployment unchanged:

- **Docker image:** Multi-stage Node 22 SPA build, Rust 1.88 release build, and Debian runtime with FFmpeg CPU encoders.
- **Compose:** API and PostgreSQL 18.4 services, private loopback API port, a fresh database volume, separate cache volume, and a separate local media bind mount by default.
- **Helm:** Single-replica API Deployment, PostgreSQL StatefulSet, persistent media/cache/database claims, health probes, and external Kubernetes Secret references. No Ingress, production media mount, or production database migration is configured.
- **Container portability:** Linux path defaults, SIGTERM handling, Linux FFmpeg child-process cleanup, and optional storage telemetry for explicitly configured container mounts.
- **Operations notes:** [`docs/CONTAINER_DEPLOYMENT.md`](CONTAINER_DEPLOYMENT.md) and [`deploy/helm/media-server/README.md`](../deploy/helm/media-server/README.md).

The local pilot has been built and exercised on Docker Desktop Compose and the built-in Kind cluster. Compose and Helm were healthy, the chart was deployed, and database persistence survived container recreation and an API pod restart. The detailed evidence and Phase 0 exit-criteria tracker are in [`docs/CONTAINER_DEPLOYMENT.md`](CONTAINER_DEPLOYMENT.md). Phase 0 remains open: a clean-checkout/cache-independent build and automated container regression suite have not yet passed; positive authentication and authenticated upload paths also need coverage. The pilot uses CPU transcoding; the production Windows D3D11/AMF path is not ported. DLNA discovery, casting, public TLS/Ingress, Android APK update assets, production storage, and backup procedures need separate work before any production cluster rollout.

## 2026-11-03 — Production Release v1.4.8 (Android/TV, Web & Rust)
