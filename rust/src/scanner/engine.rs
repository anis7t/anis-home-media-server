use super::models::TmdbMovieDetails;
use super::parser::FilenameParser;
use super::tmdb_client::TmdbClient;
use crate::error::AppError;
use crate::services::path_resolver::PathResolver;
use crate::services::probe_service::ProbeService;
use crate::services::tmdb_artwork::{ArtworkKind, TmdbArtworkService};
use sqlx::PgPool;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tracing::{debug, error, info, warn};
use walkdir::WalkDir;

const VIDEO_EXTENSIONS: &[&str] = &[".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v"];

#[derive(Debug, Clone, Default)]
pub struct ScannerReport {
    pub files_discovered: usize,
    pub unindexed_discovered: usize,
    pub movies_indexed: usize,
    pub movies_updated: usize,
    pub orphans_pruned: usize,
    pub errors: usize,
}

pub struct ScannerEngine;

impl ScannerEngine {
    /// Check whether a path has a supported video extension.
    pub fn is_video_file(path: &Path) -> bool {
        if let Some(file_name) = path.file_name().and_then(|f| f.to_str()) {
            let lower = file_name.to_lowercase();
            if lower.starts_with("chunk_") || lower.starts_with("init_chunk_") || lower.ends_with(".m4s") {
                return false;
            }
        }
        path.extension()
            .and_then(|ext| ext.to_str())
            .map(|ext| {
                let lower = format!(".{}", ext.to_lowercase());
                VIDEO_EXTENSIONS.contains(&lower.as_str())
            })
            .unwrap_or(false)
    }

    /// Compute sanitized canonical relative path from media roots (using forward slashes).
    pub fn compute_relative_path(path: &Path, roots: &[PathBuf]) -> String {
        for root in roots {
            if let Ok(rel) = path.strip_prefix(root) {
                let s = rel.to_string_lossy().replace('\\', "/");
                let clean = s.trim_start_matches('/');
                if !clean.is_empty() {
                    return clean.to_string();
                }
            }
        }
        path.file_name()
            .map(|f| f.to_string_lossy().replace('\\', "/"))
            .unwrap_or_default()
    }

    /// Crawl all configured media roots and discover physical video files.
    pub fn discover_video_files(roots: &[PathBuf]) -> Vec<PathBuf> {
        let mut discovered = Vec::new();
        let mut seen = HashSet::new();

        for root in roots {
            if !root.exists() {
                continue;
            }

            for entry in WalkDir::new(root)
                .follow_links(false)
                .into_iter()
                .filter_entry(|e| {
                    let file_name = e.file_name().to_string_lossy();
                    // Skip temporary uploads, deleted bins, caches, node modules, build targets, and git
                    file_name != ".uploads"
                        && file_name != ".deleted"
                        && file_name != "cache"
                        && file_name != ".git"
                        && file_name != "target"
                        && file_name != "node_modules"
                        && file_name != ".venv"
                })
                .filter_map(|e| e.ok())
            {
                let path = entry.path();
                if path.is_file() && Self::is_video_file(path) {
                    if let Ok(canon) = path.canonicalize() {
                        if seen.insert(canon.clone()) {
                            discovered.push(canon);
                        }
                    } else if seen.insert(path.to_path_buf()) {
                        discovered.push(path.to_path_buf());
                    }
                }
            }
        }

        discovered.sort();
        discovered
    }

    /// Reconcile and prune orphaned database rows for files no longer present on disk.
    ///
    /// Implements Decision 1A (Strict Reconciliation).
    pub async fn reconcile_orphans(pool: &PgPool, roots: &[PathBuf]) -> Result<usize, AppError> {
        let rows = sqlx::query_as::<_, (String,)>("SELECT filename FROM movies")
            .fetch_all(pool)
            .await
            .map_err(AppError::Database)?;

        let mut pruned = 0;
        for (filename,) in rows {
            // Verify if the file still exists in any media root
            if PathResolver::resolve_media_path(&filename, roots).is_err() {
                info!("Pruning orphaned movie record from database: {}", filename);
                let res = sqlx::query("DELETE FROM movies WHERE filename = $1")
                    .bind(&filename)
                    .execute(pool)
                    .await;

                if let Ok(r) = res {
                    if r.rows_affected() > 0 {
                        pruned += 1;
                        // Also cleanup associated watch history and progress if any
                        let _ = sqlx::query("DELETE FROM progress WHERE filename = $1")
                            .bind(&filename)
                            .execute(pool)
                            .await;
                    }
                }
            }
        }

        Ok(pruned)
    }

