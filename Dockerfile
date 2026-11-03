# Build the React SPA with the same Node.js major used by CI.
FROM node:22-bookworm-slim AS web-build
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

# Build the Axum server on Debian so native TLS dependencies match the runtime.
FROM rust:1.88-bookworm AS api-build
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY rust/ ./rust/
RUN cargo build --locked --release --manifest-path rust/Cargo.toml --bin media-server-api

# Runtime includes software FFmpeg, TLS certificates, health-check tooling,
# and procps for terminating FFmpeg subprocesses on Linux.
FROM debian:bookworm-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl ffmpeg libssl3 procps \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --create-home --home-dir /var/lib/media-server media-server \
    && install -d -o media-server -g media-server /app /media /cache /tmp

WORKDIR /app
COPY --from=api-build --chown=media-server:media-server \
    /src/rust/target/release/media-server-api /usr/local/bin/media-server-api
COPY --from=web-build --chown=media-server:media-server /src/web/dist ./web/dist

ENV RUST_HOST=0.0.0.0 \
    RUST_PORT=8000 \
    MEDIA_SERVER_BASE_DIR=/app \
    MEDIA_SERVER_STATIC_DIR=/app/web/dist \
    MEDIA_SERVER_MEDIA_ROOT=/media \
    MEDIA_SERVER_CACHE_DIR=/cache

USER 10001:10001
EXPOSE 8000
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
    CMD curl --fail --silent http://127.0.0.1:8000/health || exit 1

ENTRYPOINT ["/usr/local/bin/media-server-api"]
