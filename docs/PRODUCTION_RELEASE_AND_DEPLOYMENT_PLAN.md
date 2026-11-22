# Implementation Plan: Production Release (APK v1.4.13 & Rust Backend) and CI Verification

**Document Version:** 1.0  
**Target Date:** 2026-11-23  
**Status:** Pending User Approval  

---

## 1. Context & Objective

Following the amendment of the web footer note, the expansion of the web Privacy Policy modal, and the addition of the `PrivacyPolicyDialog` to the Flutter client, the user has authorized a full production release:
1. Compile, validate, and publish a new production Android APK release (`v1.4.13`, `versionCode 159`) via `scripts/release_android.py`.
2. Compile and restart the native Rust backend service (`MediaServerRust`) to serve the fresh `web/dist/` production bundle.
3. Update project documentation and session handoffs.
4. Commit and push the changes to `origin/main`.
5. Monitor and verify all 4 automated GitHub Actions CI workflow pillars before final confirmation.

---

## 2. Scope

### In Scope
1. **Android APK Production Release**:
   - Allocate `versionCode 159` (incrementing monotonic counter from 158).
   - Set version string to `1.4.13`.
   - Execute `python scripts/release_android.py --channel production --version 1.4.13 --version-code 159 --notes "..."`.
   - Verify `updates/production/manifest.json`, `updates/production/media-server-client.apk`, and `updates/version_registry.json`.
2. **Web Frontend Production Asset Build**:
   - Build optimized production bundle to `web/dist/` via `npm --prefix web run build`.
3. **Rust Backend Binary Build & Service Restart**:
   - Compile release binary: `cargo build --manifest-path rust/Cargo.toml --release`.
   - Gracefully restart `MediaServerRust` via `.\scripts\restart_rust_service.bat` and verify service health on port 8000.
4. **Pre-Push Quality Verification (Parity Suite)**:
   - Rust: `cargo test --manifest-path rust/Cargo.toml -- --test-threads=1`.
   - Web: `npm --prefix web run test`, `npm --prefix web run typecheck`, `npm --prefix web run lint`.
   - Flutter: `flutter analyze` and `flutter test test/features/settings/`.
5. **Documentation**:
   - Update `docs/PROJECT_STATUS.md`.
   - Create handoff log: `Handoffs/2026-11-23_01-45_gemini.md`.
6. **Git Commit, Push & CI Tracking**:
   - Stage deliverables and commit cleanly.
   - Push to `main`.
   - Track GitHub Actions workflow run until all 4 status checks pass (`Rust Backend`, `React 19 Frontend`, `Flutter Client`, `Secrets & Security Scan`).

### Out of Scope
- Database schema migrations (none required).
- Breaking API or client contract changes.

---

## 3. Exit Criteria

1. `updates/production/manifest.json` reports `version: "1.4.13"` and `versionCode: 159`.
2. `MediaServerRust` Windows service running healthy on port 8000 serving fresh `web/dist/`.
3. Clean Git status on `main` with all changes committed and pushed.
4. GitHub Actions CI pipeline passes all 4 pillars with green checkmarks on `main`.

---

## 4. Risks & Mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Flutter APK build failure or SDK path mismatch | Low | `release_android.py` has fallback discovery for Flutter SDK (`D:/src/flutter`, `C:/src/flutter`) and performs strict validation. |
| Rust service restart failure | Medium | Script validates NSSM service state and rolls back/warns if port 8000 fails health check. |
| GitHub CI failure / branch protection rejection | High | Full local Tier 2 pre-commit checks executed before pushing; CI status monitored live via `gh run watch`. |

---

## 5. Open Decisions

1. **Version Code & String**:
   - Monotonic `versionCode 159`
   - Release version `1.4.13`
2. **Release Notes**:
   - `"Added Privacy Policy & Architecture transparency modal to Settings; updated slogan to Zero 3rd-party tracking."`