    /// Execute a full library scan across all configured media roots.
    pub async fn scan(
        pool: &PgPool,
        roots: &[PathBuf],
        cache_dir: &Path,
        tmdb_token: Option<&str>,
    ) -> Result<ScannerReport, AppError> {
        let mut report = ScannerReport::default();
        let cache_dir_buf = cache_dir.to_path_buf();

        info!("Starting native library scan across {} media root(s)...", roots.len());

        // 1. Reconcile orphans first (Decision 1A)
        match Self::reconcile_orphans(pool, roots).await {
            Ok(count) => {
                report.orphans_pruned = count;
                if count > 0 {
                    info!("Strict reconciliation pruned {} orphaned movie(s)", count);
                }
            }
            Err(e) => {
                error!("Failed to reconcile orphaned movies: {}", e);
                report.errors += 1;
            }
        }

        // 2. Discover physical video files on disk
        let files = Self::discover_video_files(roots);
        report.files_discovered = files.len();
        info!("Discovered {} total video file(s) across media roots", files.len());

        // 3. Query existing indexed filenames from PostgreSQL
        let indexed_rows = sqlx::query_as::<_, (String,)>("SELECT filename FROM movies")
            .fetch_all(pool)
            .await
            .map_err(AppError::Database)?;

        let indexed_set: HashSet<String> = indexed_rows.into_iter().map(|(f,)| f).collect();

        // 4. Determine unindexed files
        let mut unindexed = Vec::new();
        for file in files {
            let rel = Self::compute_relative_path(&file, roots);
            let file_name = file
                .file_name()
                .map(|f| f.to_string_lossy().to_string())
                .unwrap_or_default();

            if !indexed_set.contains(&rel) && !indexed_set.contains(&file_name) {
                unindexed.push((file, rel));
            }
        }

        report.unindexed_discovered = unindexed.len();
        if unindexed.is_empty() {
            info!("All discovered media files are already indexed. Scan complete.");
            return Ok(report);
        }

        info!("Found {} unindexed video file(s) to ingest", unindexed.len());

        // 5. Initialize TMDb client if token is available
        let tmdb_client = tmdb_token.map(|t| TmdbClient::new(t.to_string()));
        if tmdb_client.is_none() {
            warn!("TMDB_API_TOKEN is not configured; unindexed movies will be added with fallback metadata.");
        }

        let total_unindexed = unindexed.len();
        for (idx, (path, relative)) in unindexed.into_iter().enumerate() {
            let (title, year) = FilenameParser::parse_filename(&path);
            let now_ts = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs() as i64;

            info!(
                "[{}/{}] Ingesting: {} (detected title: '{}', year: {:?})",
                idx + 1,
                total_unindexed,
                relative,
                title,
                year
            );

            let mut tmdb_details: Option<TmdbMovieDetails> = None;
            let is_anon = FilenameParser::is_anonymous_name(&title);

            if !is_anon {
                if let Some(ref client) = tmdb_client {
                    match client.search_movie(&title, year).await {
                        Ok(Some(matched_movie)) => {
                            debug!("TMDb matched: ID {} ({:?})", matched_movie.id, matched_movie.title);
                            match client.get_movie_details(matched_movie.id).await {
                                Ok(details) => {
                                    tmdb_details = Some(details);
                                }
                                Err(err) => {
                                    warn!("Failed to fetch TMDb details for ID {}: {}", matched_movie.id, err);
                                    report.errors += 1;
                                }
                            }
                        }
                        Ok(None) => {
                            info!("No TMDb match found for '{}' ({:?})", title, year);
                        }
                        Err(err) => {
                            warn!("TMDb search failed for '{}': {}", title, err);
                            report.errors += 1;
                        }
                    }
                }
            } else {
                info!("Filename '{}' classified as anonymous stem; skipping TMDb lookup.", title);
            }

            // Extract or fallback runtime (Decision 2A)
            let (final_title, final_year, tmdb_id, overview, poster_path, backdrop_path, mut runtime, genres, vote_avg, release_date, details_json) =
                if let Some(details) = tmdb_details {
                    let d_title = details.title.clone().unwrap_or(title);
                    let d_rel_date = details.release_date.clone().unwrap_or_default();
                    let d_year = d_rel_date
                        .get(..4)
                        .and_then(|y| y.parse::<i32>().ok())
                        .or(year);
                    let d_genres = details
                        .genres
                        .iter()
                        .map(|g| g.name.clone())
                        .collect::<Vec<_>>()
                        .join(", ");
                    let d_json = TmdbClient::build_details_json(&details);
                    let d_runtime = details.runtime.unwrap_or(0);

                    (
                        d_title,
                        d_year,
                        Some(details.id),
                        details.overview.clone().unwrap_or_default(),
                        details.poster_path.clone().unwrap_or_default(),
                        details.backdrop_path.clone().unwrap_or_default(),
                        d_runtime,
                        d_genres,
                        details.vote_average.unwrap_or(0.0),
                        d_rel_date,
                        d_json,
                    )
                } else {
                    (
                        title.clone(),
                        year,
                        None,
                        "No TMDB metadata found".to_string(),
                        "".to_string(),
                        "".to_string(),
                        0,
                        "".to_string(),
                        0.0,
                        year.map(|y| y.to_string()).unwrap_or_default(),
                        "{}".to_string(),
                    )
                };

            // Decision 2A: Fall back to ffprobe stream container duration if runtime is 0
            if runtime <= 0 {
                let video_dur_sec = ProbeService::source_video_duration(&path).await;
                if video_dur_sec > 0.0 {
                    runtime = (video_dur_sec / 60.0).round() as i64;
                    debug!("Probed container runtime for '{}': {} min", relative, runtime);
                }
            }

            // Database Upsert
            let upsert_res = sqlx::query(
                r#"
                INSERT INTO movies (
                    filename, title, year, tmdb_id, overview, poster_path, backdrop_path,
                    runtime, genres, vote_average, updated_at, release_date, details_json, last_metadata_refresh
                )
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
                ON CONFLICT (filename) DO UPDATE SET
                    title = EXCLUDED.title,
                    year = EXCLUDED.year,
                    tmdb_id = EXCLUDED.tmdb_id,
                    overview = EXCLUDED.overview,
                    poster_path = EXCLUDED.poster_path,
                    backdrop_path = EXCLUDED.backdrop_path,
                    runtime = EXCLUDED.runtime,
                    genres = EXCLUDED.genres,
                    vote_average = EXCLUDED.vote_average,
                    updated_at = EXCLUDED.updated_at,
                    release_date = EXCLUDED.release_date,
                    details_json = EXCLUDED.details_json,
                    last_metadata_refresh = EXCLUDED.last_metadata_refresh
                "#
            )
            .bind(&relative)
            .bind(&final_title)
            .bind(final_year)
            .bind(tmdb_id)
            .bind(&overview)
            .bind(&poster_path)
            .bind(&backdrop_path)
            .bind(runtime)
            .bind(&genres)
            .bind(vote_avg)
            .bind(now_ts)
            .bind(&release_date)
            .bind(&details_json)
            .bind(now_ts)
            .execute(pool)
            .await;

            match upsert_res {
                Ok(_) => {
                    report.movies_indexed += 1;
                    info!("Successfully indexed '{}' ({:?})", final_title, final_year);

                    // Download and cache artwork asynchronously if present
                    if let Some(id) = tmdb_id {
                        if !poster_path.is_empty() {
                            let _ = TmdbArtworkService::get(pool, &cache_dir_buf, id, ArtworkKind::Poster).await;
                        }
                        if !backdrop_path.is_empty() {
                            let _ = TmdbArtworkService::get(pool, &cache_dir_buf, id, ArtworkKind::Backdrop).await;
                        }
                    }
                }
                Err(err) => {
                    error!("Database error indexing '{}': {}", relative, err);
                    report.errors += 1;
                }
            }

            // Polite delay between consecutive TMDb lookups
            if idx + 1 < total_unindexed && tmdb_client.is_some() {
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        }

        info!(
            "Scan complete. Discovered: {}, Indexed: {}, Pruned: {}, Errors: {}",
            report.files_discovered, report.movies_indexed, report.orphans_pruned, report.errors
        );

        Ok(report)
    }
}
