# Walkthrough: Serena MCP Project Configuration & Memories Update

## Summary
The Serena MCP local project configuration (`.serena/project.yml`) and project memories (`.serena/memories/*.md`) have been updated to accurately reflect the 100% Rust (Axum) + React 19 SPA + Flutter Client + PostgreSQL 18.4 stack. All obsolete references to the decommissioned Python runtime, Flask/Waitress web server, old Jinja templates, and non-existent Python test harnesses were purged and replaced with the current 4-pillar CI testing architecture and modularized file hierarchy.

---

## Deliverables & Key Changes

### 1. Project Configuration (`.serena/project.yml`)
- **Active Language Servers**:
  - Removed retired `python` language server from `language_servers` list.
  - Active list configured to: `rust`, `typescript`, `dart`.
- **Ignore Rules**:
  - Added explicit patterns to `ignored_paths` to prevent wasteful symbol indexing across heavy build artifacts and caches:
    - `target/**`
    - `flutter_client/build/**`
    - `flutter_client/.dart_tool/**`
    - `web/dist/**`
    - `web/node_modules/**`
    - `cache/**`
    - `.serena/cache/**`
- **Initial Prompt**:
  - Removed outdated references to Jinja2 templates (`templates/*.html`) and Pyright baseline errors.
  - Updated the embedded memory routing descriptions to reflect the modern modular codebase.

### 2. Testing Protocol Memory (`.serena/memories/testing-protocol.md`)
- **CI Pillars**: Documented the 4 required GitHub Actions checks (`Rust Backend`, `React 19 Frontend`, `Flutter Client`, `Secrets & Security Scan`).
- **Fast-Path Verification**:
  ```powershell
  cargo test --manifest-path rust/Cargo.toml -- --test-threads=1
  npm --prefix web run test
  npm --prefix web run typecheck
  cd flutter_client; flutter analyze; cd ..
  .\scripts\run_flutter_tests.ps1
  ```
- **Exhaustive Parity Suite**: Detailed commands for formatting, clippy, lint, production builds, and gitleaks scans.
- **Production Isolation Safeguards**:
  - Re-asserted `.\scripts\run_flutter_tests.ps1` to prevent `NativeReferenceHolder` PID recycling hangs in `media_kit`.
  - Documented backend test isolation through `media_server_api::test_support::test_config()`, ensuring zero contamination of production transcode cache or live PostgreSQL data (`MediaServerPG`).

### 3. Architecture Memory (`.serena/memories/architecture.md`)
- Updated the directory tree to reflect modularized domains:
  - `rust/src/routes/` (`catalog`, `identity`, `media_pipeline`, `ops`, `casting`)
  - `rust/src/services/` (`catalog`, `identity`, `media_pipeline`, `ops`, `casting`)
  - `web/src/` (React 19 SPA)
  - `flutter_client/` (Dart / Riverpod / media_kit)
- Clarified production topology across the three persistent NSSM Windows services: `MediaServerRust` (:8000), `MediaServerCaddy` (:80/:443), and `MediaServerPG` (:5432).

### 4. HLS Invariants Memory (`.serena/memories/hls-invariants.md`)
- Updated canonical implementation pointers from deleted Python files to native Rust services:
  - `rust/src/services/media_pipeline/chunk_transcode.rs`
  - `rust/src/services/media_pipeline/transcode_worker.rs`
  - `rust/src/services/media_pipeline/hls_service.rs`
  - `rust/src/services/media_pipeline/gpu_service.rs`
- Preserved all battle-tested transcode traps: strided segment indexing (`SEGMENTS_PER_CHUNK_STRIDE = 32`), `#EXTINF` honesty over container durations, fractional fps accounting, unknown frame `-1` handling, and in-progress `#EXT-X-START:TIME-OFFSET=0` timeline alignment.

### 5. Paths & Drives Memory (`.serena/memories/paths-and-drives.md`)
- Re-stated storage tiering invariants:
  - `C:\MediaServer` is completely deprecated and unused.
  - `E:\MediaServer` (fast SSD): Application, PostgreSQL data (`E:\pgdata`), preview cache, transcode cache, transcode scratch.
  - `D:\Flicks` (high capacity): Media library, uploads, archive, deleted.
- Preserved Windows platform rules: `CTRL_C_EVENT` prevention (never `os.kill(pid, 0)`), cross-volume collision pre-unlinking, and LocalSystem traversal protection.

### 6. Cache Cleanup
- Removed stale `.serena/cache/python` and `.serena/cache/html` symbol caches.

---

## Verification Results

| Tool / Check | Action | Outcome |
| :--- | :--- | :--- |
| `project.yml` validation | Verified YAML structure & encoding | Parsed cleanly without syntax errors |
| `read_memory(architecture)` | Verified retrieval via Serena MCP | Returns updated modular Rust & React architecture |
| `read_memory(testing-protocol)` | Verified retrieval via Serena MCP | Returns current 4-pillar CI suite commands & isolation rules |
| `read_memory(hls-invariants)` | Verified retrieval via Serena MCP | Returns Rust transcode service locations & core traps |
| `read_memory(paths-and-drives)` | Verified retrieval via Serena MCP | Returns drive tiering & Windows platform invariants |

