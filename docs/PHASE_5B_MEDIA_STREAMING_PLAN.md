# Implementation Plan: Phase 5B — Multi-Root Safe Path Resolution & RFC 7233 Byte-Range Direct Play (`/media/{*path}`)

> **Document Type:** Migration Sub-Phase Implementation Plan  
> **Repository:** `anis7t/media-server`  
> **Branch:** `feat/rust-api-foundation`  
> **Parent Roadmap:** [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md) §Phase 5  
> **Parent Sliced Plan:** [`docs/PHASE_5_RUST_STREAMING_PLAN.md`](PHASE_5_RUST_STREAMING_PLAN.md)  
> **Depends On:** Phase 5A Playback Watch Progress & History API ([`docs/PHASE_5A_PROGRESS_API_WALKTHROUGH.md`](PHASE_5A_PROGRESS_API_WALKTHROUGH.md))  
> **Status:** 📋 **AWAITING USER APPROVAL**

---

## 1. Goal Description & Scope

Phase 5B delivers high-performance, zero-copy, asynchronous video streaming in the Rust Axum backend:
- Direct byte-range delivery (`/media/{*path}`) compliant with **RFC 7233** (`200 OK`, `206 Partial Content`, `416 Range Not Satisfiable`).
- Multi-root safe path resolution across mass storage `D:\Flicks`, archive mirror `D:\Flicks\.archive`, and fallback SSD roots `E:\MediaServer`.
- Strict canonical path validation eliminating directory traversal (`..`) and unauthorized path disclosure.
- Receiver and second-screen headers for Google Cast CAF receivers and DLNA televisions (`Access-Control-Allow-Origin: *`, `contentFeatures.dlna.org`, `transferMode.dlna.org: Streaming`).
- True asynchronous chunked streaming via `tokio::fs::File` and `tokio_util::io::ReaderStream` (64 KB chunk size) with zero entire-file memory buffering.

---

## 2. User Review Required & Architectural Invariants

> [!IMPORTANT]
> **Zero Memory Overhead for Multi-Gigabyte Video Files**:
> The streaming engine leverages `tokio_util::io::ReaderStream` on bounded file handles (`file.take(length)`). Even under 50 concurrent 4K streams, memory RSS remains bounded under ~100 MB, preventing OOM crashes.

> [!NOTE]
> **Multi-Root Resolution Precedence**:
> Video paths are searched in order: `D:\Flicks` (primary raw storage), then `D:\Flicks\.archive` (cold storage mirror). If a file exists in neither, it returns HTTP 404.

---

## 3. Proposed Changes

Grouped by component layer:

### 1. Crate Dependencies (`rust/Cargo.toml`)

#### [MODIFY] `rust/Cargo.toml`
Add `tokio-util` with feature `["io"]` and `mime_guess`:
```toml
[dependencies]
axum = { version = "0.8", features = ["json"] }
tokio = { version = "1", features = ["full"] }
tokio-util = { version = "0.7", features = ["io"] }
tower = { version = "0.5", features = ["util"] }
tower-http = { version = "0.6", features = ["cors", "trace"] }
sqlx = { version = "0.8", features = ["runtime-tokio", "postgres", "macros", "chrono", "json"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
chrono = { version = "0.4", features = ["serde"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
sysinfo = "0.33"
dotenvy = "0.15"
mime_guess = "2.0"
```

---

### 2. Configuration (`rust/src/config.rs`)

#### [MODIFY] `rust/src/config.rs`
Add `media_roots` vector (`D:\Flicks`, `D:\Flicks\.archive`, `E:\MediaServer`) to `AppConfig`:
```rust
#[derive(Debug, Clone)]
pub struct AppConfig {
    pub database_url: String,
    pub host: String,
    pub port: u16,
    pub media_root: PathBuf,
    pub media_roots: Vec<PathBuf>,
    pub cache_dir: PathBuf,
}
```

---

### 3. Path Resolution Service (`rust/src/services/path_resolver.rs`)

#### [NEW] `rust/src/services/path_resolver.rs`
Safe multi-root path lookup and directory traversal defense:
```rust
use crate::error::AppError;
use std::path::{Component, Path, PathBuf};

pub struct PathResolver;

impl PathResolver {
    /// Resolve a sanitized relative video path across configured media roots.
    pub fn resolve_media_path(filename: &str, roots: &[PathBuf]) -> Result<PathBuf, AppError> {
        if filename.contains('\0') {
            return Err(AppError::NotFound("Invalid filename".to_string()));
        }

        let rel_path = Path::new(filename);

        // Disallow any traversal components
        for comp in rel_path.components() {
            if let Component::ParentDir = comp {
                return Err(AppError::Forbidden("Directory traversal denied".to_string()));
            }
        }

        // Try candidate paths across media roots
        for root in roots {
            let candidate = root.join(rel_path);
            if candidate.is_file() {
                if let (Ok(canon_cand), Ok(canon_root)) = (candidate.canonicalize(), root.canonicalize()) {
                    if canon_cand.starts_with(&canon_root) {
                        return Ok(canon_cand);
                    }
                }
            }
        }

        Err(AppError::NotFound(format!("Media file '{}' not found", filename)))
    }
}
```

