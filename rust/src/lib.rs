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
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let system_routes = Router::new()
        .route("/api/system-status", get(routes::system::system_status_handler))
        .with_state(system_service);

    let movie_routes = Router::new()
        .route("/api/movies", get(routes::movies::list_movies_handler))
        .route("/api/movie/{filename}", get(routes::movies::get_movie_details_handler))
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
        .with_state(roots_arc.clone());

    let preview_state = Arc::new(routes::preview::PreviewState {
        pool,
        media_roots: roots_arc,
        cache_dir,
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

    Router::new()
        .route("/health", get(routes::health::health_handler))
        .route("/api/health", get(routes::health::health_handler))
        .merge(system_routes)
        .merge(movie_routes)
        .merge(progress_routes)
        .merge(media_routes)
        .merge(subtitle_routes)
        .merge(preview_routes)
        .layer(cors)
        .layer(TraceLayer::new_for_http())
}
