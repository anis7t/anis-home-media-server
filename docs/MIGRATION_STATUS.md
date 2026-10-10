# Media Server Modernization — Migration Status & Handoff

**Authoritative Roadmap:** [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md)
**Dedicated Branch:** `feat/rust-react-postgres-migration`
**Current HEAD:** `99e63ed2fe6bca4172e9f4f263855be7d2016938` — *`feat(db): add PostgreSQL schema migrations and harden cleanup`* (2026-10-10)
**Baseline Commit (previous revision of this document):** `b007944`
**Last Updated:** October 10, 2026

> This revision consolidates the PostgreSQL adapter work (Phase 3.1–3.8G) that has
> accumulated in the working tree since the `b007944` baseline. Every claim below is
> labelled by evidence class — see §10. Nothing here asserts that any test has been
> executed unless the execution is recorded with its phase.

---

## 1. Executive summary

The migration is **partially complete and out of sequence**. Phases 0, 1 and a
substantial portion of Phase 3 have been delivered. Phase 2 (React web frontend) has
**not been started**, yet Phase 3 work proceeded — a deliberate-looking deviation that
the roadmap does not sanction. Phases 4–7 (Rust) have not been started at all.

What can be claimed:

- The PostgreSQL adapter, versioned migrations, advisory locking and pool lifecycle
  are **committed** at HEAD.
- Test isolation and write guards are **written and statically reviewed but never
  executed** under authorization in this phase history.
- Cache-destructive-path hardening is **written, statically reviewed, and partly
  runtime-verified only through a single disposable `verify` run**.

What cannot be claimed:

- **No runtime test confidence exists for any Phase 3.3–3.8G work.** Every new test
  module in the working tree is untracked and has only ever passed `compile()` and
  `ast.parse()`.
- **The Phase 3 exit gate is not met.** The roadmap requires demonstrated data
  transfer and recovery, representative regression tests against PostgreSQL, and
  unambiguous write ownership (roadmap §5, Phase 3). None of the three is satisfied.
- **Production cache recovery is not claimed, attempted, or known to be possible.**

---

## 2. Migration plan and source of truth

### 2.1 Authoritative documents and their roles

| Document | Role |
|---|---|
| `docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md` | **The governing plan.** Goals, non-negotiable rules, target architecture, phase sequence, per-phase exit gates, testing gates, risk register, cutover/rollback strategy, definition of done. Status line still reads *"Proposed roadmap only."* |
| `docs/MIGRATION_STATUS.md` (this file) | Execution tracker and handoff for the branch above. |
| `docs/PHASE_0_ARCHITECTURE_AUDIT.md` | Phase 0 deliverable — route inventory, schema inventory, Flutter compatibility matrix, risk register. |
| `docs/PHASE_1_MIGRATION_STATUS.md` *(does not exist)* | Referenced in commit `9766edc` history but absent from `docs/`; Phase 1 status was folded into this document. |
| `docs/openapi.yaml` + `tests/test_api_contracts.py` | Phase 1 executable contract — the compatibility reference for later phases. |
| `docs/PROJECT_STATUS.md` | Operational status of the *running Flask application*; not a migration artifact. |
| `docs/REPOSITORY_ASSESSMENT_AND_ROADMAP.md` | Pre-migration assessment; superseded by the roadmap for planning purposes. |

### 2.2 Governing goals (roadmap §1–§2)

Migrate Flask → **Rust (Axum/Tokio/SQLx) + React/TypeScript + PostgreSQL**, keeping
FFmpeg as the processing engine and the Flutter/Fire TV client working. Ten
non-negotiable rules apply; four are directly implicated by current state:

