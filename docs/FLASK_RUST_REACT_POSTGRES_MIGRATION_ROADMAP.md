# Flask → Rust / React / PostgreSQL Migration Roadmap

**Status:** Proposed — read-only audit required before implementation  
**Owner:** Media Server project  
**Repository default branch:** `main`  
**Last updated:** 2026-10-10

> This document describes the intended migration strategy, not completed work. All implementation details must be verified against the repository during Phase 0. Do not begin a big-bang rewrite.

## 1. Executive direction

Evolve the existing Media Server incrementally into a multi-client platform:

- **Web frontend:** React + TypeScript, built with Vite; Tailwind CSS and shadcn/ui are the proposed styling/component layer.
- **Backend:** Rust using Axum and Tokio, with SQLx for PostgreSQL access.
- **Database:** PostgreSQL as the canonical application data store after a separately planned and verified migration.
- **Media processing:** Keep FFmpeg as the processing engine. Migrate Python/Flask transcoding orchestration to a Rust worker only after queue ownership, hardware behavior, and recovery requirements are understood.
- **Clients:** Preserve the existing Flutter/Fire TV application and maintain API compatibility wherever practical.
- **Operations:** Retain the existing deployment topology and external URLs initially. Add infrastructure only when a demonstrated requirement justifies it.

The goal is not simply to translate Flask code into Rust. The goal is to establish a well-defined backend consumed by multiple clients while preserving the working media, streaming, scanning, and transcoding behavior.

## 2. Non-negotiable migration rules

1. **Audit before implementation.** Inspect the actual repository and deliver an evidence-based plan before application changes.
2. **Preserve behavior before replacing implementation.** Playback, scanning, dual-GPU transcoding, queues, authentication, external URLs, and existing client flows are compatibility requirements.
3. **Keep Flutter working.** Do not assume the native client can be changed whenever the backend changes.
4. **Separate risky changes.** Do not combine database migration, API behavior changes, and transcoder replacement in one cutover.
5. **One source of truth.** Avoid independent Flask and Rust writes to the same workflow or competing schedulers processing the same jobs. Define ownership and handoff explicitly.
6. **Keep `main` releasable.** Use small feature branches, reviewed PRs, CI gates, and tested rollback/recovery paths.
7. **No destructive cutover without evidence.** Backups, reconciliation, representative playback tests, worker recovery tests, and rollback plans must exist before production switching.
8. **Keep FFmpeg.** Initially preserve command generation, codecs, presets, GPU-specific behavior, chunking strategy, and output checks.
9. **Avoid premature infrastructure.** Do not add Kubernetes, a broker, Redis, or separate services unless the audit demonstrates a concrete need.
10. **Do not claim completion based on compilation alone.** Every phase needs acceptance evidence.

## 3. Target architecture (logical view)

```text
                  ┌─────────────────────┐
                  │  React + TypeScript │
                  │  Web application    │
                  └──────────┬──────────┘
                             │ REST / SSE (or existing WS contract)
                  ┌──────────▼──────────┐
                  │    Rust backend     │
                  │ Axum / Tokio / SQLx │
                  ├─────────────────────┤
                  │ Auth / Media / API  │
                  │ Playback / Streaming│
                  │ Jobs / Integrations │
                  └───────┬───────┬─────┘
                          │       │
              ┌───────────▼─┐   ┌─▼────────────────┐
              │ PostgreSQL  │   │ Rust worker      │
              │ canonical   │   │ queue + FFmpeg   │
              │ app data    │   │ GPU orchestration│
              └─────────────┘   └───────┬──────────┘
                                        │
                                ┌───────▼──────────┐
                                │ Media files and  │
                                │ transcode outputs│
                                └──────────────────┘

                     ┌─────────────────────┐
                     │ Existing Flutter /  │
                     │ Fire TV clients     │
                     └─────────┬───────────┘
                               └── Rust API
```

This is a logical architecture, not a requirement that every box run on a separate server. Initially the API and worker may run as separate processes on the same host. The final process topology is to be decided during the audit.

## 4. Proposed technology choices

