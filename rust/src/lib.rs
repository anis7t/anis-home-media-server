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
use tower_http::trace::TraceLayer;

use crate::services::system_service::SystemService;

/// Paths a cast receiver fetches itself, and therefore the only paths that
/// may be readable from another origin.
const RECEIVER_CORS_PATHS: [&str; 2] = ["/media/", "/hls/"];

/// Receiver CORS, scoped exactly as Flask scopes it.
///
/// A cast receiver is a web runtime (CAF), not a dumb player: it fetches the
/// HLS manifest and every segment **cross-origin**. Without these headers the
/// TV downloads the playlist, requests *no segment*, and the session ends at
/// `stopped` with no error this server can see - the whole of "MP4 casts,
/// MKV does not". A loader that sends `Range` also preflights, because
/// `Range` is not a safelisted header, so OPTIONS is answered here too.
///
/// The scope is the security half. Flask applies these in an `after_request`
/// over `/media/` and `/hls/` and deliberately leaves `/api/*` unreadable
/// from another origin. A blanket `CorsLayer` over the whole app does the
/// opposite and is a live regression, not a style question:
///
/// * any page the user visits can read the library, the device fleet and
///   host telemetry, and
/// * the preflight stops failing, so browsers stop blocking cross-origin
///   writes to `/api/*`. The missing ACAO *was* the defence in depth for
///   `/api/scan`, `/api/storage/*` and `/api/admin*`.
///
/// Measured on both engines before this change: Flask sent no
/// `Access-Control-Allow-Origin` on `/api/movies`; Rust sent `*`.
async fn receiver_cors(req: axum::extract::Request, next: axum::middleware::Next) -> axum::response::Response {
    let path = req.uri().path();
    if !RECEIVER_CORS_PATHS.iter().any(|p| path.starts_with(p)) {
        return next.run(req).await;
    }

    // Answered here rather than in each handler so the preflight cannot drift
    // from the response headers.
    let mut res = if req.method() == axum::http::Method::OPTIONS {
        axum::response::Response::builder()
            .status(axum::http::StatusCode::OK)
            .body(axum::body::Body::empty())
            .expect("static response is valid")
    } else {
        next.run(req).await
    };

    let h = res.headers_mut();
    h.insert(
        axum::http::header::ACCESS_CONTROL_ALLOW_ORIGIN,
        axum::http::HeaderValue::from_static("*"),
    );
    h.insert(
        axum::http::header::ACCESS_CONTROL_ALLOW_METHODS,
        axum::http::HeaderValue::from_static("GET, HEAD, OPTIONS"),
    );
    h.insert(
        axum::http::header::ACCESS_CONTROL_ALLOW_HEADERS,
        axum::http::HeaderValue::from_static("Range, Origin, Accept, Content-Type"),
    );
    h.insert(
        axum::http::header::ACCESS_CONTROL_EXPOSE_HEADERS,
        axum::http::HeaderValue::from_static("Content-Length, Content-Range, Accept-Ranges"),
    );
    h.insert(
        axum::http::header::HeaderName::from_static("cross-origin-resource-policy"),
        axum::http::HeaderValue::from_static("cross-origin"),
    );
    res
}

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

    // Phase C3a: device registration and keepalive, native. The listing
    // (`GET /api/devices`) and rename/delete stay proxied until auth is
    // ported, because their admin gate depends on the Google session that
    // lives in /auth/*. Static segments take routing priority over the
    // catch-all proxy below, so both can coexist.
    let device_routes = Router::new()
        .route(
            "/api/devices/heartbeat",
            axum::routing::post(routes::devices::heartbeat_handler)
                .get(routes::devices::heartbeat_handler)
                .options(routes::devices::heartbeat_handler),
        )
        .route(
            "/api/devices/client-hints",
            axum::routing::post(routes::devices::client_hints_handler)
                .options(routes::devices::client_hints_handler),
        )
        .with_state(routes::devices::DeviceState {
            pool: Arc::new(pool.clone()),
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
        .merge(device_routes)
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

    // Path-scoped, deliberately NOT a blanket CorsLayer - see `receiver_cors`.
    app.layer(axum::middleware::from_fn(receiver_cors))
        .layer(TraceLayer::new_for_http())
}