| Rule | Current state |
|---|---|
| 2 — Preserve behavior before replacing implementation | Held. No playback/streaming/transcode behavior was altered. |
| 4 — Separate risky changes | **Partially violated.** Phase 3 database work and a cache-destructive-path change are in the same uncommitted body of work. |
| 6 — Keep `main` releasable | **At risk.** The branch is 2 commits ahead of `origin` and unpushed; 16 modified + 13 untracked files sit uncommitted on top. |
| 7 — No destructive cutover without evidence | **Violated in practice.** A production cache deletion occurred during Phase 3.8 diagnosis. No backup or restore evidence is documented anywhere. |

### 2.3 Conflicts and gaps in the documentation

1. **Phase numbering diverges.** The roadmap defines Phases 0–7. The previous revision
   of this document defined 0–9, splitting roadmap Phase 7 into "Live Events" (7),
   "Operations" (8) and "Deprecation" (9). Neither document references the other's
   numbering. **Unreconciled — needs a decision.**
2. **The previous status revision is materially stale.** It recorded baseline
   `b007944`, marked Phase 2 "PENDING AUTHORIZATION" and Phase 3 "Planned", and
   asserted *"Zero Production Changes: No production Flask code … modified."* That
   assertion is now **false**: nine files under `app/` are modified and uncommitted.
3. **No phase weights exist.** Neither document defines measurable completion
   criteria or weighting, so **a defensible numeric completion percentage is
   unavailable** (§7).
4. **Roadmap §3 status line is stale.** It still states implementation has not been
   authorized, which no longer matches the repository.
5. **Acceptance criteria are stated only as exit gates**, not as measurable
   thresholds (no coverage %, no performance budget, no reconciliation tolerance).

---

## 3. Progress matrix

Status key: **Complete** · **Partially complete** · **Blocked** · **Not started** · **Unverified**

