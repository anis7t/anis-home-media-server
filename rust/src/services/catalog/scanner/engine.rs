use super::models::TmdbMovieDetails;
use super::parser::FilenameParser;
use super::tmdb_client::TmdbClient;
use crate::error::AppError;
use crate::services::path_resolver::PathResolver;
use crate::services::probe_service::ProbeService;
use crate::services::subtitle_service::SubtitleService;
use crate::services::tmdb_artwork::{ArtworkKind, TmdbArtworkService};
use sqlx::PgPool;
use std::collections::{HashMap, HashSet};
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
    pub subtitles_acquired: usize,
    pub errors: usize,
}

pub struct ScannerEngine;

impl ScannerEngine {
    /// Whether a filename is an HLS fMP4 initialization asset rather than a
    /// library title. These can be left behind by older scans in a media root.
    pub fn is_hls_init_artifact(path: &Path) -> bool {
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            return false;
        };
        let lower = name.to_ascii_lowercase();
        if lower == "init.mp4" {
            return true;
        }

        // Older HLS test runs left initialization fixtures at the media-root
        // level (for example `init_1.mp4` and `init_copyts.mp4`). Keep the
        // boundary at `init_` so legitimate titles such as `Initial D.mp4`
        // remain eligible for the library.
        if lower
            .strip_prefix("init_")
            .is_some_and(|suffix| suffix.ends_with(".mp4") && suffix.len() > 4)
        {
            return true;
        }

