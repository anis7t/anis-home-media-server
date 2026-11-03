# Container, Kubernetes, Cloud, and Microservices Roadmap

**Status:** Roadmap drafted 2026-11-04; Phase 0 local pilot is implemented and partially verified, with its clean-checkout build and automated regression coverage still open. No cloud infrastructure has been provisioned.
**Scope:** Move from the current Windows-hosted Rust + React + PostgreSQL application toward a reproducible container platform, Kubernetes deployment, cloud media delivery, and gradual service decomposition.
**Provider:** Provider-neutral. Select a cloud provider, region, and budget at the decision gate in Phase 2.

This document is a target-state roadmap, not authorization to provision cloud resources or move production data. Every phase has a gate. Production cutover happens only after the data, network, cost, security, and rollback decisions for that phase are approved.

## 1. Goals

- Build and operate the same application artifact in local development, CI, staging, and production.
- Deploy the web/API application and independent background workers to Kubernetes.
- Keep PostgreSQL and media data durable, recoverable, and separate from container lifecycles.
- Preserve the existing React web client and Flutter / Fire TV API contract while implementations move behind services.
- Scale API, ingestion, and transcode workloads according to their different resource needs.
- Support a cloud deployment for remote playback while deciding deliberately how home-LAN playback, DLNA discovery, and casting continue to work.
- Create a service architecture that can be operated and funded by this project, rather than decomposing every route into a separate service.

## 2. Current state and starting constraints

### In place

- The production application is a Rust Axum server on Windows, serving the React SPA and all application routes.
- PostgreSQL 18.4 is the system of record.
- The current workstation uses separate volumes for the media library, application state, cache, and database data.
- The repository has four CI pillars for Rust, React, Flutter, and secret scanning.
- A Linux multi-stage Dockerfile, local Compose stack, and a Helm pilot have been added. They use an isolated local database/media location and CPU transcoding by default. The local Compose and Docker Desktop Kind pilots have been started and exercised; see [Container Deployment Pilot](CONTAINER_DEPLOYMENT.md) for dated evidence and open gaps.
- The Helm pilot is internal-only, has no public Ingress or TLS, and deploys one API replica.

### Not yet verified

- The image has been built from the current working tree, but a clean-checkout, cache-independent build has not been verified.
- Core Compose and Helm pilot paths have been exercised, but repeatable automated Phase 0 regression coverage is not yet complete.
- No cloud account, registry, cluster, domain, object store, or managed database has been selected for this migration.

### Architecture blockers to resolve before scaling

1. The API process starts the scanner, transcode worker, cache sweeper, and storage maintenance loops. Running multiple API replicas would start duplicate schedulers and workers.
2. Database schema work runs during application startup in Rust. Some startup DDL removes retired schema objects. This must become a versioned, single-run migration process before multi-replica rollout or service ownership changes.
3. The current production transcoder uses Windows D3D11 / AMD AMF. The current Linux container uses FFmpeg software encoders. A cloud GPU strategy must be chosen and proven independently.
4. Media paths, local HLS cache, uploads, archives, and previews currently assume mounted filesystems. Containers and cloud nodes must not treat their local filesystem as durable media storage.
5. Clients depend on established /api response shapes. Route ownership can move internally, but public contract changes require a separate, versioned client migration.
6. DLNA discovery and some casting behavior depend on access to the home LAN and multicast. A cloud-only pod cannot discover devices on a private home network by itself.

## 3. Target architecture

The eventual system should separate the public client interface, request-serving workloads, asynchronous work, and durable data. The diagram is logical; it does not require every box to become an independently deployed service.

~~~mermaid
flowchart LR
    Clients[Web and Flutter clients] --> Edge[DNS, TLS, CDN or cloud edge]
    Edge --> API[Axum API facade]
    API --> Identity[Identity and device capability]
    API --> Catalog[Catalog and discovery]
    API --> Media[Media and subtitle delivery]
    API --> Upload[Upload and ingestion API]
    API --> Jobs[Transcode job API]
    Upload --> Queue[Durable job queue]
    Catalog --> Queue
    Jobs --> Queue
    Queue --> Scan[Scanner workers]
    Queue --> Transcode[CPU or GPU transcode workers]
    Queue --> Maintenance[Maintenance workers]
    API --> DB[(PostgreSQL)]
    Identity --> IdentityDB[(Identity data)]
    Catalog --> CatalogDB[(Catalog data)]
    Media --> Objects[(Object storage)]
    Upload --> Objects
    Transcode --> Objects
    API --> Telemetry[Logs, metrics, traces]
    Identity --> Telemetry
    Catalog --> Telemetry
    Media --> Telemetry
    Transcode --> Telemetry
    Edge --> Telemetry