| Workstream | Intended outcome | Implementation evidence | Validation evidence | Status | Remaining work |
|---|---|---|---|---|---|
| **P0 — Architecture audit** | Evidence-based inventory before code changes | `docs/PHASE_0_ARCHITECTURE_AUDIT.md` | Documented; reviewed | **Complete** | None known |
| **P1 — API contracts & contract tests** | OpenAPI 3.1 spec + executable contract tests | `docs/openapi.yaml`, `tests/test_api_contracts.py` (both committed at `b007944`) | Reported 15/15 contract tests and 98 regression tests passing at Phase 1 | **Complete** (reported) | Re-verify; `test_api_contracts.py` is implicated in a known ordering failure (§6, item 10) |
| **P2 — React web frontend** | Vite/React/TS app in `web/` against the existing Flask API | **No `web/` directory, no `package.json`** | None | **Not started** | Entire phase |
| **P3.1 — PostgreSQL adapter** | Dual SQLite/PostgreSQL backend, versioned migrations, advisory locking, pool lifecycle | `app/db.py`: `POSTGRES_MIGRATIONS` (:311), `_validate_postgres_migrations` (:409), `run_postgres_migrations` (:509), `pg_advisory_lock` (:538/:612/:636), `schema_migrations` (:547/:669/:754), `_PG_POOL`/`_PG_POOL_LOCK` (:24-25). **Committed at `99e63ed`.** | Reported: 72 adapter tests (1 skipped), 23 API tests | **Partially complete** (reported) | Reconciliation, rollback plan, production cutover — all exit-gate items still open |
| **P3.2 — PostgreSQL integration tests** | Opt-in real-PG tests against an isolated schema | `tests/integration/{conftest,test_postgres_migrations,test_postgres_timestamps}.py` + `README.md` (untracked) | Reported 26 tests passing against PG 18.4; clean skip when gate closed | **Partially complete** (reported, untracked) | Never re-run under authorization |
| **P3.3 — Timestamp compatibility** | Normalize SQLite string ↔ PG datetime at the DB→app boundary | `app/utils/formatting.py` (+77), `app/services/device_service.py`, `app/services/media_service.py`; `tests/test_timestamp_compat.py` (untracked) | Reported focused results positive; **baseline suite had 38 failures** | **Partially complete** (reported) | Full-suite re-run |
| **P3.4–3.7 — Test isolation & write guards** | No test may write to a deployed path | `tests/conftest.py` (+374), `tests/test_app.py` (+59), `tests/_isolation_paths.py`, `tests/_write_guard.py`, `tests/test_write_guard.py`, `tests/test_isolation_guard.py` (all untracked) | Reported 45 guard tests passing; `git diff --check` exit 0 | **Partially complete** — never executed under authorization in this history | Authorized run; `CachePurgeSafetyTests` isolation defect (§6, item 8) |
| **P3.8 — Cache/destructive-path hardening** | `MEDIA_SERVER_CACHE_DIR`; centralized cache-root boundary; refusal reporting | `app/config.py` (+115): `CacheRootUnsafe`, `approved_cache_root` (:81), `require_within_cache_root` (:122). `transcode_service.py` (+116), `media_service.py` (+46), `subtitles_service.py` (+63), `api.py` (+5), `worker_service.py` (+10) | One disposable `verify` run exited 0 with `VERIFY OK` (Phase 3.8G8P) | **Partially complete** | Enumeration completeness; A8/A13/A14; C3–C6 |
| **P3.8G — Cache-safety boundary tests** | Executable coverage of the cache-root boundary | `tests/_cache_test_support.py`, `tests/test_cache_safety_boundaries.py` (**19 test definitions**) | `compile()` + `ast.parse()` + `git diff --check` only | **Unverified** — static-only | First authorized execution |
| **P4 — Rust API foundation** | Modular Axum app | **No `rust/`, `crates/`, or `Cargo.toml`** | None | **Not started** | Entire phase |
| **P5 — Rust media/playback/streaming** | Library, range streaming, HLS in Rust | None | None | **Not started** | Entire phase |
| **P6 — Rust transcoding worker** | Queue ownership + FFmpeg orchestration | None | None | **Not started** | Entire phase |
| **P7 — Cutover, hardening, Flask retirement** | Staged cutover, tested rollback | None | None | **Not started** | Entire phase; blocked by P2–P6 |
| **Deployment / operations** | Preserve NSSM + Cloudflare topology | Unmodified; `.gitignore` (uncommitted) already anticipates `target/`, `node_modules/`, `pgdata/`, `.pgpass` | None in this branch | **Not started** | Cutover evidence (roadmap §9) |
| **Rollback / data safety** | Backup + demonstrated restore + point-of-no-return | **No documented backup, restore drill, or rollback window** | None | **Blocked** | Required by roadmap §9 and Phase 3 exit gate before any cutover |
| **Acceptance testing** | Per-phase exit gates met | Only the two Phase 0/1 gates have artifacts | Not re-verified | **Blocked** | Depends on an authorized full-suite run |

---

## 4. Current repository state

Read-only inspection performed 2026-10-10.

```
Branch            : feat/rust-react-postgres-migration
HEAD              : 99e63ed2fe6bca4172e9f4f263855be7d2016938
HEAD subject      : feat(db): add PostgreSQL schema migrations and harden cleanup
Ahead of origin   : 2 commits  (99e63ed, 10b7295) — NOT pushed
Staged            : 0
Modified (tracked): 16
Untracked         : 13
git diff --check  : exit 0 (no whitespace errors)
```

### 4.1 Committed vs uncommitted

**Committed (2 commits ahead of `origin`, unpushed):**

| Commit | Subject |
|---|---|
| `9766edc` | docs: add Phase 0 architecture audit and Phase 1 migration status documentation |
| `b007944` | feat(api): add OpenAPI 3.1 specification and automated contract test suite (Phase 1) |
| `03a2ea4` | feat(db): implement SQLite/PostgreSQL database adapter (Stage 1) and capture workspace state |
| `10b7295` | feat(db): normalize queries to ON CONFLICT and harden connection lifecycle (Phase 2) |
| `99e63ed` | feat(db): add PostgreSQL schema migrations and harden cleanup |