| Concern | Initial proposal | Qualification |
|---|---|---|
| Web UI | React + TypeScript | Migrate incrementally; preserve core workflows |
| Frontend build | Vite | Confirm repository tooling and deployment fit |
| Styling/components | Tailwind CSS + shadcn/ui | Adopt only if consistent with design/a11y needs |
| API state/cache | TanStack Query | Keep API calls in a central typed client |
| Web routing | React Router | Preserve externally used URLs where practical |
| Rust HTTP | Axum + Tokio | Modular application before splitting into many crates |
| Database | PostgreSQL | Actual current engine/schema must be audited first |
| SQL access | SQLx | Versioned migrations and query checking where practical |
| API contract | Versioned REST + OpenAPI | Existing endpoints and compatibility shape are authoritative inputs |
| Live progress | SSE initially | Keep existing WebSocket behavior if required by verified consumers |
| Media processing | FFmpeg | Do not rewrite codecs/processing engine in Rust |
| Job state | PostgreSQL-backed state initially | Add external queue infrastructure only if justified |
| Testing | Unit, contract, integration, end-to-end | Real hardware tests for GPU-specific guarantees |
| Deployment | Preserve current topology initially | Change only when migration requirements demand it |

These are starting decisions. Phase 0 must identify any existing implementation that should be retained or any constraint that requires a different choice.

## 5. Phases and dependencies

Effort ranges below are rough planning estimates, not delivery commitments. They must be refined once repository size, test coverage, coupling, and outstanding work are understood.

### Phase 0 — Read-only architecture audit

**Estimate:** 1–2 weeks  
**Code changes:** none

Inspect repository documentation, Git state, current routes, service modules, templates, JavaScript, workers, database models, deployment, storage, external integrations, and Flutter API usage. Identify any partial React, Rust, or PostgreSQL work before proposing new structure.

Required deliverables:

- Current-state architecture and process/deployment diagram.
- Flask route and API inventory with methods, auth, schemas, status/error behavior, streaming semantics, and client dependencies.
- Current frontend page/component inventory and page-to-React mapping.
- Database engine/schema/migration/index/constraint inventory and persistence assumptions.
- Flutter compatibility matrix and playback expectations.
- End-to-end transcoding flow: request, queue, GPU assignment, FFmpeg, progress, cancellation, retries, output validation, persistence, and playback.
- Test inventory and gaps, including hardware-dependent tests.
- Security/operations audit: authz, sessions, secrets, file access, path handling, deployment, backup/restore, health checks, process lifecycle, logs.
- Ranked risk register, unknowns, dependency graph, rollback outline, and refined effort ranges.
- Recommended first implementation task.

**Exit gate:** significant findings cite exact repository paths and symbols; verified facts are separated from assumptions; no material subsystem is unmapped.

### Phase 1 — API contracts, regression tests, and Git discipline

**Estimate:** 1–2 weeks  
**Depends on:** Phase 0

Document existing contracts, preferably in OpenAPI where appropriate. Capture authentication and authorization requirements, request/response payloads, errors, IDs, pagination, ranges, and progress/event formats. Create reusable contract tests before replacing implementations.

Important compatibility cases:

- Auth/session behavior and permission checks.
- Media IDs and URL/path encoding.
- HTTP `Range`, `206 Partial Content`, `Content-Range`, and `Accept-Ranges` when applicable.
- Seeking, resume, playback progress, and end-of-play updates.
- Transcode queue state, completion, failure, cancellation, and progress.
- SSE/WebSocket event payloads.
- Existing web routes and externally used stream URLs.
- Flutter flows and API expectations.

Branch discipline:

- Use focused branches such as `feat/react-foundation`, `feat/postgres-migrations`, `feat/rust-api-foundation`, and `feat/rust-transcode-worker`.
- Start branches from a current agreed base; keep branches short-lived.
- Require pull requests and relevant CI checks.
- Avoid a large feature branch that mixes unrelated architecture layers.
- Keep `main` deployable and document how to revert each release.

**Exit gate:** repeatable tests exist for critical contracts and a reviewed branch/PR workflow is being followed.

### Phase 2 — React web frontend

**Estimate:** 2–4 weeks  
**Depends on:** Phase 0; Phase 1 should be underway

Build the web UI against the existing API before performing the full backend migration. Do not remove existing pages until the React counterparts are verified.

Proposed feature areas:

```text
web/src/
  app/
  components/
  features/
    auth/
    library/
    media-details/
    playback/
    search/
    collections/
    history/
    admin/
    transcoding/
    settings/
  hooks/
  lib/
    api/
    auth/
    player/
  routes/
  types/
```

This is a suggestion, not a mandate to impose a directory layout without inspection.

Implementation sequence:

1. App shell, shared design tokens, routing, centralized typed API client.
2. Authentication, loading/error/empty states, and permission-aware navigation.
3. Home screen and media library grid.
4. Search, sorting/filtering, genres, collections, and details pages.
5. Browser player and persisted playback progress.
6. Subtitle/audio selection and existing seek/resume behaviors.
7. Administration pages for scans, queue visibility, server status, and settings.
8. Responsive behavior, accessibility, and performance.
9. Browser and end-to-end regression tests.

Target a polished, cinematic and responsive UI; do not treat template-to-component translation as the full design task.

**Exit gate:** users can complete the current core web workflows against the existing backend, and the React app has automated coverage for its critical routes.

### Phase 3 — PostgreSQL migration

**Estimate:** 1–3 weeks  
**Depends on:** Phase 0 and an agreed data ownership/cutover strategy

First verify the current database engine. If it is SQLite, identify implicit SQLite behavior before designing the PostgreSQL schema.

Tasks:

1. Inventory models, tables, indexes, constraints, relationships, JSON fields, IDs, and transaction boundaries.
2. Identify SQLite-specific behavior, type coercion, autoincrement assumptions, lock/concurrency patterns, and conflict handling if applicable.
3. Create explicit PostgreSQL schema and versioned migrations.
4. Back up the source database and demonstrate restoration.
5. Build an idempotent migration/transfer utility.
6. Reconcile row counts, keys, foreign keys, timestamps, nulls, and representative records.
7. Test concurrent playback state and background-job updates.
8. Check query plans and performance for the important library/playback queries.
9. Document the point of no return, rollback window, and recovery steps.

PostgreSQL should become the canonical application data store. If Flask and Rust must coexist during transition, assign write ownership explicitly and prevent split-brain state. Avoid long-running dual writes unless an audited design includes reconciliation and failure recovery.

**Exit gate:** data transfer and recovery are demonstrated; the application passes representative regression tests against PostgreSQL; write ownership is unambiguous.

### Phase 4 — Rust API foundation

**Estimate:** 2–4 weeks  
**Depends on:** API contracts (Phase 1) and the database cutover plan (Phase 3)

Start with a modular Rust application. Split into additional crates only where clear boundaries justify it.

Candidate modules:

- Configuration, secret loading, and startup validation.
- Structured logs, request/correlation IDs, and consistent error mapping.
- Health and readiness checks.
- PostgreSQL connection/pool management.
- Authentication, sessions, and authorization.
- Versioned route structure and API contracts.
- Integration and contract test harness.

Migrate a small set of low-risk routes first, such as health/status and read-only library queries. Route selected paths to Rust while Flask continues to own unmigrated responsibilities. Do not change all clients and backend behavior at once.

**Exit gate:** Rust serves selected production-like requests, with contract tests matching the documented behavior and no new authentication/data-integrity gaps.

### Phase 5 — Media library, playback, and streaming

**Estimate:** 3–6 weeks  
**Depends on:** Phases 1, 3, and 4

Move responsibilities in controlled slices:

1. Library and metadata queries.
2. Search, filtering, pagination, and media details.
3. Watch history and playback progress.
4. Authorized media-file lookup and safe path resolution.
5. Direct file streaming and byte-range support.
6. Seeking, subtitle delivery, and track behavior.
7. HLS or other existing streaming modes as actually used.
8. Live status/progress delivery.
9. Web and Flutter end-to-end tests.

Streaming tests must validate headers and byte behavior, not merely whether the first video frame appears. Cover authorization, partial responses, seek near the beginning and end, resume after refresh, and handling of invalid or unsatisfiable ranges where supported.

Preserve externally used routes and avoid exposing arbitrary filesystem paths. Keep cache and media path rules aligned with current behavior unless a separate change is explicitly planned.

**Exit gate:** representative playback sessions pass the contract and end-to-end suite from both web and Flutter clients.

### Phase 6 — Rust transcoding worker/orchestration

**Estimate:** 3–6 weeks  
**Depends on:** Phases 0, 1, 3, and a stable Rust foundation

The worker should eventually own the job lifecycle and scheduling. The exact state model must be derived from current implementation and documented before migration.

Illustrative lifecycle:

```text
Requested → Queued → Scheduled → Running
                                  ├─ Progress
                                  ├─ Cancel
                                  └─ Failure/retry
                                      ↓
                               Output validation
                                      ↓
                                  Completed
```

Responsibilities to migrate:

- Queue admission and scheduling.
- GPU assignment and concurrency limits.
- FFmpeg process spawn/monitor/shutdown.
- Progress parsing and reporting.
- Cancellation, timeout, and cleanup.
- Failure classification and bounded retries.
- Chunk dependencies and assembly, if applicable.
- Output duration/integrity validation.
- Atomic publication of completed outputs.
- Persistent job state and API/event updates.
- Recovery for jobs abandoned by worker/server restart.

Initially retain FFmpeg command generation, encoders, presets, GPU mappings, chunking strategy, and output checks. Do not change processing behavior simply as a side effect of changing orchestration languages.

Reliability considerations should include durable job records, worker leases or ownership, heartbeats, bounded retries, idempotent completion, restart recovery, and protection from duplicate execution. Introduce an external broker only if measured workload and failure requirements justify it.

Critical tests:

- Both existing GPUs are scheduled correctly under concurrent load.
- Worker restart does not silently lose queued jobs.
- Cancellation targets the correct process and cleans partial output.
- Failed/stale jobs do not remain permanently running.
- Progress and queue reporting remain accurate.
- Incomplete/corrupt outputs are not marked complete.
- Existing chunk ordering/assembly and playback integration remain correct.
- Only one authoritative scheduler can claim a job.

**Exit gate:** the Rust worker passes representative hardware integration tests and failure/restart tests, and no competing scheduler owns the same queue.

### Phase 7 — Cutover, hardening, and Flask retirement

**Estimate:** 2–4 weeks  
**Depends on:** all needed routes and jobs migrated with passing gates

1. Deploy new services without immediately switching all traffic.
2. Verify readiness, logs, authentication, file access, database connectivity, and worker health.
3. Route selected endpoints to Rust.
4. Run contract, browser, Flutter, streaming, and job tests.
5. Expand traffic in controlled steps.
6. Track request errors/latency, playback failures, job duration, GPU utilization, stale jobs, memory, and logs.
7. Keep rollback available to a known-good deployment and compatible data state.
8. Remove Flask responsibilities one at a time.
9. Search for any remaining runtime imports, route dependencies, templates, scripts, and operational processes.
10. Remove unused Flask packages/configuration only after confirming no production path depends on them.
11. Retire Flask after a final acceptance review.

Do not remove migration compatibility or old runtime support while rollback still depends on it. Plan schema expansion/contract steps so the rollback window remains viable.

**Exit gate:** all production responsibilities have explicit owners in the new architecture, no production workflow depends on Flask, recovery procedures are tested, and all release criteria are met.

## 6. Testing and release gates

| Test layer | Required coverage |
|---|---|
| Unit tests | Domain rules, state transitions, parsers, path and permission logic |
| Contract tests | Request/response/error/status compatibility across Flask and Rust |
| Database integration | Migrations, transactions, concurrency, reconciliation |
| Streaming integration | Range requests, headers, seeking, authz, subtitles |
| Worker integration | Scheduling, retries, cancellation, worker restart, output validation |
| Hardware tests | Real dual-GPU and FFmpeg behavior on the supported production host |
| Flutter regression | Authentication, library, player, tracks, resume, TV navigation where applicable |
| React/browser | Navigation, search, details, playback, admin, responsive behavior |
| End-to-end | Scan → metadata/library → playback → progress/history → transcode workflow |
| Operations | Backup/restore, restarts, deployment config, health checks, rollback |

Use mocks for fast general CI where appropriate, but do not treat mocks as proof of hardware acceleration. Run GPU and production-host checks in a suitable controlled environment.

Every PR should have a focused scope, relevant automated checks, updated docs where needed, and a manual test note for areas that cannot be automated. Do not merge with unresolved critical security, data-integrity, or playback regressions.

## 7. Security and operations controls

The audit should verify, and implementation should preserve or improve:

- Authentication and authorization, including administrative routes.
- Session/token handling and secure secret loading.
- Safe media path resolution and path traversal protection.
- Authorization before streaming or generating playable URLs.
- Safe FFmpeg process arguments (avoid shell injection and unsafe interpolated commands).
- Bounded upload/scan/job resource consumption.
- Secure handling of error messages and logs.
- Service restart, shutdown, process cleanup, and stale job recovery.
- Backup and database restore procedures.
- Health/readiness probes and useful structured telemetry.
- Cloudflare tunnel/reverse-proxy routing and existing externally used URLs.

Do not publish secret values in audit output, logs, or documentation.

## 8. Risk register (initial, to be refined after audit)