~~~

### Design principles

- **Keep a public compatibility layer.** Preserve current API routes and response shapes at the edge while internal ownership changes. The edge remains a first-party Rust application surface; it does not revive the retired Flask/Waitress bridge.
- **Separate workloads before splitting every domain.** First run the API and background workers as different deployments. This removes the current replica constraint and gives a clear scaling boundary without immediately multiplying API services.
- **Use modular Rust domains as the extraction seam.** Keep domain interfaces explicit inside the repository first; split a domain into its own process only when independent scale, release cadence, ownership, failure isolation, or security justifies the additional operations.
- **Assign one owner to each piece of data.** Shared PostgreSQL can be a temporary migration state, but new services should not make uncontrolled cross-service writes. Establish ownership before separating schemas or databases.
- **Use asynchronous messaging for long work.** Scans, transcodes, metadata refreshes, and maintenance should be durable jobs. Consumers must tolerate retries and duplicate delivery.
- **Treat media as object data.** Use a durable media/object store for originals and completed outputs. Keep node-local storage for disposable scratch and cache only.
- **Keep CPU and GPU workloads distinct.** The API must not require a GPU. GPU jobs should land on an explicitly selected compatible worker pool.
- **Make recovery a deployment feature.** Database and object-store backups, migration rollback, image rollback, and restoration drills are part of release readiness.

## 4. Phases

### Phase 0 — Verify and harden the local pilot

**Goal:** Establish a known-good Linux container baseline before adding cloud variables.

**Work**

- Build the Docker image and resolve Linux compiler, FFmpeg, runtime library, signal handling, file permission, and React static-file issues.
- Render and lint the Helm chart; verify the Compose configuration.
- Start Compose with an empty isolated database and a disposable media directory.
- Exercise the core path: liveness/readiness behavior, sign-in configuration and positive/negative auth flows, catalog scan, byte-range direct play, CPU HLS transcode, subtitles, seek previews, authenticated upload and archive behavior, and persistence across restart.
- Confirm the default Compose bind mount cannot silently point at the production library.
- Record image size, startup time, database initialization behavior, and CPU transcode throughput on the development host.
- Make the container entrypoint, process user, writable paths, shutdown grace period, and FFmpeg child cleanup consistent across Docker and Kubernetes.
- Add repeatable regression checks for the container contract and pilot paths, and run them from a clean source checkout; preserve the existing Rust, React, Flutter/API-contract, and secret-scanning CI checks.

**Exit criteria**

- A cache-independent image build succeeds from a clean checkout, the image contains no secrets or production paths, and the container starts without Windows-only path assumptions.
- Automated regression checks verify Compose configuration, isolated default media/database/cache storage, health behavior, least-privilege runtime identity and writable mounts, and PostgreSQL persistence after recreation.
- Automated end-to-end checks cover media scan, byte-range direct play, CPU HLS transcode and its outputs, sidecar subtitle listing/streaming, seek-preview metadata/thumbnail, and authenticated upload/archive behavior. Tests use disposable fixtures and never production media or data.
- Shutdown tests signal the API with an FFmpeg child active, assert the child exits within the configured grace period, and cover restart/reconciliation behavior for interrupted jobs without claiming resumability unless it is proven.
- Helm lint and rendering checks pass; local-cluster checks verify API-only Service selection, pod readiness, persistent PVC binding, health, API pod restart persistence, and graceful termination behavior.
- Negative/security regressions verify no secrets enter image layers/logs, no API Service selects PostgreSQL, no production paths are mounted by defaults, and unauthorized upload/admin actions remain denied.
- Every check has a documented command, fixture/setup, expected result, cleanup path, and captured result; known platform limitations and unverified behavior are recorded in the pilot documentation.

