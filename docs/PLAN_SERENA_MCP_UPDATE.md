# Implementation Plan: Update Serena MCP Configuration & Project Memories

## 1. Scope

### In Scope
- **`E:\MediaServer\.serena\project.yml`**:
  - Remove retired `python` language server from `language_servers` list (retaining active `dart`, `typescript`, `rust`).
  - Add explicit `ignored_paths` for build artifacts and dependency trees (`target/**`, `flutter_client/build/**`, `web/dist/**`, `cache/**`, `web/node_modules/**`, `.dart_tool/**`) to prevent symbol indexing overhead.
  - Purge decommissioned Jinja2 and Pyright notes from `initial_prompt`.
- **`E:\MediaServer\.serena\memories\testing-protocol.md`**:
  - Replace defunct Python pytest (`.\venv\Scripts\python.exe -m pytest tests/`) and non-existent `tests/conftest.py` references with current fast-path and local parity CI suites:
    - Rust: `cargo test --manifest-path rust/Cargo.toml -- --test-threads=1`, `cargo clippy`, `cargo fmt`
    - React Frontend: `npm --prefix web run test`, `npm --prefix web run typecheck`, `npm --prefix web run lint`
    - Flutter Client: `flutter analyze` in `flutter_client/` and `.\scripts\run_flutter_tests.ps1`
    - Secrets & Security: `gitleaks git --pre-commit`
  - Reaffirm cache and database test isolation invariants via `media_server_api::test_support::test_config()`.
- **`E:\MediaServer\.serena\memories\architecture.md`**:
  - Update file tree map to reflect the modularized Rust architecture:
    - `rust/src/routes/` (`catalog/`, `identity/`, `media_pipeline/`, `ops/`, `casting/`)
    - `rust/src/services/` (`catalog/`, `identity/`, `media_pipeline/`, `ops/`, `casting/`)
    - `rust/src/services/media_pipeline/` (`chunk_transcode.rs`, `transcode_worker.rs`, `gpu_service.rs`, `hls_service.rs`, `transcode_sweeper.rs`, `preview_service.rs`, `probe_service.rs`)
    - `rust/src/services/catalog/` (`scan_service.rs`, `tmdb.rs`)
  - Update React 19 SPA (`web/src/`) and Flutter client (`flutter_client/lib/features/`) layout descriptions.
- **`E:\MediaServer\.serena\memories\hls-invariants.md`**:
  - Replace references to deleted Python transcode service with the canonical Rust implementation (`rust/src/services/media_pipeline/chunk_transcode.rs`, `transcode_worker.rs`, `hls_service.rs`).
  - Update active verification scripts list.
- **`E:\MediaServer\.serena\memories\paths-and-drives.md`**:
  - Align routing details with native Rust endpoints and current multi-volume drive tiering (`E:` runtime/cache/PG data, `D:` media library/staging).

### Deliberately Out of Scope
- No changes to application code in `rust/`, `web/`, or `flutter_client/`.
- No modifications to database schemas or PostgreSQL services.
- No changes to global Serena configuration (`C:\Users\anis7\.serena\serena_config.yml`).

---

## 2. Exit Criteria
1. **YAML Validity**: `E:\MediaServer\.serena\project.yml` is valid YAML and successfully parsed by Serena.
2. **Clean Project Activation**: Calling Serena's `activate_project` or `get_current_config` confirms:
   - Active language servers are `dart`, `typescript`, `rust` (no extraneous `python` LSP spawned).
   - Memory routing table in `initial_prompt` embeds clean, up-to-date instructions.
3. **Accurate Memory Retrieval**: `read_memory` for all 4 project memories (`architecture`, `hls-invariants`, `paths-and-drives`, `testing-protocol`) returns 100% current state consistent with `AGENTS.md` and repository reality.
4. **Zero Regressions**: No existing invariants from `AGENTS.md` are omitted or contradicted.

---

## 3. Risks & Mitigations
- **Risk**: Serena cache inconsistency after removing Python language server.
  - **Mitigation**: Clean obsolete cache entries in `.serena/cache/python` if needed and re-activate project via `activate_project` MCP tool to rebuild state.
- **Risk**: Omitting critical production invariants during memory clean-up.
  - **Mitigation**: Strictly preserve all battle-tested invariants (strided segment index handling, `#EXTINF` duration honesty, negative-one frame indicator semantics, Windows `CTRL_C_EVENT` prevention, `NativeReferenceHolder` cleanup in Flutter test script).

---

## 4. Open Decisions
- None identified. The changes align Serena MCP configuration strictly with the decommissioned status of Python/Flask and the current modular Rust + React 19 + Flutter stack.