| Risk | Initial severity | Mitigation |
|---|---|---|
| Lost or incompatible undocumented API behavior | High | Route inventory, contract tests, staged route replacement |
| Flutter regression | High | Client contract matrix and regression tests for every migrated API |
| Streaming seek/range regression | High | Explicit range/headers/auth tests and real browser playback |
| Queue split-brain or duplicate FFmpeg work | Critical | Single scheduler ownership, job claims/leases, recovery tests |
| Dual-GPU allocation regression | High | Preserve mappings and test on real target hardware |
| Data loss during DB conversion | Critical | Backups, restore drills, idempotent transfer, record reconciliation |
| Flask/Rust split-brain writes | High | Define canonical writer per domain and a tested cutover sequence |
| Auth/security mismatch | Critical | Explicit authz matrix, security review, negative tests |
| Deployment/tunnel outage | High | Preserve routing initially, health checks, documented rollback |
| Rewrite scope grows too broad | High | Small feature branches, phase exit gates, defer unrelated refactors |
| Incomplete CI coverage for hardware | Medium/High | Separate mocked CI from hardware acceptance tests |

## 9. Production cutover and rollback strategy

Before each risky cutover, record:

- The current known-good build and how to redeploy it.
- Backup location, timestamp, and a successful restore result.
- Database schema compatibility and whether writes can safely roll back.
- The exact routes/jobs being switched.
- Health, error, playback, job, and hardware signals to watch.
- Conditions that trigger rollback.
- Who/what owns jobs and writes during transition.
- How partial FFmpeg output and stale jobs are handled.
- How to return traffic to the previous implementation without leaving inconsistent state.

Favor expand/contract database changes and staged route migration. Do not claim zero downtime until the deployment and data model actually support it.

## 10. Effort estimate and uncertainty

Initial sequential ranges:

| Phase | Estimate |
|---|---:|
| Phase 0: audit | 1–2 weeks |
| Phase 1: contracts/tests/Git | 1–2 weeks |
| Phase 2: React | 2–4 weeks |
| Phase 3: PostgreSQL | 1–3 weeks |
| Phase 4: Rust foundation | 2–4 weeks |
| Phase 5: media/playback/streaming | 3–6 weeks |
| Phase 6: transcoding worker | 3–6 weeks |
| Phase 7: cutover/retirement | 2–4 weeks |

These add to approximately 15–31 weeks if treated sequentially. Some work can overlap after dependencies are established. This is a provisional planning range, not a promise; solo part-time development, hidden coupling, inadequate tests, data complexity, and hardware-specific issues may extend it. Phase 0 must refine estimates.

## 11. Phase 0 audit prompt

The first coding-agent task must be read-only. Use a plan/audit mode and require the agent to:

1. Inspect current Git branch, working tree, recent commits, docs, and migration-related work.
2. Read project status and Flutter handoff docs before touching Flutter-related contracts.
3. Inventory Flask routes, services, templates/JavaScript, DB schema, workers, streaming, deployment, and external integrations.
4. Document every Flutter API/player expectation relevant to the migration.
5. Trace the complete transcode path, including dual-GPU scheduling, queue reporting, chunking, cancellation, restart, validation, and output delivery.
6. Inspect existing tests and distinguish hardware test needs from mockable CI checks.
7. Produce current/target architecture diagrams, route inventory, frontend migration map, DB plan, compatibility matrix, risk register, dependency sequence, effort ranges, and exact acceptance criteria for the first implementation task.
8. Cite repository paths/symbols for important findings; mark unknowns and assumptions clearly.

**Stop condition:** return the audit and plan only. Do not modify application files, create migrations, install dependencies, change deployment configuration, commit, push, create branches, open PRs, or start implementation without explicit approval.

## 12. Definition of done

- React replaces the Flask-rendered web UI and supports the required workflows.
- Rust owns all migrated backend/API and business logic responsibilities.
- PostgreSQL is the canonical application database.
- Streaming, seeking, subtitles, playback state, and existing client contracts pass tests.
- Rust worker owns transcoding jobs and FFmpeg process orchestration.
- Dual-GPU behavior, queue correctness, cancellation, recovery, and output validation pass hardware/integration acceptance tests.
- Flutter/Fire TV continues to work against the supported API.
- External routes and operational behaviors remain compatible or have an explicitly approved migration.
- Backups/restoration, deployment, monitoring, and rollback have been tested and documented.
- No production dependency on Flask remains, and unused runtime code/configuration is removed safely.

**Current status: Proposed roadmap only. Phase 0 is the next action; implementation has not been authorized by this document.**