**Modified and UNCOMMITTED (16 files, +1229/−117):**

| Area | Files |
|---|---|
| Application code (**9**) | `app/config.py`, `app/routes/api.py`, `app/utils/formatting.py`, `app/services/{device,media,subtitles,system,transcode,worker}_service.py` |
| Tests (3) | `tests/conftest.py`, `tests/test_app.py`, `tests/test_storage_retention.py` |
| Tooling / user-owned (4) | `.gitignore`, `.vscode/settings.json`, `opencode.json`, `docs/AGENT_EXTENSIONS.md` |

**Untracked (13):** `tests/_cache_test_support.py`, `tests/test_cache_safety_boundaries.py`,
`tests/_isolation_paths.py`, `tests/_write_guard.py`, `tests/test_write_guard.py`,
`tests/test_isolation_guard.py`, `tests/test_timestamp_compat.py`,
`tests/integration/{README.md,conftest.py,test_postgres_migrations.py,test_postgres_timestamps.py}`,
plus user-owned `.vscode/extensions.json` and the root `=` artifact.

> `tests/test_storage_retention.py` carries **+139/−41 uncommitted**. The committed
> version contains **zero** occurrences of `_dedicated_cache_root`; the working tree
> contains five. The dedicated-root correction described in §6 item 9 is therefore
> **entirely uncommitted**.

All user modifications, untracked files and the reported `D:\Flicks` Mayday artifacts
are preserved. Nothing has been staged, committed, pushed, reset, restored, cleaned or
branch-switched during this documentation task.

---

## 5. Phase history

Distinguishing **runtime-executed**, **statically validated**, and **reported-only**.

| Phase | Work | Evidence class | Notes |
|---|---|---|---|
| 3.1 | PostgreSQL adapter, migrations, advisory locking, identity columns, pool close safety | **Runtime-tested (reported)** + committed | 72 adapter tests (1 skipped), 23 API tests. Not re-run since. |
| 3.2 | Integration tests gated on `MEDIA_SERVER_TEST_POSTGRES_URL`, per-test `pgi_<hex>` schema, fail-closed DB-name validation | **Runtime-tested (reported)** | 26 tests vs PG 18.4. Dedicated test database, not `media_dev`. Untracked. |
| 3.3 | `parse_db_timestamp` / `format_db_timestamp`; device + media service updated | **Runtime-tested (reported)** | Focused runs positive; baseline suite still showed 38 failures. |
| 3.4–3.7 | Isolation roots, dotenv-override repair, upload-target leak fix, `isolation_guard`, write guard (13 patches) | **Runtime-tested (reported)**, then **statically validated** | 45 guard tests reported passing. Full suite **not** re-run after later hardening. |
| 3.8 | `MEDIA_SERVER_CACHE_DIR`; cache-root boundary centralized in `app/config.py`; guarded purge/cleanup paths; refusal reporting | **Runtime-tested (reported)** | Response to a production cache-deletion incident. |
| 3.8G8A–N | Disposable bootstrap gate hardened (env swap, nested teardown, guarded restoration, ownership bookkeeping) | **Compile/AST only** | Gate never executed during those phases. |
| 3.8G8P | **One** authorized `python -B gate.py verify` run | **Runtime-executed** | Exit 0, `[GATE] VERIFY OK`, 13/13 patches installed and released, environment restored, 10/10 app↔config snapshots agreed. Proves *containment*, not destructive-path behavior. |
| 3.8G8Q | Read-only test plan; coverage matrix; enumeration-completeness analysis | **Read-only analysis** | Delivered this plan; no files written. |
| 3.8G8R/T/U | Stage A (5 tests), Stage B (6 tests), Stage C (6 tests), Stage D (2 tests) | **Compile/AST + `git diff --check` only** | 19 test definitions total in `tests/test_cache_safety_boundaries.py`. **Never executed.** |

### 5.1 The production cache incident

