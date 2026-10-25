use crate::error::AppError;
use sqlx::PgPool;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::Mutex as AsyncMutex;

/// Which artwork an id refers to. The two differ in cache directory and in
/// the size requested from TMDb, so they are distinct keys throughout.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ArtworkKind {
    Poster,
    Backdrop,
}

impl ArtworkKind {
    fn cache_dir(&self) -> &'static str {
        match self {
            ArtworkKind::Poster => "posters",
            ArtworkKind::Backdrop => "backdrops",
        }
    }

    /// The image size Flask requests (`posters.py`: w1280 for backdrops,
    /// w500 for posters). Changing this changes the cached bytes, so it is
    /// pinned to Flask's values rather than "picked".
    fn tmdb_size(&self) -> &'static str {
        match self {
            ArtworkKind::Poster => "w500",
            ArtworkKind::Backdrop => "w1280",
        }
    }

    fn column(&self) -> &'static str {
        match self {
            ArtworkKind::Poster => "poster_path",
            ArtworkKind::Backdrop => "backdrop_path",
        }
    }
}

/// Flask refuses to serve a cache file at or below this size
/// (`posters.py`: `st_size > 1000`). Reproduced exactly, because a truncated
/// file that slips past this guard is cached by every client forever.
const MIN_CACHE_BYTES: u64 = 1000;

const MAX_ATTEMPTS: u32 = 3;
const REQUEST_TIMEOUT_SECS: u64 = 10;
const TMDB_IMAGE_BASE: &str = "https://image.tmdb.org/t/p";

/// Base for TMDb image requests, overridable so tests can point at a local
/// mock. Read per call rather than cached: the override is set by tests at
/// runtime, and a cached value would make them silently hit the real CDN.
fn image_base() -> String {
    std::env::var("TMDB_ARTWORK_BASE_URL").unwrap_or_else(|_| TMDB_IMAGE_BASE.to_string())
}

/// Per-artwork locks, so N concurrent requests for one id cause one download.
///
/// This is not about TMDb tolerating load - measured: 420 requests across 70
/// distinct assets at concurrency 12, zero failures. It is that 12 cards
/// showing the same title would otherwise each pull the identical ~120 KB.
/// Waiters queue, then find the file in cache.
fn key_locks() -> &'static Mutex<HashMap<(ArtworkKind, i64), Arc<AsyncMutex<()>>>> {
    static LOCKS: OnceLock<Mutex<HashMap<(ArtworkKind, i64), Arc<AsyncMutex<()>>>>> =
        OnceLock::new();
    LOCKS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn client() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            // Flask used a 30s timeout with 5 attempts and `attempt * 3`
            // backoff, which can hold one request for ~3 minutes against a
            // CDN that answers in ~0.5s. Measured p95 was 0.66s, so 10s is
            // generous, and 3 attempts keeps the worst case near 36s rather
            // than stalling a browser image request past a proxy timeout.
            .timeout(Duration::from_secs(REQUEST_TIMEOUT_SECS))
            .user_agent("Mozilla/5.0")
            .build()
            .expect("reqwest client")
    })
}

pub struct TmdbArtworkService;

