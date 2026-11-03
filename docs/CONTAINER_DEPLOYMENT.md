# Container Deployment Pilot

The Docker Compose and Helm setups are for isolated local development and a
Kubernetes pilot. They do not replace the Windows production services, mount
the production library by default, or migrate production PostgreSQL data.

## Docker Compose

Requirements: Docker Desktop using Linux containers and Compose v2.

From the repository root, run:

~~~powershell
docker compose up --build
~~~

Open http://localhost:8000. The API is bound to loopback only. Compose starts a
fresh PostgreSQL database and builds the React SPA into the Rust API image.
The default media directory is .docker/local-data/media; the transcode cache
and PostgreSQL data use separate named Docker volumes.

The default database password and application secret in compose.yaml are
development-only values. They are not copied into the image. The database
port is not published, and the API port is bound to 127.0.0.1. If you change
the deployment boundary, set MEDIA_DOCKER_DB_PASSWORD and
MEDIA_DOCKER_APP_SECRET to private values before starting it.

To choose a different local development media folder, set the path explicitly
before starting Compose:

~~~powershell
$env:MEDIA_DOCKER_MEDIA_PATH = 'C:/media-server-dev/media'
docker compose up --build
~~~

The server can upload, archive, and manage files under the configured media
root. Do not point this setting at D:\Flicks for the pilot. The server applies
schema changes on startup, so MEDIA_SERVER_DATABASE_URL must keep pointing at
the Compose database and must never be set to the production database URL.

Use docker compose down to stop the stack while preserving its named database
and cache volumes. docker compose down --volumes removes those named volumes;
the bind-mounted development media directory remains on the host.

Compose runs Linux FFmpeg software encoders. The Windows D3D11/AMF hardware
transcode path is not active in these containers. Public TLS, LAN DLNA
discovery, and casting are not configured in this local-only setup.

## Kubernetes with Helm

The chart is at deploy/helm/media-server. Setup steps, secret keys, image
loading notes, storage values, and local port forwarding are in the
[Helm pilot README](../deploy/helm/media-server/README.md).

The chart creates a new PostgreSQL 18 StatefulSet and PVCs for the pilot media
directory and cache. It does not include an Ingress or TLS configuration;
access is through kubectl port-forward until a cluster-specific ingress is
chosen. Keep the API at one replica because each process starts background
scanner, transcode, and maintenance workers.

## Phase 0 verification (2026-11-04)

**Status: in progress, not yet passed.** The evidence below records a successful
local pilot run, not a complete release gate. The roadmap's clean-checkout build
and repeatable automated regression checks remain required before Phase 0 can
be marked complete.

The local pilot was run on Docker Desktop 4.98.0 / Engine 29.9.2. Docker's WSL
disk image is at `E:\DockerData\DockerDesktopWSL`; the previous C: copy was
removed by Docker Desktop after the move. The Compose API used loopback port
18001 because host port 8000 was unavailable. The default media bind resolved
to `.docker/local-data/media` and did not include the production library.

- The Linux image built successfully. Its final image size was 795,363,433
  bytes (about 759 MiB). The server listened within 0.5 seconds of process
  start, and Compose reported it healthy within 20 seconds. PostgreSQL schema
  setup and pool verification completed during startup.
- Both Compose services reached healthy status. A dedicated marker row and two
  scanned movie rows remained after forcibly recreating the Compose PostgreSQL
  container; the named volume was preserved.
- Two disposable clips were scanned with no scanner errors. The MP4 direct-play
  request returned HTTP 206 for `bytes 0-1023/86838`. Its media-info response
  reported H.264 direct play. A local SRT sidecar was listed and streamed as
  WebVTT; seek-preview metadata and a JPEG thumbnail were returned successfully.
- A six-second Matroska clip completed an HLS CPU transcode. The worker reported
  complete coverage, the progress file ended, and the master playlist, 360p
  playlist, initialization segment, and media segment each returned HTTP 200.
  FFmpeg reported `speed=1.00x`. The worker's claim-to-completion interval was
  about 1.84 seconds for this small sample.
