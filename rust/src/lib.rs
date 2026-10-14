pub mod config;
pub mod db;
pub mod error;
pub mod models;
pub mod routes;
pub mod services;

use axum::{routing::get, Router};
use sqlx::PgPool;
use std::path::PathBuf;
use std::sync::Arc;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;

use crate::services::system_service::SystemService;

pub fn create_app(
    pool: PgPool,
    system_service: SystemService,
    media_roots: Vec<PathBuf>,
    cache_dir: PathBuf,
) -> Router {
    create_app_full(pool, system_service, media_roots, cache_dir, None, None)
}

pub fn create_app_with_static(
    pool: PgPool,
    system_service: SystemService,
    media_roots: Vec<PathBuf>,
    cache_dir: PathBuf,
    static_dir: Option<PathBuf>,
) -> Router {
    create_app_full(pool, system_service, media_roots, cache_dir, static_dir, None)
}

pub fn create_app_full(
    pool: PgPool,
    system_service: SystemService,
    media_roots: Vec<PathBuf>,
    cache_dir: PathBuf,
    static_dir: Option<PathBuf>,
    flask_origin: Option<String>,
) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let system_routes = Router::new()
        .route("/api/system-status", get(routes::system::system_status_handler))
        .with_state(system_service);

    let movie_routes = Router::new()
        .route("/api/movies", get(routes::movies::list_movies_handler))
        .route("/api/movie/{*filename}", get(routes::movies::get_movie_details_handler))
        .with_state(pool.clone());

    let progress_routes = Router::new()
        .route(
            "/api/progress",
            get(routes::progress::get_progress_handler)
                .post(routes::progress::post_progress_handler),
        )
        .with_state(pool.clone());

    let roots_arc = Arc::new(media_roots);
    let media_routes = Router::new()
        .route(
            "/media/{*filename}",
            get(routes::media::media_handler)
                .head(routes::media::media_handler)
                .options(routes::media::media_handler),
        )
        .with_state(roots_arc.clone());

    let cache_dir_arc = Arc::new(cache_dir);

    let subtitle_state = routes::subtitles::SubtitleState {
        roots: roots_arc.clone(),
        cache_dir: cache_dir_arc.clone(),
        pool: pool.clone(),
    };

    let subtitle_routes = Router::new()
        .route(
            "/subtitles/{*path}",
            get(routes::subtitles::subtitle_stream_handler)
                .head(routes::subtitles::subtitle_stream_handler)
                .options(routes::subtitles::subtitle_stream_handler),
        )
        .route(
            "/api/subtitles/{*filename}",
            get(routes::subtitles::list_subtitles_handler),
        )
        .route(
            "/api/upload-subtitle/{*filename}",
            axum::routing::post(routes::subtitles::upload_subtitle_handler),
        )
        .with_state(subtitle_state);

    let preview_state = Arc::new(routes::preview::PreviewState {
        pool,
        media_roots: roots_arc.clone(),
        cache_dir: (*cache_dir_arc).clone(),
    });

    let preview_routes = Router::new()
        .route(
            "/api/seek-preview-meta/{*filename}",
            get(routes::preview::get_preview_meta_handler),
        )
        .route(
            "/seek-preview/{*path}",
            get(routes::preview::get_preview_thumb_handler)
                .head(routes::preview::get_preview_thumb_handler)
                .options(routes::preview::get_preview_thumb_handler),
        )
        .route(
            "/preview-vtt/{*filename}",
            get(routes::preview::get_preview_vtt_handler)
                .head(routes::preview::get_preview_vtt_handler)
                .options(routes::preview::get_preview_vtt_handler),
        )
        .with_state(preview_state);

    let hls_state = routes::hls::HlsState {
        roots: roots_arc.clone(),
        cache_dir: cache_dir_arc.clone(),
    };

    let hls_routes = Router::new()
        .route(
            "/hls/{*path}",
            get(routes::hls::hls_handler)
                .head(routes::hls::hls_handler)
                .options(routes::hls::hls_handler),
        )
        .with_state(hls_state);

    let transcode_state = routes::transcode::TranscodeState {
        roots: roots_arc.clone(),
        cache_dir: cache_dir_arc,
    };

    let transcode_routes = Router::new()
        .route(
            "/transcode/{*filename}",
            get(routes::transcode::transcode_handler)
                .head(routes::transcode::transcode_handler)
                .options(routes::transcode::transcode_handler),
        )
        .route(
            "/api/transcode-status/{*filename}",
            get(routes::transcode::transcode_status_handler),
        )
        .with_state(transcode_state);

    let proxy_routes = if let Some(origin) = flask_origin {
        let proxy_state = Arc::new(routes::proxy::ProxyState::new(origin));
        Router::new()
            .route("/auth", axum::routing::any(routes::proxy::proxy_handler))
            .route("/auth/{*path}", axum::routing::any(routes::proxy::proxy_handler))
            .route("/api/auth", axum::routing::any(routes::proxy::proxy_handler))
            .route("/api/auth/{*path}", axum::routing::any(routes::proxy::proxy_handler))
            .route("/api/devices", axum::routing::any(routes::proxy::proxy_handler))
            .route("/api/devices/{*path}", axum::routing::any(routes::proxy::proxy_handler))
            .route("/api/cast", axum::routing::any(routes::proxy::proxy_handler))
            .route("/api/cast/{*path}", axum::routing::any(routes::proxy::proxy_handler))
            .route("/tmdb-poster/{*path}", axum::routing::any(routes::proxy::proxy_handler))
            .route("/tmdb-backdrop/{*path}", axum::routing::any(routes::proxy::proxy_handler))
            .route("/poster/{*path}", axum::routing::any(routes::proxy::proxy_handler))
            .route("/api/admin", axum::routing::any(routes::proxy::proxy_handler))
            .route("/api/admin/{*path}", axum::routing::any(routes::proxy::proxy_handler))
            .route("/api/storage", axum::routing::any(routes::proxy::proxy_handler))
            .route("/api/storage/{*path}", axum::routing::any(routes::proxy::proxy_handler))
            .route("/api/scan", axum::routing::any(routes::proxy::proxy_handler))
            .route("/api/media-info/{*path}", axum::routing::any(routes::proxy::proxy_handler))
            .with_state(proxy_state)
    } else {
        Router::new()
    };

    let app = Router::new()
        .route("/health", get(routes::health::health_handler))
        .route("/api/health", get(routes::health::health_handler))
        .merge(system_routes)
        .merge(movie_routes)
        .merge(progress_routes)
        .merge(media_routes)
        .merge(subtitle_routes)
        .merge(preview_routes)
        .merge(hls_routes)
        .merge(transcode_routes)
        .merge(proxy_routes);

    let dist_path = static_dir.unwrap_or_else(|| {
        let rel_dist = PathBuf::from("web/dist");
        if rel_dist.exists() {
            rel_dist
        } else {
            let abs_dist = PathBuf::from("E:\\MediaServer\\web\\dist");
            if abs_dist.exists() {
                abs_dist
            } else {
                rel_dist
            }
        }
    });

    let app = if dist_path.join("index.html").exists() {
        let spa_service = routes::spa::SpaFallbackService::new(&dist_path);
        app.fallback(move |uri: axum::http::Uri, req: axum::extract::Request| {
            let spa = spa_service.clone();
            async move { spa.handle(uri, req).await }
        })
    } else {
        app.fallback(|uri: axum::http::Uri| async move {
            let path = uri.path().to_string();
            (
                axum::http::StatusCode::NOT_FOUND,
                axum::Json(serde_json::json!({
                    "error": "Not Found",
                    "path": path,
                })),
            )
        })
    };

    app.layer(cors).layer(TraceLayer::new_for_http())
}
