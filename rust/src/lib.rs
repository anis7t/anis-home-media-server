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
        pool: pool.clone(),
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
        cache_dir: cache_dir_arc.clone(),
        pool: Some(pool.clone()),
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

    // Phase 6A: durable transcode job queue. Admission, listing and cancel
    // are exposed now; nothing spawns FFmpeg yet (that is 6C).
    //
    // ONE wildcard route, dispatched internally by suffix. Axum's radix
    // router forbids `/jobs/{*filename}` and `/jobs/{*filename}/cancel`
    // together (AGENTS.md s9): the wildcard swallows the whole tail, so the
    // two patterns conflict and the router panics at startup - which is what
    // broke every other suite until it was found.
    let job_routes = Router::new()
        .route("/api/transcode/jobs", get(routes::jobs::list_jobs_handler))
        .route(
            "/api/transcode/jobs/{*path}",
            axum::routing::post(routes::jobs::jobs_dispatch_handler),
        )
        .with_state(routes::jobs::JobState {
            pool: Arc::new(pool.clone()),
        });

    // Phase C1a: locally stored poster art, native. Registered BEFORE the proxy
    // router so it cannot be shadowed; the `/poster/{*path}` proxy entry is
    // removed below now that this owns the prefix.
    let asset_state = routes::assets::AssetState {
        roots: roots_arc.clone(),
        cache_dir: cache_dir_arc.clone(),
        pool: Some(pool.clone()),
    };

    let asset_routes = Router::new()
        .route(
            "/poster/{*filename}",
            get(routes::assets::poster_handler)
                .head(routes::assets::poster_handler)
                .options(routes::assets::poster_handler),
        )
        .route(
            "/tmdb-poster/{id}",
            get(routes::assets::tmdb_poster_handler)
                .head(routes::assets::tmdb_poster_handler)
                .options(routes::assets::tmdb_poster_handler),
        )
        .route(
            "/tmdb-backdrop/{id}",
            get(routes::assets::tmdb_backdrop_handler)
                .head(routes::assets::tmdb_backdrop_handler)
                .options(routes::assets::tmdb_backdrop_handler),
        )
        .with_state(asset_state);

    // Phase C2: technical media details, native.
    let media_info_routes = Router::new()
        .route(
            "/api/media-info/{*filename}",
            get(routes::media_info::media_info_handler)
                .head(routes::media_info::media_info_handler)
                .options(routes::media_info::media_info_handler),
        )
        .with_state(routes::media_info::MediaInfoState {
            roots: roots_arc.clone(),
            cache_dir: cache_dir_arc.clone(),
            pool: Some(pool.clone()),
        });

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
            .route("/api/admin", axum::routing::any(routes::proxy::proxy_handler))
            .route("/api/admin/{*path}", axum::routing::any(routes::proxy::proxy_handler))
            .route("/api/storage", axum::routing::any(routes::proxy::proxy_handler))
            .route("/api/storage/{*path}", axum::routing::any(routes::proxy::proxy_handler))
            .route("/api/scan", axum::routing::any(routes::proxy::proxy_handler))
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
        .merge(job_routes)
        .merge(asset_routes)
        .merge(media_info_routes)
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