During Phase 3.8 diagnosis, a standalone script ran outside pytest. The cache-root
override did not yet exist and the script never rebound the in-memory cache attribute,
so `get_cache_dir()` resolved to the deployed cache tree. Media enumeration was
incomplete but non-empty, so the audit could not distinguish it from a complete
library. The reported result was deletion of **53 production cache directories**.

Two lessons are recorded in code: the cache-root boundary (`app/config.py:81-142`) and
the enumeration-completeness check (`transcode_service.py:340-356`).

**This document makes no claim that the deleted data is recoverable, and no recovery
was attempted.** What is documented: the guard added afterwards would **not** have
prevented this incident, because the fault was the *media enumeration*, not the cache
path. That half is addressed by the missing-root check; the broader half is not (§6).

---

## 6. Open risks and blockers

Status vocabulary: **Confirmed (static)** · **Reported, not rechecked** · **Partially mitigated** · **Blocked** · **Unknown**

| ID | Issue | Source reference | Severity | Status | Next action | Blocks "complete"? |
|---|---|---|---|---|---|---|
| **1** | **Enumeration completeness.** If every configured root exists but the walk silently omits media — including basename dedup collapsing two distinct files (`media_service.py:64-67`) or a root skipped without a word (`:58-59`) — the audit reports `degraded=False` and classifies live cache directories as orphaned (`transcode_service.py:414`). | `media_service.py:58-59,64-67`; `transcode_service.py:346-356,414,465-472` | **Critical** | **Confirmed (static)**; sentinel test C-B7 documents it and asserts no fix | Production decision required: a completeness signal from `video_paths()` or an enumeration self-report. A coverage threshold must **not** be invented. | **Yes** |
| **2** | **A8 — per-file containment.** `cleanup_cache()` validates only the `transcodes` directory once, then unlinks globbed files individually. | `transcode_service.py:247` (dir check); `:256`, `:262`, `:270` (unlinks) | **Medium** | **Confirmed (static)**; test deliberately not written | Application decision: re-validate each file, or document the directory check as sufficient | No |
| **3** | **A13 — local poster containment.** A DB-derived `local:` poster path is joined onto `MEDIA_ROOT` and unlinked with **no** `_is_within_media_roots` check and a bare `except: pass` — unlike the adjacent media-file deletion at `:427` which *does* check. | `media_service.py:397-404` (vs `:427`) | **High** | **Confirmed (static)** | Add containment validation mirroring `:427` | No |
| **4** | **A14 — archive / delete-source containment.** Target paths are built from a relative media path and unlinked without a media-root or archive-root containment check. | `transcode_service.py:627-633` (archive), `:660-665` (delete_source) | **High** | **Confirmed (static)** | Add containment validation before `target_path.unlink()` | No |
| **5** | **C3 — subtitle refusal propagation.** Refusals are recorded locally and logged, but the function returns only the flat `purged` list, so a caller cannot distinguish a refusal from an absent file. | `subtitles_service.py:370-431` (return at `:431`) | **Medium** | **Confirmed (static)**; documented in the test module, not asserted away | Return a structured result or a refusal list alongside `purged` | No |
| **6** | **C4/C5 — media purge refusal propagation.** `purge_media()` returns `'success': True` unconditionally regardless of `refused_cache_deletes`; the delete route returns it verbatim with HTTP 200. | `media_service.py:455` (vs `:463`); `api.py:568-575` | **High** | **Confirmed (static)** | Derive `success` from `refused_cache_deletes`; review the HTTP status | No |
| **7** | **C6 — post-transcode status masking.** `apply_post_transcode_policy()` returns `status='cache_purged'` unconditionally, even when the inner purge recorded refusals. | `transcode_service.py:684-692` (refusals at `:2159`) | **Medium** | **Confirmed (static)** | Derive status from the inner result | No |
| **8** | **`CachePurgeSafetyTests` isolation defect.** `setUp` uses `get_cache_dir()`, which conftest re-points at the **shared session cache** before every test; two tests then perform **live purges** against it with a single-file mocked enumeration. Any other directory in that shared tree is classified orphaned and deleted. | `test_storage_retention.py:407-408`, live purges at `:460` and `:482`; shared cache imposed by `conftest.py:278-286,513` | **Medium** (intra-session interference; production cache is not reachable) | **Confirmed (static)** | Re-home onto a dedicated root per test (Stage G) | No |
| **9** | **Retention-test correction uncommitted and untested.** `test_audit_and_purge_orphaned_caches` was given a dedicated cache root and its post-purge assertions inverted, but the change is uncommitted (`+139/−41`) and has never been executed. | `test_storage_retention.py:59-91` (helpers), `:119-228` (test), `:203-208` (inverted assertions) | **Medium** | **Confirmed (static)**; **runtime-unverified** | Commit decision, then an authorized focused run | No |
| **10** | **Historical full-suite failures.** A baseline run showed 38 failures, including `test_audit_and_purge_orphaned_caches` and order-dependent `test_app.py` failures. Root causes were diagnosed for two of them (module import ordering in `test_api_contracts.py` vs `test_app.py`; contradictory assertions in the retention test). | Reported; root causes diagnosed in Phase 3.8 | **High** | **Reported, not rechecked** | An authorized full-suite run is required before any completion claim | **Yes** |