- The API process ran as UID/GID 10001. The Compose `/media`, `/cache`, and
  `/tmp` paths were writable. Compose enables an init process and a four-minute
  stop grace period; the Helm API pod uses UID 10001, read-only root filesystem,
  mounted writable paths, and the same 240-second grace period.
- Graceful shutdown was exercised with a five-minute transcode actively running
  (FFmpeg was confirmed in the container process list). Compose delivered the
  stop signal; the API logged graceful shutdown and the container stopped in
  about 4.2 seconds, well inside its grace period. After restarting the API,
  its health check passed and no FFmpeg child process remained. The interrupted
  long-running sample job was a disposable local test and is not evidence of
  resumable transcode-job recovery.
- The Docker Desktop Kind cluster (`docker-desktop`, one node, Kubernetes
  1.36.1) reached Ready. Helm lint and rendering passed. The first rollout
  exposed an API Service selector that also matched the Postgres pod; the chart
  now labels API pods with `app.kubernetes.io/component: api` and selects that
  component. The upgraded release reached Ready, all PVCs bound, port-forwarded
  health returned healthy, and a marker row in the Helm PostgreSQL PVC remained
  after deleting and recreating the API pod.

### Phase 0 exit-criteria tracking

| Criterion | Current evidence | State |
|---|---|---|
| Clean, cache-independent image build from a clean checkout | The image built from the current working tree with cached layers. | Open |
| Isolated Compose startup, health, database recreation, and persistence | Both services were healthy; database marker and catalog rows survived Postgres container recreation. | Verified manually |
| Scan, direct-play byte range, CPU HLS transcode and outputs, subtitle, and seek preview | Disposable media fixtures covered these paths successfully. | Verified manually |
| Helm lint/render, local rollout, API-only Service selection, readiness, and PostgreSQL persistence after API restart | The Kind rollout was Ready, PVCs bound, API Service selected only API, and a marker row survived pod replacement. | Verified manually |
| Active FFmpeg shutdown and child cleanup | One Compose stop while FFmpeg was active completed within the grace period; no child remained after API restart. | Verified manually; repeated and Helm termination coverage open |
| Authenticated upload/archive and positive authentication path | OAuth was unconfigured; anonymous upload-init was denied with 403. | Open |
| Repeatable automated container regression suite | The recorded checks were run manually; the consolidated automated suite has not yet been implemented and run. | Open |
| Secret, production-path, and authorization negative regressions | Defaults and one anonymous upload denial were inspected/tested manually. | Open for automated coverage |

The next Phase 0 work is to add and run automated regressions for the open
criteria, then rebuild from a clean checkout without relying on cached image
layers. Use only disposable fixtures and fresh local volumes. Never point
Compose or Helm at production media or PostgreSQL. Google OAuth credentials
must not be copied into source, image layers, command output, or test logs; if
real OAuth cannot be safely exercised, cover the enabled/disabled and
allowed/denied paths through a documented test configuration or test seam.

Keep Phase 0 open until every roadmap exit criterion has authoritative passing
evidence. Record commands, fixture setup, expected results, actual results,
cleanup, and any platform-specific limitation here.

When running on a host where port 8000 is occupied, set
`MEDIA_DOCKER_HTTP_PORT` and set `MEDIA_DOCKER_PUBLIC_BASE_URL` to the same
loopback origin before enabling OAuth. For this run, the API was bound to
`127.0.0.1:18001`.

## Current limitations

- The Linux containers use CPU transcoding. Preserving the current AMD AMF /
  D3D11 GPU path requires a separate runtime and hardware support decision.
- DLNA discovery and cast playback depend on LAN networking that is not set up
  by this pilot.
- The image excludes Android APK update artifacts. The app update routes need
  an updates directory mounted at the server's base directory before use.
- Storage sizes and storage classes in the Helm values are pilot defaults.
  Choose production-grade storage and backup procedures before moving data.
- Do not point either setup at production PostgreSQL: schema setup runs at
  application startup and includes retired-schema cleanup operations.