**Gate:** Do not mark Phase 0 complete or proceed to production Kubernetes until every exit criterion passes. If a credential-dependent check cannot be run with real credentials, provide a safe test configuration or an automated test seam and prove both allowed and denied behavior without logging or persisting the credential.

### Phase 1 — Define the deployment contract and image supply chain

**Goal:** Make container images immutable, traceable, and safe to deploy.

**Work**

- Define the runtime contract: required environment variables, secret names, filesystem mounts, ports, health endpoints, resource needs, shutdown behavior, and supported CPU architectures.
- Separate build-time values from runtime configuration. Never copy .env files, signing keys, OAuth secrets, or Cloudflare tokens into an image.
- Extend CI to build the server image from the same Rust and React sources already checked by the existing jobs.
- Publish versioned images to a selected OCI registry after an approved release or tag. Deploy by immutable digest in staging and production; avoid mutable latest tags for releases.
- Add image provenance, software bill of materials, vulnerability checks, and signing policy after selecting compatible registry/tooling.
- Decide whether to build linux/amd64 only initially or add linux/arm64 when a target node pool or client environment requires it. Multi-platform builds require validating every native dependency and FFmpeg package on each architecture.
- Version the Helm chart separately from the application image. Keep development, staging, and production values separate, with secret values injected at deploy time.
- Define image retention, release promotion, rollback, and registry credentials.

**Exit criteria**

- A tagged source revision creates a traceable image and chart version.
- CI rejects an image release when required Rust, React, Flutter contract, or secret checks fail.
- A staging release can be rolled back to a prior immutable image digest.
- No credentials or production data enter image layers or build logs.

### Phase 2 — Decide the cloud target and landing architecture

**Goal:** Select the deployment environment before provisioning billable infrastructure.

**Decisions to document**

- Cloud provider, region, availability-zone strategy, account/subscription/project structure, naming, tags, and budget cap.
- Managed Kubernetes versus a simpler managed container platform for the first cloud release. Kubernetes is the requested target, but a pilot should still compare the ongoing control-plane and operations cost.
- Public hostname, DNS ownership, TLS termination, WAF/rate-limiting needs, and the cloud edge/API entry point.
- Container registry, image retention, CI identity, workload identity, and secret-management system.
- Managed PostgreSQL versus self-managed PostgreSQL. Evaluate supported PostgreSQL major versions, extensions, connection limits, backup/restore controls, and cross-region recovery before choosing.
- Durable original-media and derived-media storage, cache policy, lifecycle retention, replication, and CDN behavior.
- Expected library size, concurrent streams, upload volume, remote egress, transcode concurrency, and acceptable monthly cost.
- Whether production becomes cloud-only or hybrid with a home server / home-network connector.
- Data residency, account retention, recovery objectives, and who can administer cloud resources.

**Default decision posture**

- Use provider-neutral Helm values and Kubernetes resources until the provider is selected.
- Evaluate managed PostgreSQL for production; keep the chart's in-cluster PostgreSQL for local pilot use only unless operations evidence supports self-management.
- Use object storage for durable media and outputs; use PVC or node-local storage only for workloads that need filesystem scratch.
- Do not select cloud GPU instances until a representative transcode job proves codec support, driver/runtime compatibility, throughput, thermals or service limits, and per-hour cost.
- Keep home-LAN discovery as a separate edge/hybrid design decision.

**Exit criteria**

- An approved cloud architecture and cost envelope exist.
- Network, identity, database, object store, registry, TLS, and recovery choices are recorded.
- A non-production environment can be provisioned and destroyed using reviewed Infrastructure as Code.

### Phase 3 — Make application lifecycle and schema changes safe

**Goal:** Remove startup and path assumptions that prevent replicas and independent services.

**Work**

- Replace runtime DDL in server startup with versioned, ordered migrations executed by one deployment job or migration process.
- Make migrations backward-compatible for rolling application releases: expand schema, deploy compatible code, backfill, then contract only after old code is gone.
- Move secrets and environment loading to an explicit configuration layer. Keep Windows host defaults behind platform-specific configuration; container paths must be explicit.
- Make API health semantics distinct: process liveness, startup readiness, and dependency readiness. A transient database outage should not cause an uncontrolled pod-restart loop.
- Confirm graceful shutdown covers HTTP requests, active uploads, running FFmpeg children, and job-lease release or expiry.
- Replace host-specific disk/CPU assumptions with container- and cgroup-aware telemetry, without changing the Android/TV API response contract.
- Externalize APK update artifacts, Caddy configuration, and other files currently discovered through the repository base directory.
- Define resource requests/limits and filesystem permissions for API, worker, and migration jobs.