---

### 4. RFC 7233 Range Service (`rust/src/services/range_service.rs`)

#### [NEW] `rust/src/services/range_service.rs`
Range parsing, boundary arithmetic, and asynchronous stream response generation:
```rust
use crate::error::AppError;
use axum::{
    body::Body,
    http::{header, HeaderMap, HeaderValue, Method, Response, StatusCode},
};
use std::path::PathBuf;
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncSeekExt, SeekFrom};
use tokio_util::io::ReaderStream;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpRange {
    FromTo(u64, u64),
    From(u64),
    Suffix(u64),
}

impl HttpRange {
    pub fn parse(header: &str) -> Option<Self> {
        let spec = header.trim().strip_prefix("bytes=")?;
        let first = spec.split(',').next()?.trim();
        if let Some(suffix) = first.strip_prefix('-') {
            first.parse::<u64>().ok().map(HttpRange::Suffix)
        } else if let Some(idx) = first.find('-') {
            let start = first[..idx].trim().parse::<u64>().ok()?;
            let end_str = first[idx + 1..].trim();
            if end_str.is_empty() {
                Some(HttpRange::From(start))
            } else {
                let end = end_str.parse::<u64>().ok()?;
                Some(HttpRange::FromTo(start, end))
            }
        } else {
            None
        }
    }

    pub fn resolve(self, total: u64) -> Result<(u64, u64), ()> {
        if total == 0 {
            return Err(());
        }
        match self {
            HttpRange::FromTo(start, end) => {
                if start >= total || start > end {
                    Err(())
                } else {
                    Ok((start, end.min(total - 1)))
                }
            }
            HttpRange::From(start) => {
                if start >= total {
                    Err(())
                } else {
                    Ok((start, total - 1))
                }
            }
            HttpRange::Suffix(len) => {
                if len == 0 {
                    Err(())
                } else {
                    let len = len.min(total);
                    Ok((total - len, total - 1))
                }
            }
        }
    }
}

pub struct RangeService;

impl RangeService {
    pub async fn stream_file(
        path: PathBuf,
        headers: HeaderMap,
        method: Method,
    ) -> Result<Response<Body>, AppError> {
        let mut file = File::open(&path).await.map_err(|e| AppError::NotFound(e.to_string()))?;
        let metadata = file.metadata().await.map_err(|e| AppError::Internal(e.to_string()))?;
        let total_size = metadata.len();

        let mime = mime_guess::from_path(&path)
            .first_or_octet_stream()
            .as_ref()
            .to_string();

        let mut res_headers = HeaderMap::new();
        res_headers.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
        res_headers.insert(header::CONTENT_TYPE, HeaderValue::from_str(&mime).unwrap());
        res_headers.insert("access-control-allow-origin", HeaderValue::from_static("*"));
        res_headers.insert("access-control-allow-methods", HeaderValue::from_static("GET, HEAD, OPTIONS"));
        res_headers.insert("access-control-allow-headers", HeaderValue::from_static("Range, Origin, Accept, Content-Type"));
        res_headers.insert("access-control-expose-headers", HeaderValue::from_static("Content-Length, Content-Range, Accept-Ranges"));
        res_headers.insert("cross-origin-resource-policy", HeaderValue::from_static("cross-origin"));
        res_headers.insert("contentfeatures.dlna.org", HeaderValue::from_static("DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"));
        res_headers.insert("transfermode.dlna.org", HeaderValue::from_static("Streaming"));

        if let Some(range_raw) = headers.get(header::RANGE).and_then(|v| v.to_str().ok()) {
            if let Some(parsed) = HttpRange::parse(range_raw) {
                match parsed.resolve(total_size) {
                    Ok((start, end)) => {
                        let length = end - start + 1;
                        res_headers.insert(header::CONTENT_LENGTH, HeaderValue::from(length));
                        res_headers.insert(
                            header::CONTENT_RANGE,
                            HeaderValue::from_str(&format!("bytes {}-{}/{}", start, end, total_size)).unwrap(),
                        );

                        let body = if method == Method::HEAD {
                            Body::empty()
                        } else {
                            file.seek(SeekFrom::Start(start)).await.map_err(|e| AppError::Internal(e.to_string()))?;
                            let stream = ReaderStream::with_capacity(file.take(length), 64 * 1024);
                            Body::from_stream(stream)
                        };

                        let mut res = Response::new(body);
                        *res.status_mut() = StatusCode::PARTIAL_CONTENT;
                        *res.headers_mut() = res_headers;
                        return Ok(res);
                    }
                    Err(_) => {
                        res_headers.insert(
                            header::CONTENT_RANGE,
                            HeaderValue::from_str(&format!("bytes */{}", total_size)).unwrap(),
                        );
                        let mut res = Response::new(Body::empty());
                        *res.status_mut() = StatusCode::RANGE_NOT_SATISFIABLE;
                        *res.headers_mut() = res_headers;
                        return Ok(res);
                    }
                }
            }
        }

        // Full 200 response
        res_headers.insert(header::CONTENT_LENGTH, HeaderValue::from(total_size));
        let body = if method == Method::HEAD {
            Body::empty()
        } else {
            let stream = ReaderStream::with_capacity(file, 64 * 1024);
            Body::from_stream(stream)
        };

        let mut res = Response::new(body);
        *res.status_mut() = StatusCode::OK;
        *res.headers_mut() = res_headers;
        Ok(res)
    }
}
```

