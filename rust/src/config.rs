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
}

impl AppConfig {
    pub fn from_env() -> Self {
        dotenvy::dotenv().ok();

        let database_url = env::var("MEDIA_SERVER_DATABASE_URL")
            .unwrap_or_else(|_| "postgresql://postgres:postgres@127.0.0.1:5432/media_server".to_string());

        let host = env::var("RUST_HOST")
            .or_else(|_| env::var("HOST"))
            .unwrap_or_else(|_| "127.0.0.1".to_string());

        let port = env::var("RUST_PORT")
            .or_else(|_| env::var("PORT"))
            .ok()
            .and_then(|p| p.parse::<u16>().ok())
            .unwrap_or(8001);

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
            media_roots.push(archive_dir);
            let app_root = PathBuf::from("E:\\MediaServer");
            if !media_roots.contains(&app_root) {
                media_roots.push(app_root);
            }
        }

        let cache_dir = env::var("MEDIA_SERVER_CACHE_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("E:\\MediaServer\\cache"));

        Self {
            database_url,
            host,
            port,
            media_root,
            media_roots,
            cache_dir,
        }
    }
}