**Exit criteria**

- Multiple API replicas can start without running duplicate schema changes or deleting objects during startup.
- Migrations can be applied once, observed, and recovered from a failed deployment.
- API pods become ready only when they can serve their required dependencies and stop accepting new requests before termination.
- No service requires a developer workstation path or local repository checkout at runtime.

### Phase 4 — Establish Kubernetes platform operations

**Goal:** Create a secure, observable, recoverable non-production cluster.

**Work**

- Provision the selected cluster and network with Infrastructure as Code. Define private/public subnets, egress, cluster identity, node pools, DNS, and firewall boundaries.
- Package the app with Helm environments: local, staging, production. Split the application chart from any optional local PostgreSQL chart so production can use managed PostgreSQL.
- Add namespace boundaries, least-privilege service accounts/RBAC, resource quotas, network policies, pod security settings, and external secret references.
- Configure ingress or Gateway API, TLS certificates, request/body limits, timeouts for streaming, Server-Sent Events, and resumable uploads.
- Add startup, readiness, and liveness probes; PodDisruptionBudget where multiple replicas are safe; and graceful termination.
- Add cluster and application observability. Correlate structured logs, metrics, and distributed traces across the API, jobs, database, storage, and edge.
- Set alerts for API error/latency, database saturation, queue age/depth, failed transcodes, disk/PVC pressure, object-store failures, and cost budget.
- Add backup schedule, retention, encryption, restore runbook, and restore rehearsal for each durable system.
- Keep autoscaling disabled until the stateless API and workers have separate deployments and useful scaling metrics.

**Exit criteria**

- Staging is reproducible from code and can be torn down and recreated.
- Secrets are not committed into Helm values; cluster access and service identities follow least privilege.
- Operators can trace one client request across services and see job/database/storage failures.
- A tested backup restore meets the agreed recovery objectives.

### Phase 5 — Separate API and background execution

**Goal:** Remove duplicate background work and independently scale request-serving and asynchronous workloads.

**Initial deployments**

- **API deployment:** HTTP routes, authentication middleware, request validation, and a compatibility API surface.
- **Scanner workers:** Library discovery, file probing, and metadata enrichment.
- **Transcode workers:** Chunk planning, FFmpeg execution, progress, and job completion.
- **Maintenance workers:** Cache audit/purge, retention actions, and scheduled cleanup.
- **Scheduler/dispatcher:** Enqueue periodic scans/refreshes and coordinate job creation. Initially can be a single leader or a Kubernetes CronJob where the work is bounded and idempotent.

**Work**

- Preserve the existing PostgreSQL transcode job lease and idempotent enqueue behavior while separating worker processes.
- Define job states, retry/backoff, maximum attempts, dead-letter handling, cancellation, lease expiry, worker identity, and progress telemetry.
- Ensure shutdown stops new jobs and either finishes a chunk safely or releases the lease without losing work.
- Keep the current database queue for the first extraction unless measurements justify a managed queue/broker. If replacing it, add an outbox or equivalent atomic handoff to avoid database/broker divergence.
- Add queue-age and job-duration metrics; scale worker pools from backlog and service limits, not CPU alone.
- Add per-worker resource classes. Limit CPU workers separately from GPU workers; keep 4K or other high-memory/long jobs within explicit concurrency budgets.
- Ensure API deployment no longer starts scan, transcode, or maintenance loops.

**Exit criteria**

- API replicas can scale without starting extra schedulers or consumers.
- A worker can die mid-job and another worker can safely resume or retry it.
- Duplicate delivery cannot publish duplicate catalog records or corrupt HLS output.
- Scanner, transcode, and maintenance pools can be deployed and scaled independently.

### Phase 6 — Move durable media and database operations to cloud

**Goal:** Decouple media durability from node disks and move data under an approved recovery plan.

**Media/object storage**

