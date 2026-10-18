use std::env;
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub database_url: String,
    pub host: String,
    pub port: u16,
    pub media_root: PathBuf,
    pub media_roots: Vec<PathBuf>,
    pub cache_dir: PathBuf,
    pub static_dir: PathBuf,
    pub flask_origin: String,
    pub base_dir: PathBuf,
    pub tmdb_api_token: Option<String>,
}

impl AppConfig {
    pub fn from_env() -> Self {
        dotenvy::dotenv().ok();

        let database_url = env::var("MEDIA_SERVER_DATABASE_URL")
            .unwrap_or_else(|_| "postgresql://postgres:postgres@127.0.0.1:5432/media_server".to_string());

        // 0.0.0.0, not 127.0.0.1.
        //
        // A loopback bind makes this service invisible to the LAN, which
        // breaks two things that are both load-bearing: a cast receiver has
        // to fetch media from this host (it answers `SetAVTransportURI` with an
        // empty HTTP 500 when it cannot), and the Cloudflare tunnel cannot
        // reach it once this service takes ownership of :8000.
        //
        // This default was wrong and the symptom was invisible from the
        // development host, because every test goes through 127.0.0.1.
        let host = env::var("RUST_HOST")
            .or_else(|_| env::var("HOST"))
            .unwrap_or_else(|_| "0.0.0.0".to_string());

        let port = env::var("RUST_PORT")
            .or_else(|_| env::var("PORT"))
            .ok()
            .and_then(|p| p.parse::<u16>().ok())
            .unwrap_or(8000);

        let media_root = env::var("MEDIA_SERVER_MEDIA_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("D:\\Flicks"));

        let mut media_roots = Vec::new();
        if let Ok(roots_env) = env::var("MEDIA_SERVER_MEDIA_ROOTS") {
            for r in roots_env.split(',') {
                let trimmed = r.trim();
                if !trimmed.is_empty() {
                    media_roots.push(PathBuf::from(trimmed));
                }
            }
        }
        if media_roots.is_empty() {
            media_roots.push(media_root.clone());
            let archive_dir = media_root.join(".archive");
            if archive_dir.exists() {
                media_roots.push(archive_dir);
            }
        }

        let cache_dir = env::var("MEDIA_SERVER_CACHE_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("E:\\MediaServer\\cache"));

        let static_dir = env::var("MEDIA_SERVER_STATIC_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                let rel_dist = PathBuf::from("web/dist");
                if rel_dist.exists() {
                    rel_dist
                } else {
                    PathBuf::from("E:\\MediaServer\\web\\dist")
                }
            });

        let flask_origin = env::var("FLASK_ORIGIN")
            .or_else(|_| env::var("MEDIA_SERVER_FLASK_ORIGIN"))
            .unwrap_or_else(|_| "http://127.0.0.1:8000".to_string());

        let base_dir = env::var("MEDIA_SERVER_BASE_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                env::current_dir().unwrap_or_else(|_| PathBuf::from("E:\\MediaServer"))
            });

        let tmdb_api_token = env::var("TMDB_API_TOKEN")
            .ok()
            .map(|t| t.trim().trim_matches(|c| c == '"' || c == '\'').to_string())
            .filter(|t| !t.is_empty());

        Self {
            database_url,
            host,
            port,
            media_root,
            media_roots,
            cache_dir,
            static_dir,
            flask_origin,
            base_dir,
            tmdb_api_token,
        }
    }
}
