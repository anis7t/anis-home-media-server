use crate::error::AppError;
use crate::services::asset_service::{AssetService, ARTWORK_MAX_AGE_SECS};
use crate::services::tmdb_artwork::{ArtworkKind as TmdbArtworkKind, TmdbArtworkService};
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
    pub pool: Option<sqlx::PgPool>,
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

/// Serve TMDb artwork by id, downloading on demand.
///
/// `GET|HEAD|OPTIONS /tmdb-poster/{id}` and `/tmdb-backdrop/{id}`.
///
/// The id arrives as a string and is parsed here rather than extracted as an
/// integer: Flask declares `<int:tmdb_id>`, so a non-numeric path simply does
/// not match a route and answers 404. Extracting `i64` would answer 400
/// instead - a small divergence in an error path, but one the probe checks.
async fn tmdb_artwork(
    state: AssetState,
    id: &str,
    kind: TmdbArtworkKind,
    headers: HeaderMap,
    method: Method,
) -> Result<Response<Body>, AppError> {
    let parsed: i64 = id
        .parse()
        .map_err(|_| AppError::NotFound(format!("Invalid artwork id '{}'", id)))?;

    let pool = state
        .pool
        .as_ref()
        .ok_or_else(|| AppError::Internal("artwork routes require a database pool".to_string()))?;

    let path =
        TmdbArtworkService::get(pool, &state.cache_dir, parsed, kind).await?;
    AssetService::serve_image(path, headers, method, ARTWORK_MAX_AGE_SECS).await
}

pub async fn tmdb_poster_handler(
    State(state): State<AssetState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    method: Method,
) -> Result<Response<Body>, AppError> {
    tmdb_artwork(state, &id, TmdbArtworkKind::Poster, headers, method).await
}

pub async fn tmdb_backdrop_handler(
    State(state): State<AssetState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    method: Method,
) -> Result<Response<Body>, AppError> {
    tmdb_artwork(state, &id, TmdbArtworkKind::Backdrop, headers, method).await
}