- Map original media, archived media, subtitles, artwork, completed HLS outputs, seek previews, resumable upload chunks, and temporary chunks to explicit storage classes.
- Use object storage for durable originals and published outputs. Use node-local scratch for temporary chunks only when jobs can recover after node loss.
- Preserve relative media identifiers and authorization checks when the physical location changes.
- Decide whether clients stream through the API, receive signed object URLs, or use a CDN. Preserve byte-range behavior for direct play and HLS manifests/segment behavior for transcoded media.
- Use multipart uploads or a staged upload service for large files; define checksum verification, abort cleanup, lifecycle, and retention.
- Budget CDN and object-store egress; media traffic may dominate compute cost.

**Database**

- Inventory tables and classify ownership: identity/sessions/devices; catalog/metadata; playback progress/history; upload state; transcode jobs; settings/audit.
- Use a consistent PostgreSQL backup and restore process. Decide between offline dump/restore, logical replication, or an application-level migration based on data size and required downtime.
- Verify PostgreSQL 18 compatibility with the selected managed service before provisioning.
- Do not move production data until restore and cutback have been rehearsed against a copy.

**Exit criteria**

- A test media library and database can be copied and restored with row/file counts and checksums reconciled.
- The API can resolve media from cloud storage without relying on local paths.
- Direct play, byte ranges, HLS, subtitles, posters, upload resume, and preview paths work in staging.
- Storage retention, deletion, and orphan cleanup cannot remove the only durable copy.

### Phase 7 — Prove a cloud transcoding strategy

**Goal:** Select a supported encoding backend and predictable cost/performance profile.

**Options to compare**

- CPU-only worker pool for the first cloud release.
- Cloud GPU workers using a supported Linux encoding stack and node/runtime integration.
- Hybrid workers that keep GPU transcoding at home and send jobs/results to cloud storage.
- Pre-transcode selected titles/qualities and serve from object storage/CDN.

**Work**

- Build a codec/device matrix for H.264, HEVC, 10-bit, audio, subtitle extraction, fMP4 HLS, and supported source containers.
- Benchmark representative SD/HD/4K files, cold and warm storage, concurrency, startup, throughput, failure rate, and cost per source-hour.
- Route work using job requirements and worker capability labels. Keep API pods and ordinary workers schedulable without GPU hardware.
- Add concurrency caps, timeouts, cancellation, queue backpressure, node drain behavior, and per-job cost/usage telemetry.
- Retain a fallback path when a GPU worker is unavailable or a source is unsupported.

**Exit criteria**

- The chosen strategy meets playback-start, transcode-throughput, quality, concurrency, and cost targets.
- GPU worker loss does not make the API unavailable or lose the source file.
- The deployment chart can target GPU nodes only for the worker pool that requires them.

### Phase 8 — Extract microservices gradually

**Goal:** Introduce independent service ownership only where it improves scaling, reliability, security, or delivery.

**Candidate boundaries**

1. **Identity and device service:** Google OAuth flow, sessions, admin controls, QR/device pairing, device records, audit ownership.
2. **Catalog and discovery service:** scans, filename parsing, TMDb enrichment, genres, catalog queries, artwork metadata.
3. **Ingestion service:** uploads, resumable chunks, validation, file placement, scan enqueue, subtitle upload.
4. **Media and subtitle delivery service:** authorization-aware byte ranges, HLS playlist/segment delivery, subtitles, preview lookup, object-store/CDN integration.
5. **Transcode control/worker service:** job API, scheduling, worker pools, chunk outputs, progress and cache state.
6. **Playback progress service:** user-scoped progress, history, continue-watching, device relationships.
7. **Local-network connector (optional):** a home-side component for DLNA discovery, Chromecast reachability, and private-LAN casting if the public API moves to cloud.

These are candidates, not a mandate to create seven deployables. Start with worker separation, then extract one request-serving domain at a time where measurements or ownership justify it.

**Migration sequence per domain**

1. Define ownership, public/internal API, data owner, failure behavior, and SLO.
2. Add an internal Rust module boundary in the current application.
3. Add contract tests and telemetry around the boundary.
4. Route a small, non-critical path through the new service behind the compatibility API.
5. Reconcile reads/writes, retry behavior, authorization, and performance.
6. Migrate the full domain and stop old writes.
7. Only then consider separating its schema/database.