### 6.1 Additional risks from the roadmap register

| Risk | Relevance today |
|---|---|
| Data loss during DB conversion (**Critical**) | **No documented backup, restore drill, or rollback window exists.** Directly required by the Phase 3 exit gate. |
| Queue split-brain / duplicate FFmpeg work (**Critical**) | Not yet applicable — Rust worker is not started. |
| Auth/security mismatch (**Critical**) | The roadmap requires an explicit authz matrix. `api_delete_media` returning HTTP 200 for a partly-refused delete is a relevant precedent (item 6). |
| Rewrite scope grows too broad (High) | The Phase 3.8 cache-hardening effort is unrelated to the migration's stated purpose and consumed substantial effort on a single branch. |

---

## 7. Assessment — are we on the correct path?

### 7.1 Direct answer

**Partially.** The *technical* direction matches the roadmap; the *sequencing and
branch discipline* do not.

**What supports alignment:**

- The PostgreSQL adapter was built to the roadmap's Phase 3 task list: versioned
  migrations, advisory locking, an explicit `schema_migrations` table, and a
  dual-backend abstraction rather than a big-bang replacement.
- `schema_migrations` plus `pg_advisory_lock` is the correct idempotency primitive for
  the required "idempotent migration/transfer utility" (roadmap §5, Phase 3 task 5).
- Compatibility was preserved: no playback, streaming, transcoding or client-facing
  behavior was altered.
- The uncommitted `.gitignore` additions (`target/`, `node_modules/`, `pgdata/`,
  `.pgpass`) anticipate exactly the roadmap's Phase 2 and Phase 4 toolchains.
- The cache-root hardening is a genuine safety improvement, and its analysis is
  documented rather than asserted.

**Where it has deviated or exposed gaps:**

1. **Phase order was skipped.** The roadmap sequences Phase 2 (React) before Phase 3
   (PostgreSQL) and states Phase 3 "Depends on Phase 0 and an agreed data
   ownership/cutover strategy" — not on Phase 2. Proceeding to Phase 3 while Phase 2 is
   untouched is a real deviation. *It may have been an intentional reprioritization, but
   no document records that decision.*
2. **Rule 4 was violated in practice.** Database work and a destructive-path change
   share one uncommitted working tree.
3. **Rule 6 is at risk.** 2 unpushed commits and 29 uncommitted/untracked files.
4. **The Phase 3 exit gate is unmet on all three clauses**: no demonstrated transfer or
   recovery, no representative regression run against PostgreSQL, and no documented
   write-ownership decision for a Flask/Rust coexistence that does not yet exist.