---

### 5. Media Route Handler (`rust/src/routes/media.rs`)

#### [NEW] `rust/src/routes/media.rs`
Axum handler for `/media/{*path}` with GET, HEAD, and OPTIONS support:
```rust
use crate::error::AppError;
use crate::services::path_resolver::PathResolver;
use crate::services::range_service::RangeService;
use axum::{
    body::Body,
    extract::{Path, State},
    http::{HeaderMap, Method, Response, StatusCode},
};
use std::path::PathBuf;
use std::sync::Arc;

pub async fn media_handler(
    State(roots): State<Arc<Vec<PathBuf>>>,
    headers: HeaderMap,
    method: Method,
    Path(filename): Path<String>,
) -> Result<Response<Body>, AppError> {
    if method == Method::OPTIONS {
        let mut res = Response::new(Body::empty());
        *res.status_mut() = StatusCode::OK;
        let h = res.headers_mut();
        h.insert("access-control-allow-origin", "*".parse().unwrap());
        h.insert("access-control-allow-methods", "GET, HEAD, OPTIONS".parse().unwrap());
        h.insert("access-control-allow-headers", "Range, Origin, Accept, Content-Type".parse().unwrap());
        return Ok(res);
    }

    let resolved_path = PathResolver::resolve_media_path(&filename, &roots)?;
    RangeService::stream_file(resolved_path, headers, method).await
}
```

---

### 6. Router Integration (`rust/src/lib.rs`)

#### [MODIFY] `rust/src/lib.rs`
Mount `/media/{*filename}` route with shared `Arc<Vec<PathBuf>>`:
```rust
    let media_roots = Arc::new(config.media_roots.clone());
    let media_routes = Router::new()
        .route("/media/{*filename}", get(routes::media::media_handler).head(routes::media::media_handler).options(routes::media::media_handler))
        .with_state(media_roots);
```

---

## 4. Verification Plan

### Automated Tests (`rust/tests/streaming_range_test.rs`)
Test against actual fixture files on disk:

1. **Full content (No Range)**:
   - `GET /media/{sample_file}`
   - Assert `200 OK`, `Accept-Ranges: bytes`, `Content-Length: {size}`, `Content-Type: video/mp4`.
2. **Initial Range (`bytes=0-1023`)**:
   - `GET /media/{sample_file}` with `Range: bytes=0-1023`.
   - Assert `206 Partial Content`, `Content-Length: 1024`, `Content-Range: bytes 0-1023/{size}`.
3. **Mid-stream Range (`bytes=1000-1999`)**:
   - `GET /media/{sample_file}` with `Range: bytes=1000-1999`.
   - Assert `206 Partial Content`, `Content-Length: 1000`, `Content-Range: bytes 1000-1999/{size}`.
4. **Open-ended Range (`bytes=1000-`)**:
   - `GET /media/{sample_file}` with `Range: bytes=1000-`.
   - Assert `206 Partial Content`, `Content-Length: {size - 1000}`, `Content-Range: bytes 1000-{size-1}/{size}`.
5. **Suffix Range (`bytes=-500`)**:
   - `GET /media/{sample_file}` with `Range: bytes=-500`.
   - Assert `206 Partial Content`, `Content-Length: 500`.
6. **Unsatisfiable Range (`bytes=999999999-`)**:
   - `GET /media/{sample_file}` with `Range: bytes=999999999-`.
   - Assert `416 Range Not Satisfiable`, `Content-Range: bytes */{size}`.
7. **Directory Traversal Denial**:
   - `GET /media/../../windows/system32/calc.exe` -> assert `403 Forbidden` or `404 Not Found`.
8. **HEAD request**:
   - `HEAD /media/{sample_file}` with `Range: bytes=0-1023`.
   - Assert `206 Partial Content`, headers present, empty body.
9. **CORS & DLNA Headers**:
   - Assert `Access-Control-Allow-Origin: *` and `transferMode.dlna.org: Streaming`.

### Test Execution Commands
```powershell
.\scripts\cargo.bat test --manifest-path rust\Cargo.toml --test streaming_range_test
.\scripts\cargo.bat test --manifest-path rust\Cargo.toml
.\scripts\cargo.bat check --manifest-path rust\Cargo.toml
```