**Data and API rules**

- Do not let multiple services write the same tables indefinitely.
- Use explicit service APIs or events for cross-domain work; avoid direct database access between services.
- Prefer event/outbox patterns for catalog, upload, and transcode lifecycle transitions where atomic cross-system delivery matters.
- Keep external /api paths and response schemas stable for Flutter / Fire TV. Add a contract version only when clients can migrate deliberately.
- Keep the edge/API façade thin and observable. Do not place all business logic in a new gateway.

**Exit criteria**

- A service owns a well-defined domain and can be deployed, scaled, and recovered independently.
- Its database writes and events have a single owner; its API contract is documented.
- Cross-service failure, timeout, retry, and duplicate-event behavior are covered.
- The Flutter API probe and web playback flow remain compatible throughout the extraction.

### Phase 9 — Cloud staging and controlled production cutover

**Goal:** Prove production-like operation before changing user traffic.

**Work**

- Deploy the API, workers, database, storage, and edge into staging with production-like network and secret handling.
- Restore a sanitized or protected copy of production data and a representative media sample.
- Validate authentication, QR pairing, user/device scoping, catalog scan, uploads, direct play, HLS quality selection, subtitles, progress, downloads/update assets, and remote streaming.
- Exercise load at expected concurrent streams and transcode queue depth; measure uplink, cloud egress, object requests, database connections, and tail latency.
- Simulate API pod restart, worker interruption, database failover/restore, object-store timeout, queue backlog, and failed image/chart rollback.
- Run Android API contract probes and Flutter/web release checks against staging.
- Define cutover: data sync/freeze window, DNS/edge change, session impact, monitoring watch, rollback trigger, and restore/cutback steps.
- If hybrid operation remains, prove home casting and cloud remote playback independently.

**Exit criteria**

- Staging meets agreed SLO, security, playback, data-reconciliation, and cost targets.
- A production backup restore and application rollback have both been rehearsed.
- Cloud cutover has a timed runbook with named owner and an unambiguous rollback decision.

### Phase 10 — Operate, scale, and reduce cost

**Goal:** Scale only the components that need it and make ongoing operation sustainable.

**Work**

- Scale stateless API replicas with request latency/saturation metrics after background loops are fully separated.
- Scale scanner and transcode pools using queue age/depth, worker capability, and budget limits.
- Apply autoscaling only when startup latency, cold storage, node provisioning time, and GPU capacity are understood.
- Add tenant/user quotas if multi-user growth requires them; control upload size, transcode concurrency, and storage retention.
- Review service count, database utilization, storage growth, egress, idle GPU/CPU capacity, log/trace retention, and backup cost on a regular cadence.
- Add multi-zone or multi-region recovery only if agreed RTO/RPO and user needs warrant the operational and data-replication cost.
- Keep the local Windows deployment supported until the cloud operation is proven and a deliberate retirement decision is made.

**Exit criteria**

- Scaling behavior is demonstrated under representative demand.
- Budgets and alerts catch unexpected compute, GPU, storage, and egress growth.
- Recovery objectives are met in periodic restore/failover drills.
- Every production service has an owner, SLO, runbook, image/chart version, and rollback route.

### Phase sequencing and dependencies

The phase numbers identify major work areas; they do not authorize skipping a
gate or provisioning infrastructure early. Some discovery and local CI work can
run in parallel, but production data and billable resources stay behind the
relevant decisions and recovery checks.

| Work | Must follow | Must be complete before |
|---|---|---|
| Phase 0 local pilot | Existing container/Helm pilot groundwork | Phase 0 exit criteria pass before production Kubernetes work |
| Phase 1 image/runtime contract | Phase 0 findings | Registry-specific publishing and release promotion wait for Phase 2 provider/registry decisions |
| Phase 2 cloud target and cost envelope | Phase 0 evidence | Any cloud provisioning, production data movement, or public endpoint |
| Phase 3 lifecycle and migration safety | Phase 0 portability findings; can be designed alongside Phase 1/2 | Multi-replica API rollout, production schema change, and worker split |
| Phase 4 platform operations | Phase 2 approved target and Phase 1 artifact/secret contract | Staging workloads handling protected data |
| Phase 5 worker separation | Phase 3 migration/lifecycle safety | API autoscaling and independent worker autoscaling |
| Phase 6 durable data move | Phase 2 storage/DB decisions and Phase 4 secure staging | Production cutover or removal of the source copy |
| Phase 7 transcode strategy | Representative media and Phase 2 budget/target | Production GPU capacity commitment or transcode service-level promise |
| Phase 8 domain extraction | Phase 5 worker boundaries and measured need | Each extracted domain's production ownership change |
| Phase 9 staging and cutover rehearsal | Phases 3–7 applicable gates | Production traffic cutover |
| Phase 10 operations and scaling | Phase 9 cutover evidence and agreed SLO/RPO/RTO | Further scaling or service decomposition decisions |