5. **No numeric percentage is defensible.** Neither document defines phase weights or
   measurable acceptance thresholds. Qualitative bands follow instead.

| Dimension | Band | Basis |
|---|---|---|
| Implementation progress (roadmap phases) | **Early-middle** | 2 of 8 phases delivered; a third (Phase 3) substantially built but not gate-passed; Phase 2 skipped; Phases 4–7 untouched. |
| Test confidence | **Low** | The entire Phase 3.3–3.8G body of new tests is untracked and unexecuted. Last full-suite run showed 38 failures, unverified since. |
| Operational safety | **Degraded, recovering** | A production cache deletion occurred. Mitigations are written and partially runtime-verified. No backup/restore evidence exists. |
| Production readiness | **Not applicable** | PostgreSQL is not the canonical store; no cutover has been attempted or is close. |

### 7.2 Biggest blockers

1. **Enumeration completeness (issue 1).** Only a live-cache-misclassification bug that
   can delete real transcodes. It requires a production design decision, not a test.
2. **No backup, restore drill, or rollback window (roadmap §9, Phase 3 exit gate).**
   This blocks any cutover regardless of code quality.
3. **Zero runtime validation of ~1,229 uncommitted lines and 19 new test definitions.**
4. **Issue 10 (38 historical failures) unresolved** — no completion claim is defensible
   until an authorized full-suite run exists.

---

## 8. Recommended resumption sequence

Each step is small and independently reviewable. Static work and runtime work are kept
separate, and **every runtime step requires explicit authorization**.

| # | Step | Type | Gate before proceeding |
|---|---|---|---|
| 1 | **Freeze and document the working tree.** Decide, per modified file, whether it belongs on this branch. Split the Phase 3.8 cache-hardening work onto its own branch — it is not a migration deliverable and violates roadmap rule 4. | Static | User decision recorded in this document |
| 2 | **Resolve the documentation conflicts in §2.3** — phase numbering, stale roadmap status line, and the missing measurable acceptance criteria. | Static | Both documents agree on numbering |
| 3 | **Reconcile the four tracked-vs-untracked boundaries** for `tests/test_storage_retention.py`, `tests/conftest.py` and `tests/test_app.py`. | Static | — |
| 4 | **Apply the four confirmed application fixes** — A13, A14, C4/C5, C3, C6 (items 3–7). Each is small, source-local and independently reviewable. | Static | Per-fix review; no test may be weakened |
| 5 | **Decide A8** (item 2) — re-validate per file, or document the directory check as the accepted boundary. | Design | Explicit decision recorded |
| 6 | **Re-home `CachePurgeSafetyTests` onto a dedicated root** (item 8). | Static | — |
| 7 | **First authorized execution: Stage A–D boundary tests only.** Run `tests/test_cache_safety_boundaries.py` in isolation. This is the first point at which any Phase 3.8G code has ever executed. | **Runtime — authorization required** | Stop and report results before anything else |
| 8 | **Authorized focused runs:** `tests/test_write_guard.py`, `tests/test_isolation_guard.py`, `tests/test_timestamp_compat.py`, `tests/test_storage_retention.py`. | **Runtime — authorization required** | Each reports separately |
| 9 | **Authorized full-suite run** with the cache/DB/media isolation proof (snapshot library list, `movies` rows and cache directory list before and after). | **Runtime — authorization required** | Resolves item 10 |
| 10 | **Re-baseline the suite.** Record the true failure count; fix ordering issues before adding new failures. | **Runtime — authorization required** | — |
| 11 | **Decide Phase 2 vs Phase 3 resumption** and record the decision in the roadmap. | Design | Roadmap amended |
| 12 | **Only after steps 1–10:** PostgreSQL reconciliation, transfer and rollback documentation per roadmap §5 Phase 3 tasks 4–9. | **Runtime — authorization required** | Backup + restore drill demonstrated |