        lower
            .strip_prefix("init_chunk_")
            .and_then(|rest| rest.strip_suffix(".mp4"))
            .is_some_and(|number| {
                !number.is_empty() && number.bytes().all(|byte| byte.is_ascii_digit())
            })
    }

    /// Check whether a path has a supported video extension.
    pub fn is_video_file(path: &Path) -> bool {
        if Self::is_hls_init_artifact(path) {
            return false;
        }
        if let Some(file_name) = path.file_name().and_then(|f| f.to_str()) {
            let lower = file_name.to_lowercase();
            if lower.starts_with("chunk_")
                || lower.starts_with("init_chunk_")
                || lower.ends_with(".m4s")
            {
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
                    // Skip temporary uploads, deleted bins, caches, backups, node modules, build targets, and git
                    file_name != ".uploads"
                        && file_name != ".deleted"
                        && file_name != ".backups"
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
            if Self::is_hls_init_artifact(Path::new(&filename)) {
                info!(
                    "Pruning HLS initialization artifact from catalog: {}",
                    filename
                );
                let mut tx = pool.begin().await.map_err(AppError::Database)?;
                sqlx::query("DELETE FROM progress WHERE filename = $1")
                    .bind(&filename)
                    .execute(&mut *tx)
                    .await
                    .map_err(AppError::Database)?;
                sqlx::query("DELETE FROM device_watch_history WHERE filename = $1")
                    .bind(&filename)
                    .execute(&mut *tx)
                    .await
                    .map_err(AppError::Database)?;
                let deleted = sqlx::query("DELETE FROM movies WHERE filename = $1")
                    .bind(&filename)
                    .execute(&mut *tx)
                    .await
                    .map_err(AppError::Database)?;
                tx.commit().await.map_err(AppError::Database)?;
                pruned += deleted.rows_affected() as usize;
                continue;
            }

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

        info!(
            "Starting native library scan across {} media root(s)...",
            roots.len()
        );

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
        info!(
            "Discovered {} total video file(s) across media roots",
            files.len()
        );

        // 3. Query existing indexed filenames from PostgreSQL
        let indexed_rows = sqlx::query_as::<
            _,
            (
                String,
                Option<i64>,
                Option<String>,
                Option<String>,
                Option<i64>,
                Option<i64>,
            ),
        >(
            "SELECT filename, tmdb_id::BIGINT as tmdb_id, title, overview, last_metadata_refresh, added_at FROM movies",
        )
        .fetch_all(pool)
        .await
        .map_err(AppError::Database)?;

        let mut indexed_set: HashSet<String> = HashSet::new();
        let mut incomplete_map: HashMap<String, Option<String>> = HashMap::new();

        let now_sec = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;

        for (f, tid, t, ov, lmr, added_at) in indexed_rows {
            // Backfill legacy catalog rows from the actual media file time.
            // `added_at` is immutable after this point and is not the metadata
            // refresh timestamp (`updated_at`).
            if added_at.is_none() {
                if let Ok(path) = PathResolver::resolve_media_path(&f, roots) {
                    if let Some(timestamp) = Self::file_modified_timestamp(&path) {
                        let _ = sqlx::query(
                            "UPDATE movies SET added_at = $2 WHERE filename = $1 AND added_at IS NULL",
                        )
                        .bind(&f)
                        .bind(timestamp)
                        .execute(pool)
                        .await;
                    }
                }
            }
            if tid.is_some() {
                indexed_set.insert(f);
            } else {
                // If it was already scanned and confirmed to have no TMDb metadata within the last 4 hours,
                // treat as indexed to avoid hammering TMDb on every routine scan.
                let recently_checked = ov.as_deref() == Some("No TMDB metadata found")
                    && lmr.unwrap_or(0) > 0
                    && (now_sec - lmr.unwrap_or(0)) < 14400;

                if recently_checked {
                    indexed_set.insert(f);
                } else {
                    incomplete_map.insert(f, t);
                }
            }
        }

        // 4. Determine unindexed files (completely new files, or pre-inserted uploads missing tmdb_id)
        let mut unindexed = Vec::new();
        for file in files {
            let rel = Self::compute_relative_path(&file, roots);
            let file_name = file
                .file_name()
                .map(|f| f.to_string_lossy().to_string())
                .unwrap_or_default();

            let is_indexed = indexed_set.contains(&rel) || indexed_set.contains(&file_name);
            let existing_title = incomplete_map
                .get(&rel)
                .or_else(|| incomplete_map.get(&file_name))
                .cloned()
                .flatten();

            if !is_indexed
                || incomplete_map.contains_key(&rel)
                || incomplete_map.contains_key(&file_name)
            {
                unindexed.push((file, rel, existing_title));
            }
        }

        report.unindexed_discovered = unindexed.len();
        if unindexed.is_empty() {
            info!("All discovered media files are already indexed. Sweeping subtitles for existing movies...");
            let swept = Self::proactive_subtitle_sweep(pool, roots, &cache_dir_buf).await;
            report.subtitles_acquired += swept;
            info!(
                "Scan complete. Discovered: {}, Swept Subtitles: {}, Pruned: {}, Errors: {}",
                report.files_discovered,
                report.subtitles_acquired,
                report.orphans_pruned,
                report.errors
            );
            return Ok(report);
        }

        info!(
            "Found {} unindexed video file(s) to ingest",
            unindexed.len()
        );

        // 5. Initialize TMDb client if token is available
        let tmdb_client = tmdb_token.map(|t| TmdbClient::new(t.to_string()));
        if tmdb_client.is_none() {
            warn!("TMDB_API_TOKEN is not configured; unindexed movies will be added with fallback metadata.");
        }

        let total_unindexed = unindexed.len();
        for (idx, (path, relative, existing_title)) in unindexed.into_iter().enumerate() {
            let (title, year) = FilenameParser::parse_filename(&path);
            let now_ts = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs() as i64;
            let added_at = Self::file_modified_timestamp(&path).unwrap_or(now_ts);

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
                            debug!(
                                "TMDb matched: ID {} ({:?})",
                                matched_movie.id, matched_movie.title
                            );
                            match client.get_movie_details(matched_movie.id).await {
                                Ok(details) => {
                                    tmdb_details = Some(details);
                                }
                                Err(err) => {
                                    warn!(
                                        "Failed to fetch TMDb details for ID {}: {}",
                                        matched_movie.id, err
                                    );
                                    report.errors += 1;
                                }
                            }
                        }
                        Ok(None) => {
                            info!("No TMDb match found for '{}' ({:?})", title, year);
                            if let Some(ref alt_title) = existing_title {
                                if alt_title != &title
                                    && !FilenameParser::is_anonymous_name(alt_title)
                                {
                                    debug!(
                                        "Retrying TMDb search with alternative title: '{}'",
                                        alt_title
                                    );
                                    if let Ok(Some(alt_match)) =
                                        client.search_movie(alt_title, year).await
                                    {
                                        if let Ok(details) =
                                            client.get_movie_details(alt_match.id).await
                                        {
                                            tmdb_details = Some(details);
                                        }
                                    }
                                }
                            }
                        }
                        Err(err) => {
                            warn!("TMDb search failed for '{}': {}", title, err);
                            report.errors += 1;
                        }
                    }
                }
            } else {
                info!(
                    "Filename '{}' classified as anonymous stem; skipping TMDb lookup.",
                    title
                );
            }

            // Extract or fallback runtime (Decision 2A)
            let (
                final_title,
                final_year,
                tmdb_id,
                overview,
                poster_path,
                backdrop_path,
                mut runtime,
                genres,
                vote_avg,
                release_date,
                details_json,
            ) = if let Some(details) = tmdb_details {
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
                    existing_title.unwrap_or_else(|| title.clone()),
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
                    debug!(
                        "Probed container runtime for '{}': {} min",
                        relative, runtime
                    );
                }
            }

            // Database Upsert
            let upsert_res = sqlx::query(
                r#"
                INSERT INTO movies (
                    filename, title, year, tmdb_id, overview, poster_path, backdrop_path,
                    runtime, genres, vote_average, updated_at, release_date, details_json, last_metadata_refresh, added_at
                )
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
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
                    last_metadata_refresh = EXCLUDED.last_metadata_refresh,
                    added_at = COALESCE(movies.added_at, EXCLUDED.added_at)
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
            .bind(added_at)
            .execute(pool)
            .await;

            match upsert_res {
                Ok(_) => {
                    report.movies_indexed += 1;
                    info!("Successfully indexed '{}' ({:?})", final_title, final_year);

                    // Download and cache artwork asynchronously if present
                    if let Some(id) = tmdb_id {
                        if !poster_path.is_empty() {
                            let _ = TmdbArtworkService::get(
                                pool,
                                &cache_dir_buf,
                                id,
                                ArtworkKind::Poster,
                            )
                            .await;
                        }
                        if !backdrop_path.is_empty() {
                            let _ = TmdbArtworkService::get(
                                pool,
                                &cache_dir_buf,
                                id,
                                ArtworkKind::Backdrop,
                            )
                            .await;
                        }
                    }

                    // Proactively acquire subtitles if movie lacks English subtitles
                    if SubtitleService::ensure_subtitles_for_movie(
                        &path,
                        &relative,
                        &final_title,
                        roots,
                        &cache_dir_buf,
                    )
                    .await
                    {
                        report.subtitles_acquired += 1;
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

        // Polite proactive sweep for remaining library movies lacking subtitles (Option A)
        let swept = Self::proactive_subtitle_sweep(pool, roots, &cache_dir_buf).await;
        report.subtitles_acquired += swept;

        info!(
            "Scan complete. Discovered: {}, Indexed: {}, Subtitles Acquired: {}, Pruned: {}, Errors: {}",
            report.files_discovered, report.movies_indexed, report.subtitles_acquired, report.orphans_pruned, report.errors
        );

        Ok(report)
    }

    fn file_modified_timestamp(path: &Path) -> Option<i64> {
        std::fs::metadata(path)
            .ok()?
            .modified()
            .ok()?
            .duration_since(UNIX_EPOCH)
            .ok()
            .map(|duration| duration.as_secs() as i64)
    }

    /// Polite background sweep to proactively acquire missing English subtitles
    /// for existing movies in the database (Option A).
    pub async fn proactive_subtitle_sweep(
        pool: &PgPool,
        roots: &[PathBuf],
        cache_dir: &Path,
    ) -> usize {
        let rows = match sqlx::query_as::<_, (String, String)>(
            "SELECT filename, title FROM movies ORDER BY updated_at DESC",
        )
        .fetch_all(pool)
        .await
        {
            Ok(r) => r,
            Err(e) => {
                warn!("Proactive subtitle sweep: failed to query movies: {}", e);
                return 0;
            }
        };

        let mut acquired = 0;
        let total = rows.len();
        debug!(
            "Proactive subtitle sweep: checking {} existing movies for missing English subtitles",
            total
        );

        for (filename, title) in rows {
            let Ok(video_path) = PathResolver::resolve_media_path(&filename, roots) else {
                continue;
            };

            // Fast-path: check if English subtitles already exist
            if SubtitleService::has_english_subtitles(&video_path, &filename, roots, cache_dir)
                .await
            {
                continue;
            }

            // Missing English subtitles: attempt proactive acquisition
            if SubtitleService::ensure_subtitles_for_movie(
                &video_path,
                &filename,
                &title,
                roots,
                cache_dir,
            )
            .await
            {
                acquired += 1;
            }

            // Polite delay between consecutive OpenSubtitles calls (Option A: 500ms)
            tokio::time::sleep(Duration::from_millis(500)).await;
        }

        if acquired > 0 {
            info!(
                "Proactive subtitle sweep completed: cached subtitles for {} movie(s)",
                acquired
            );
        }
        acquired
    }
}
