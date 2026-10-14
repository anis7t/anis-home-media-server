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
        .with_state(pool);

    let roots_arc = Arc::new(media_roots);
    let media_routes = Router::new()
        .route(
            "/media/{*filename}",
            get(routes::media::media_handler)
                .head(routes::media::media_handler)
                .options(routes::media::media_handler),
        )
        .with_state(roots_arc);

    Router::new()
        .route("/health", get(routes::health::health_handler))
        .route("/api/health", get(routes::health::health_handler))
        .merge(system_routes)
        .merge(movie_routes)
        .merge(progress_routes)
        .merge(media_routes)
        .layer(cors)
        .layer(TraceLayer::new_for_http())
}