Steps 1–6 are static and can proceed without touching production. Steps 7–12 require
explicit authorization at each point.

---

## 9. Next-session handoff

**Safe starting point.** `E:\MediaServer`, branch `feat/rust-react-postgres-migration`,
HEAD `99e63ed`. Step 1 of §8 — freeze/split the working tree.

**What was last completed.** Phase 3.8G8U — Stage D added two refusal-propagation
tests to `tests/test_cache_safety_boundaries.py` (now 48,219 bytes, 19 test
definitions). `tests/_cache_test_support.py` is 7,665 bytes. Both validated with
`compile()`, `ast.parse()` and `git diff --check` only.

**What must not be repeated.**

- Do **not** re-run the disposable gate. Its one authorized `verify` run (Phase
  3.8G8P) succeeded; the gate lives outside the repository under the system temp
  directory and is not tracked.
- Do **not** re-derive the cache-root boundary or the guard design — both are written
  and source-referenced here.
- Do **not** "fix" the C-B7 sentinel. It exists to document issue 1 and must stay a
  sentinel until a real completeness signal exists.
- Do **not** weaken or delete any existing assertion to make a test pass.
- Do **not** clean the reported `D:\Flicks` Mayday artifacts or the root `=` file.

**Still awaiting authorization.** Stage E tests; Stage G retention-test correction;
any pytest execution; the full-suite run; any PostgreSQL connection; any application
startup.

**Safe read-only commands to resume with:**

```powershell
git rev-parse --abbrev-ref HEAD; git rev-parse HEAD
git status --short
git diff --stat
git diff --check
git ls-files --others --exclude-standard
```

**Explicitly unsafe without authorization:** anything invoking `purge_orphaned_caches`,
`audit_orphaned_caches`, `cleanup_cache`, `purge_media`, `video_paths`, `init_db`, the
worker loops, the Flask app, pytest, or any connection to PostgreSQL.

---

## 10. Evidence and confidence legend

| Label | Meaning |
|---|---|
| **read-only verified** | Established by inspection during this documentation task. Cites a file:line. |
| **runtime-tested** | Actually executed, with the execution recorded against a phase. |
| **statically validated** | `compile()`, `ast.parse()`, `ast.walk` or `git diff --check` only — **code shape, never behaviour**. |
| **reported** | Supplied project history or a prior phase's stated result. Not re-verified here. |
| **not verified** | No evidence of any class exists. |
| **blocked** | Cannot proceed without a decision or an authorization. |

### Claims by class

**read-only verified (this task):** branch/HEAD/status (§4); absence of `web/`, `rust/`,
`Cargo.toml`, `package.json` and any tracked `.sql` file (§3); PostgreSQL surface
locations in `app/db.py`; all ten issue locations in §6; the dedicated-root correction
being uncommitted (§4.1); document inventory and the conflicts in §2.3.

**runtime-tested:** exactly one thing in this branch's recent history — the Phase
3.8G8P `verify` run (exit 0, `VERIFY OK`). Everything else marked runtime-tested in
§5 is **reported**.

**statically validated:** all of `tests/test_cache_safety_boundaries.py` and
`tests/_cache_test_support.py`; every Stage 3.8G gate-edit phase.

**reported:** the 72/23/26/45/98 test counts, the 38-failure baseline, the 53-directory
cache deletion, and all PostgreSQL integration results.

**not verified:** every runtime behaviour of the Phase 3.3–3.8G application changes;
the C-B7 sentinel's predictions; the A5 symlink case, which will likely skip on this
host; whether the `_isolation_paths` union still covers every `.env` key `app/config.py`
reads beyond line 127.

**blocked:** Phase 3 exit gate (no backup/restore/rollback evidence); Phase 7 cutover;
any completion claim (issue 10).

---

*No tests were executed, no application code was started, no database or PostgreSQL
connection was made, no cache or media operation was performed, and nothing was staged
or committed in producing this document.*