impl TmdbArtworkService {
    /// Resolve TMDb artwork for `tmdb_id`, downloading on demand.
    ///
    /// Order matches Flask: serve from cache if a usable file exists, else
    /// look the TMDb path up in the database, else download.
    pub async fn get(
        pool: &PgPool,
        cache_dir: &PathBuf,
        tmdb_id: i64,
        kind: ArtworkKind,
    ) -> Result<PathBuf, AppError> {
        if tmdb_id < 0 {
            return Err(AppError::NotFound("Invalid artwork id".to_string()));
        }

        let dir = cache_dir.join(kind.cache_dir());
        let target = dir.join(format!("{}.jpg", tmdb_id));

        if cached(&target) {
            return Ok(target);
        }

        let lock = {
            let mut map = key_locks()
                .lock()
                .map_err(|_| AppError::Internal("artwork lock poisoned".to_string()))?;
            map.entry((kind, tmdb_id))
                .or_insert_with(|| Arc::new(AsyncMutex::new(())))
                .clone()
        };
        let _guard = lock.lock().await;

        // Re-check under the lock: whoever held it may have just downloaded.
        if cached(&target) {
            return Ok(target);
        }

        // Flask's query is by tmdb_id and column; a missing row or empty
        // column means "no artwork", which is a 404, not an error.
        let sql = format!(
            "SELECT {} AS art FROM movies WHERE tmdb_id = $1",
            kind.column()
        );
        let art_path: Option<String> = sqlx::query_scalar(&sql)
            .bind(tmdb_id)
            .fetch_optional(pool)
            .await?
            .flatten();

        let art_path = match art_path {
            Some(p) if !p.trim().is_empty() => p,
            _ => {
                return Err(AppError::NotFound(format!(
                    "No {} recorded for tmdb_id {}",
                    kind.column(),
                    tmdb_id
                )))
            }
        };

        tokio::fs::create_dir_all(&dir)
            .await
            .map_err(|e| AppError::Internal(e.to_string()))?;

        match download(&art_path, kind, &target).await {
            true => Ok(target),
            // Flask swallows every download failure and answers 404, so a
            // host that cannot reach TMDb looks exactly like a host missing
            // the artwork. Reproduced deliberately.
            false => Err(AppError::NotFound(format!(
                "Artwork download failed for tmdb_id {}",
                tmdb_id
            ))),
        }
    }
}

fn cached(path: &PathBuf) -> bool {
    std::fs::metadata(path)
        .map(|m| m.is_file() && m.len() > MIN_CACHE_BYTES)
        .unwrap_or(false)
}

/// Download to a temporary file and rename into place.
///
/// Flask writes straight to `{id}.jpg`, so a download that dies halfway
/// leaves a truncated file sitting at the final name - and because the read
/// guard only rejects files at or below 1 KB, a 60 KB half-image passes and
/// is served (and cached) by every client, permanently. Renaming on the same
/// volume is atomic, so the final name holds either nothing or a complete
/// image.
async fn download(art_path: &str, kind: ArtworkKind, target: &PathBuf) -> bool {
    let url = format!("{}/{}{}", image_base(), kind.tmdb_size(), art_path);
    let temp = target.with_extension(format!("jpg.tmp-{}", std::process::id()));

    let mut delay = 2u64;
    for attempt in 1..=MAX_ATTEMPTS {
        match client().get(&url).header("Accept", "image/*").send().await {
            Ok(resp) if resp.status().is_success() => {
                match resp.bytes().await {
                    Ok(bytes) if bytes.len() as u64 > MIN_CACHE_BYTES => {
                        // Write then rename; never leave a partial file at
                        // the final name.
                        if tokio::fs::write(&temp, &bytes).await.is_ok()
                            && tokio::fs::rename(&temp, target).await.is_ok()
                        {
                            return true;
                        }
                        let _ = tokio::fs::remove_file(&temp).await;
                    }
                    other => {
                        tracing::warn!(
                            "tmdb artwork {} attempt {} rejected ({} bytes)",
                            art_path,
                            attempt,
                            other
                                .map(|b| b.len())
                                .unwrap_or(0)
                        );
                    }
                }
            }
            Ok(resp) => {
                tracing::warn!(
                    "tmdb artwork {} attempt {} -> HTTP {}",
                    art_path,
                    attempt,
                    resp.status()
                );
            }
            Err(e) => {
                tracing::warn!("tmdb artwork {} attempt {} -> {}", art_path, attempt, e);
            }
        }

        if attempt < MAX_ATTEMPTS {
            tokio::time::sleep(Duration::from_secs(delay)).await;
            delay += 2;
        }
    }

    let _ = tokio::fs::remove_file(&temp).await;
    false
}