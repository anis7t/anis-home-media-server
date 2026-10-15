use crate::error::AppError;
use crate::services::asset_service::{AssetService, ARTWORK_MAX_AGE_SECS};
use axum::{
    body::Body,
    extract::{Path, State},
    http::{HeaderMap, HeaderValue, Method, Response, StatusCode},
};
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone)]
pub struct AssetState {
    pub roots: Arc<Vec<PathBuf>>,
    pub cache_dir: Arc<PathBuf>,
}

fn cors_image_headers(h: &mut HeaderMap) {
    h.insert("access-control-allow-origin", HeaderValue::from_static("*"));
    h.insert(
        "access-control-allow-methods",
        HeaderValue::from_static("GET, HEAD, OPTIONS"),
    );
    h.insert(
        "access-control-allow-headers",
        HeaderValue::from_static("Range, Origin, Accept, Content-Type"),
    );
}

/// `GET|HEAD|OPTIONS /poster/{*filename}` - locally stored poster art.
///
/// Read-only. Replaces the `/poster/{*path}` proxy entry, so this handler
/// must reproduce the Flask route's answers exactly: 200 for a real image
/// under a media root, 404 for anything else (missing, wrong extension, or
/// outside the roots).
pub async fn poster_handler(
    State(state): State<AssetState>,
    Path(filename): Path<String>,
    headers: HeaderMap,
    method: Method,
) -> Result<Response<Body>, AppError> {
    if method == Method::OPTIONS {
        let mut res = Response::new(Body::empty());
        *res.status_mut() = StatusCode::OK;
        cors_image_headers(res.headers_mut());
        return Ok(res);
    }

    let path = AssetService::resolve_local_image(&state.roots, &filename)?;
    AssetService::serve_image(path, headers, method, ARTWORK_MAX_AGE_SECS).await
}