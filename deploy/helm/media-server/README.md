# Helm pilot

This chart deploys one Rust API pod, one PostgreSQL 18 pod, and persistent
claims for media and transcode cache. It is intended for a local Kubernetes
pilot. It has no public ingress, TLS, production data migration, or GPU device
configuration.

The API pod starts the scanner, transcode worker, and maintenance loops itself.
Keep replicaCount at 1 until those workers are separated from the API or given
cluster-wide leader election. The Linux image uses FFmpeg's CPU encoders; the
current Windows D3D11/AMF path is not available in this pilot.
The API gets a 240-second shutdown window so an in-progress FFmpeg chunk can
finish before Kubernetes replaces the pod.

## Build and load the image

Build the local image from the repository root:

~~~powershell
docker build -t media-server-api:local .
~~~

Make that image available to the selected local cluster. Docker Desktop
Kubernetes shares Docker Desktop's image store. For a kind cluster, load it
with kind load docker-image media-server-api:local; for Minikube, use
minikube image load media-server-api:local.

## Create secrets

Create the namespace, then create secrets in that namespace before installing
the chart. The app secret must include a stable MEDIA_SERVER_SECRET and a
database URL. URL-encode special characters in the database password, or use a
random password made of URL-safe characters.

~~~powershell
kubectl create namespace media-server
kubectl -n media-server create secret generic media-server-postgres-secrets `
  --from-literal=POSTGRES_PASSWORD='replace-with-a-random-url-safe-password'
kubectl -n media-server create secret generic media-server-app-secrets `
  --from-literal=MEDIA_SERVER_DATABASE_URL='postgresql://media_server:replace-with-a-random-url-safe-password@media-server-postgres:5432/media_server' `
  --from-literal=MEDIA_SERVER_SECRET='replace-with-a-long-random-secret'
~~~

Optional values such as GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, TMDB_API_TOKEN,
and MEDIA_SERVER_ADMIN_EMAILS can also be added to the app secret. Do not
commit secret values or a populated values file.

## Install and access

~~~powershell
helm upgrade --install media-server .\deploy\helm\media-server `
  --namespace media-server
kubectl -n media-server port-forward svc/media-server 8000:8000
~~~

Open http://localhost:8000. The /health endpoint reports server readiness. The
chart uses the cluster's default storage class unless one is set in
postgres.persistence.storageClassName, persistence.media.storageClassName, or
persistence.cache.storageClassName. You can supply pre-created claims with
persistence.media.existingClaim and persistence.cache.existingClaim.

The default media claim is a new, isolated 10 GiB volume. It does not mount
D:\Flicks or any other production media path. Set the claim size and storage
class deliberately for the selected cluster. Public access, TLS, LAN discovery,
casting, database backups, and a production storage migration require separate
cluster-specific decisions before a rollout.