Phase 1 can begin with provider-neutral image hardening and local CI. Phase 2
must settle the provider, registry, architecture, and budget before those local
artifacts are promoted or infrastructure is provisioned. Phase 8 remains
optional per domain; the roadmap does not require every candidate service to
become a separate deployment.

## 5. Cross-phase workstreams

### Client contract and release discipline

- Keep the existing Android API probe in every release gate.
- Add API schema/version checks where a service extraction changes internal routing.
- Keep web and Flutter against the same staging environment before production cutover.
- Separate server release, chart release, Android client release, and database migration sequencing.

### Security and access

- Use workload identity and managed secret injection where supported by the selected cloud.
- Configure encryption in transit and at rest, network policies, least-privilege IAM/RBAC, audit retention, and secret rotation.
- Treat Kubernetes Secret objects as sensitive configuration requiring encryption-at-rest and access controls, not as encrypted secret-management by themselves.
- Scan and sign images; record source revision and build provenance.
- Restrict public entry to the intended TLS edge; keep PostgreSQL, queues, and worker services private.

### Reliability and observability

- Define SLOs for API availability/latency, playback startup, direct-play delivery, HLS availability, upload completion, transcode queue age, and metadata scan freshness.
- Emit structured logs, metrics, and traces with request, user/device-safe correlation, job ID, service name, and image version. Avoid tokens, media URLs with secrets, and unnecessary personal data.
- Propagate trace context over HTTP and the job/event path.
- Define alert ownership, retention cost, sampling, and data access.

### Data recovery

- Specify RPO/RTO before production database or object-store migration.
- Back up both database state and required object/media metadata; a database dump without media objects is not a full media-server restore.
- Retain a source copy until checksum and catalog reconciliation is complete.
- Practice restore to an isolated environment before deleting, archiving, or redirecting any production path.

## 6. Decision register

| Decision | Needed by | Options to evaluate | Default posture |
|---|---|---|---|
| Cloud provider and region | Phase 2 | Provider capabilities, latency to users, data residency, GPU and PostgreSQL support, egress costs | Keep roadmap provider-neutral until selected |
| Production Kubernetes vs managed containers first | Phase 2 | Managed Kubernetes, managed container runtime, staged hybrid | Use the simplest option that meets required deployment/worker control; Kubernetes remains the target requested here |
| PostgreSQL hosting | Phase 2 | Managed PostgreSQL, self-managed StatefulSet | Prefer evaluating managed PostgreSQL for production; retain StatefulSet for local pilot |
| Durable media store | Phase 2 / 6 | Object store, shared filesystem, home NAS/hybrid | Use object storage for cloud durability, after access-control and egress design |
| Cloud transcoding | Phase 2 / 7 | CPU, compatible GPU, hybrid GPU workers, pre-transcode | Prove with representative media and cost measurements before commitment |
| Home LAN casting | Phase 2 / 7 | Retain a local connector, keep cast on home server, retire from cloud mode | Do not assume cloud pods can discover private LAN devices |
| Public API compatibility | Phase 3 / 8 | Thin Rust edge façade, versioned direct service APIs | Keep existing public paths stable through a Rust façade during migration |
| Microservice split | Phase 5 / 8 | Modular monolith only, worker services first, selective domain extraction | Extract workers first; create each API service only for a measurable reason |
| Image architecture | Phase 1 | linux/amd64 only, add linux/arm64 | Start with cluster node architecture; add targets only when required and verified |
| Cost and recovery objectives | Phase 2 | Monthly budget, RPO/RTO, availability target | Must be explicit before production data leaves the host |

