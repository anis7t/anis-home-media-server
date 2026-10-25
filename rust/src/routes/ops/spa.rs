use axum::{
    extract::Request,
    http::{header, HeaderValue, StatusCode, Uri},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;
use std::path::PathBuf;
use tower::ServiceExt;
use tower_http::services::{ServeDir, ServeFile};

#[derive(Clone, Debug)]
pub struct SpaFallbackService {
    serve_dir: ServeDir<ServeFile>,
}

impl SpaFallbackService {
    pub fn new(dist_path: &PathBuf) -> Self {
        let index_file = dist_path.join("index.html");
        let serve_dir = ServeDir::new(dist_path).fallback(ServeFile::new(index_file));
        Self { serve_dir }
    }

    pub async fn handle(&self, uri: Uri, req: Request) -> Response {
        let path = uri.path();

        // 1. Never serve HTML for API or media routes that were not matched.
        if path.starts_with("/api/")
            || path.starts_with("/media/")
            || path.starts_with("/hls/")
            || path.starts_with("/subtitles/")
            || path.starts_with("/seek-preview/")
            || path.starts_with("/preview-vtt/")
            || path.starts_with("/tmdb-poster/")
            || path.starts_with("/tmdb-backdrop/")
            || path.starts_with("/poster/")
            || path.starts_with("/auth/")
            || path == "/auth"
        {
            return (
                StatusCode::NOT_FOUND,
                Json(json!({
                    "error": "Not Found",
                    "path": path,
                })),
            )
                .into_response();
        }

        // 2. Delegate to ServeDir with index.html fallback
        let mut res = match self.serve_dir.clone().oneshot(req).await {
            Ok(r) => r.into_response(),
            Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, "Static file error").into_response(),
        };

        // 3. Set Cache-Control based on content type and asset path
        if path.starts_with("/assets/") {
            res.headers_mut().insert(
                header::CACHE_CONTROL,
                HeaderValue::from_static("public, max-age=31536000, immutable"),
            );
        } else {
            res.headers_mut().insert(
                header::CACHE_CONTROL,
                HeaderValue::from_static("no-cache, must-revalidate"),
            );
        }

        res
    }
}
