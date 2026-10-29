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
        h.insert(
            "access-control-allow-methods",
            "GET, HEAD, OPTIONS".parse().unwrap(),
        );
        h.insert(
            "access-control-allow-headers",
            "Range, Origin, Accept, Content-Type".parse().unwrap(),
        );
        return Ok(res);
    }

    let resolved_path = PathResolver::resolve_media_path(&filename, &roots)?;
    RangeService::stream_file(resolved_path, headers, method).await
}