## 7. Major risks and mitigations

| Risk | Why it matters here | Mitigation / gate |
|---|---|---|
| Premature microservice split | Adds network failures, releases, credentials, data duplication, and operations before scale is known | Extract background workers first; require an ownership/SLO/cost case per new service |
| Schema work during startup | Every replica could perform DDL and retired-schema cleanup | Replace with one versioned migration job before multi-replica rollout |
| Duplicate scheduled work | Scanner and maintenance daemons currently start with every API instance | Separate schedulers/workers or enforce explicit single-leader execution |
| Media-store migration errors | Catalog paths, archives, subtitles, and cached HLS must remain resolvable | Copy with checksums, dual-read or staged cutover, reconcile records, preserve rollback source |
| Streaming egress cost | Large media files can dominate cloud bills | Measure bytes per playback/quality, use CDN/object-store delivery where appropriate, define quotas and alerts |
| GPU incompatibility or surprise cost | Current AMF/D3D11 path is Windows-specific | Prototype and benchmark before selecting an instance/runtime; keep CPU or home-worker fallback |
| API regression for TV/mobile | Client releases are separate from server releases | Preserve public API contract, probe every staging/release build, use façade during extraction |
| Cloud networking breaks casting | Current casting assumes local-network reachability | Keep home-local connector/server or define casting as a separate product capability |
| Incomplete disaster recovery | Database and media objects are separate durable systems | Set RPO/RTO, back up both, and rehearse a full restore |
| Cloud bill growth | Idle clusters, GPU nodes, storage, logs, and egress all cost money | Budget cap, tagging, scale-to-zero where safe, retention policies, monthly review |
| Secrets or artifacts leak into images | Current native deployment reads local files and release artifacts | Externalize secrets and APK assets; inspect image layers and CI logs |

## 8. Release gates

No production phase is complete until all applicable gates pass:

1. **Build gate:** Image is produced from a known source revision; dependencies and image digest are recorded.
2. **Security gate:** Secret scan, image scan/signing policy, least-privilege configuration, and ingress review pass.
3. **Contract gate:** Rust API contracts and the Flutter/Fire TV probe pass; React playback journeys pass in staging.
4. **Data gate:** Database migrations are ordered and reversible/forward-fixable; media checksums and catalog counts reconcile.
5. **Reliability gate:** Startup/readiness, graceful drain, worker retry, backup restore, and rollback are demonstrated.
6. **Performance/cost gate:** Representative playback/transcode demand meets agreed latency, capacity, and cost limits.
7. **Cutover gate:** Runbook, monitoring, rollback trigger, data owner, and operator are named and approved.

## 9. Suggested implementation order

The critical path is:

1. Verify Phase 0 local containers and Helm pilot.
2. Decide provider, cost envelope, and cloud/hybrid intent.
3. Replace startup DDL and separate background workers.
4. Select database and media/object storage; implement backup, restore, and migration procedures.
5. Provision a secure staging platform using Infrastructure as Code.
6. Prove CPU/GPU transcode economics and media delivery.
7. Extract the first domain service only after worker separation and observability are reliable.
8. Run staging compatibility and failure drills.
9. Approve and execute a controlled production cutover.
10. Scale and further decompose only against observed needs.

## 10. Official references

- [Kubernetes workload controllers](https://kubernetes.io/docs/concepts/workloads/controllers/) — Deployments, StatefulSets, Jobs, and CronJobs.
- [Kubernetes probes](https://kubernetes.io/docs/concepts/workloads/pods/probes/) — startup, readiness, and liveness behavior.
- [Kubernetes StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/) — stable identity and persistent storage behavior.
- [Kubernetes Horizontal Pod Autoscaler](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/) — resource and custom-metric scaling.
- [Kubernetes Secret good practices](https://kubernetes.io/docs/concepts/security/secrets-good-practices/) — sensitive configuration handling.
- [Docker multi-platform builds](https://docs.docker.com/build/building/multi-platform/) — image architecture strategy.
- [Helm chart best practices](https://helm.sh/docs/chart_best_practices/) — reusable, configurable chart design.
- [OpenTelemetry observability primer](https://opentelemetry.io/docs/concepts/observability-primer/) — instrumentation and telemetry signals.
