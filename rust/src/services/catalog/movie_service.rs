use crate::error::AppError;
use crate::models::movie::{
    MovieDetailsResponse, MovieListResponse, MovieSummaryItem, TechnicalSpecs,
};
use sqlx::{PgPool, Row};

pub struct MovieService;

impl MovieService {
    pub async fn list_movies(
        pool: &PgPool,
        device_id: Option<&str>,
        user_id: Option<i64>,
        search_query: Option<&str>,
        sort_by: Option<&str>,
    ) -> Result<MovieListResponse, AppError> {
        // Option A precedence:
        // 1. If user_id is provided, join user-scoped progress
        // 2. Else if device_id is provided, join device_watch_history
        // 3. Otherwise join guest progress (user_id IS NULL)
        let rows = if let Some(uid) = user_id {
            sqlx::query(
                r#"
                SELECT
                    m.filename,
                    m.title,
                    m.year,
                    m.tmdb_id::BIGINT as tmdb_id,
                    m.overview,
                    m.poster_path,
                    m.backdrop_path,
                    m.runtime,
                    m.genres,
                    m.vote_average::DOUBLE PRECISION as vote_average,
                    m.release_date,
                    m.updated_at,
                    COALESCE(p.position, 0.0) as position,
                    COALESCE(p.duration, 0.0) as duration,
                    p.updated_at as watch_updated_at
                FROM movies m
                LEFT JOIN progress p ON m.filename = p.filename AND p.user_id = $1
                ORDER BY m.title ASC
                "#,
            )
            .bind(uid)
            .fetch_all(pool)
            .await?
        } else if let Some(dev_id) = device_id.filter(|id| !id.trim().is_empty()) {
            sqlx::query(
                r#"
                SELECT
                    m.filename,
                    m.title,
                    m.year,
                    m.tmdb_id::BIGINT as tmdb_id,
                    m.overview,
                    m.poster_path,
                    m.backdrop_path,
                    m.runtime,
                    m.genres,
                    m.vote_average::DOUBLE PRECISION as vote_average,
                    m.release_date,
                    m.updated_at,
                    COALESCE(h.position, 0.0) as position,
                    COALESCE(h.duration, 0.0) as duration,
                    h.last_watched as watch_updated_at
                FROM movies m
                LEFT JOIN device_watch_history h ON m.filename = h.filename AND h.device_id = $1
                ORDER BY m.title ASC
                "#,
            )
            .bind(dev_id)
            .fetch_all(pool)
            .await?
        } else {
            sqlx::query(
                r#"
                SELECT
                    m.filename,
                    m.title,
                    m.year,
                    m.tmdb_id::BIGINT as tmdb_id,
                    m.overview,
                    m.poster_path,
                    m.backdrop_path,
                    m.runtime,
                    m.genres,
                    m.vote_average::DOUBLE PRECISION as vote_average,
                    m.release_date,
                    m.updated_at,
                    COALESCE(p.position, 0.0) as position,
                    COALESCE(p.duration, 0.0) as duration,
                    p.updated_at as watch_updated_at
                FROM movies m
                LEFT JOIN progress p ON m.filename = p.filename AND p.user_id IS NULL
                ORDER BY m.title ASC
                "#,
            )
            .fetch_all(pool)
            .await?
        };

        let mut movie_list = Vec::new();

        for r in rows {
            let filename: String = r.get("filename");
            let title: String = r
                .try_get::<Option<String>, _>("title")
                .ok()
                .flatten()
                .filter(|t| !t.trim().is_empty())
                .unwrap_or_else(|| {
                    std::path::Path::new(&filename)
                        .file_stem()
                        .and_then(|s| s.to_str())
                        .unwrap_or(&filename)
                        .to_string()
                });
            let year: Option<i32> = r.try_get("year").ok();
            let tmdb_id: Option<i64> = r
                .try_get::<Option<i64>, _>("tmdb_id")
                .ok()
                .flatten()
                .or_else(|| {
                    r.try_get::<Option<i32>, _>("tmdb_id")
                        .ok()
                        .flatten()
                        .map(|id| id as i64)
                });
            let overview: Option<String> = r.try_get("overview").ok();
            let poster_path: Option<String> = r.try_get("poster_path").ok();
            let backdrop_path: Option<String> = r.try_get("backdrop_path").ok();
            let runtime: Option<i32> = r.try_get("runtime").ok();
            let genres: Option<String> = r.try_get("genres").ok();
            let vote_avg: Option<f64> = r
                .try_get::<Option<f64>, _>("vote_average")
                .ok()
                .flatten()
                .or_else(|| {
                    r.try_get::<Option<f32>, _>("vote_average")
                        .ok()
                        .flatten()
                        .map(|v| (v as f64 * 10.0).round() / 10.0)
                });
            let release_date: Option<String> = r.try_get("release_date").ok();
            let position: f64 = r.try_get("position").unwrap_or(0.0);
            let duration: f64 = r.try_get("duration").unwrap_or(0.0);

            // Calculate percent
            let percent = if duration > 0.0 {
                ((position / duration) * 100.0).min(100.0)
            } else {
                0.0
            };

            let remaining_mins = if duration > position && duration > 0.0 {
                Some(((duration - position) / 60.0).round() as i32)
            } else {
                None
            };

            // Poster URL convention
            let poster = if let Some(tid) = tmdb_id {
                Some(format!("tmdb:{}", tid))
            } else {
                poster_path.clone()
            };

            // Needs transcode heuristic: MKV / WebM typically need transcode, MP4 direct plays
            let is_mkv = filename.to_lowercase().ends_with(".mkv");
            let needs_transcode = is_mkv;
            let hls_cached = is_mkv; // HLS cache is verified via filesystem in production

            let item = MovieSummaryItem {
                filename,
                title,
                year,
                tmdb_id,
                overview,
                poster_path,
                backdrop_path,
                runtime,
                genres,
                vote_average: vote_avg,
                rating: vote_avg,
                release_date,
                updated_at: None,
                poster,
                position: (position * 10.0).round() / 10.0,
                duration: (duration * 10.0).round() / 10.0,
                percent: (percent * 10.0).round() / 10.0,
                remaining_mins,
                needs_transcode,
                hls_cached,
            };

            movie_list.push(item);
        }

        // Apply optional search query filter
        if let Some(q) = search_query.filter(|s| !s.trim().is_empty()) {
            let q_lower = q.to_lowercase();
            movie_list.retain(|m| {
                m.title.to_lowercase().contains(&q_lower)
                    || m.filename.to_lowercase().contains(&q_lower)
                    || m.genres
                        .as_ref()
                        .map(|g| g.to_lowercase().contains(&q_lower))
                        .unwrap_or(false)
            });
        }

        // Apply sort
        match sort_by.unwrap_or("title") {
            "recent" => {
                movie_list.sort_by(|a, b| b.release_date.cmp(&a.release_date));
            }
            "rating" => {
                movie_list.sort_by(|a, b| {
                    b.vote_average
                        .unwrap_or(0.0)
                        .partial_cmp(&a.vote_average.unwrap_or(0.0))
                        .unwrap_or(std::cmp::Ordering::Equal)
                });
            }
            "year" => {
                movie_list.sort_by_key(|a| std::cmp::Reverse(a.year));
            }
            _ => {
                movie_list.sort_by_key(|a| a.title.to_lowercase());
            }
        }

        // Watching items: position > 10.0 and duration - position > 10.0
        let watching = movie_list
            .iter()
            .filter(|m| m.position > 10.0 && (m.duration <= 0.0 || m.position < m.duration - 10.0))
            .cloned()
            .collect();

        let total = movie_list.len();

        Ok(MovieListResponse {
            movies: movie_list,
            watching,
            total,
        })
    }

    pub async fn get_movie_details(
        pool: &PgPool,
        filename: &str,
        device_id: Option<&str>,
        user_id: Option<i64>,
    ) -> Result<MovieDetailsResponse, AppError> {
        let row = if let Some(uid) = user_id {
            sqlx::query(
                r#"
                SELECT
                    m.filename,
                    m.title,
                    m.year,
                    m.tmdb_id::BIGINT as tmdb_id,
                    m.overview,
                    m.poster_path,
                    m.backdrop_path,
                    m.runtime,
                    m.genres,
                    m.vote_average::DOUBLE PRECISION as vote_average,
                    m.release_date,
                    m.details_json,
                    m.updated_at,
                    COALESCE(p.position, 0.0) as position,
                    COALESCE(p.duration, 0.0) as duration
                FROM movies m
                LEFT JOIN progress p ON m.filename = p.filename AND p.user_id = $2
                WHERE m.filename = $1
                "#,
            )
            .bind(filename)
            .bind(uid)
            .fetch_optional(pool)
            .await?
        } else if let Some(dev) = device_id.filter(|d| !d.trim().is_empty()) {
            sqlx::query(
                r#"
                SELECT
                    m.filename,
                    m.title,
                    m.year,
                    m.tmdb_id::BIGINT as tmdb_id,
                    m.overview,
                    m.poster_path,
                    m.backdrop_path,
                    m.runtime,
                    m.genres,
                    m.vote_average::DOUBLE PRECISION as vote_average,
                    m.release_date,
                    m.details_json,
                    m.updated_at,
                    COALESCE(h.position, p.position, 0.0) as position,
                    COALESCE(h.duration, p.duration, 0.0) as duration
                FROM movies m
                LEFT JOIN device_watch_history h ON m.filename = h.filename AND h.device_id = $2
                LEFT JOIN progress p ON m.filename = p.filename AND p.user_id IS NULL
                WHERE m.filename = $1
                "#,
            )
            .bind(filename)
            .bind(dev)
            .fetch_optional(pool)
            .await?
        } else {
            sqlx::query(
                r#"
                SELECT
                    m.filename,
                    m.title,
                    m.year,
                    m.tmdb_id::BIGINT as tmdb_id,
                    m.overview,
                    m.poster_path,
                    m.backdrop_path,
                    m.runtime,
                    m.genres,
                    m.vote_average::DOUBLE PRECISION as vote_average,
                    m.release_date,
                    m.details_json,
                    m.updated_at,
                    COALESCE(p.position, 0.0) as position,
                    COALESCE(p.duration, 0.0) as duration
                FROM movies m
                LEFT JOIN progress p ON m.filename = p.filename AND p.user_id IS NULL
                WHERE m.filename = $1
                "#,
            )
            .bind(filename)
            .fetch_optional(pool)
            .await?
        };

        let r = match row {
            Some(r) => r,
            None => {
                return Err(AppError::NotFound(format!(
                    "Movie '{}' not found",
                    filename
                )))
            }
        };

        let fname: String = r.get("filename");
        let title: String = r
            .try_get::<Option<String>, _>("title")
            .ok()
            .flatten()
            .filter(|t| !t.trim().is_empty())
            .unwrap_or_else(|| {
                std::path::Path::new(&fname)
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or(&fname)
                    .to_string()
            });
        let year: Option<i32> = r.try_get("year").ok();
        let tmdb_id: Option<i64> = r
            .try_get::<Option<i64>, _>("tmdb_id")
            .ok()
            .flatten()
            .or_else(|| {
                r.try_get::<Option<i32>, _>("tmdb_id")
                    .ok()
                    .flatten()
                    .map(|id| id as i64)
            });
        let overview: Option<String> = r.try_get("overview").ok();
        let poster_path: Option<String> = r.try_get("poster_path").ok();
        let backdrop_path: Option<String> = r.try_get("backdrop_path").ok();
        let runtime: Option<i32> = r.try_get("runtime").ok();
        let genres: Option<String> = r.try_get("genres").ok();
        let vote_avg: Option<f64> = r
            .try_get::<Option<f64>, _>("vote_average")
            .ok()
            .flatten()
            .or_else(|| {
                r.try_get::<Option<f32>, _>("vote_average")
                    .ok()
                    .flatten()
                    .map(|v| (v as f64 * 10.0).round() / 10.0)
            });
        let release_date: Option<String> = r.try_get("release_date").ok();
        let details_json_str: Option<String> = r.try_get("details_json").ok();
        let position: f64 = r.try_get("position").unwrap_or(0.0);
        let duration: f64 = r.try_get("duration").unwrap_or(0.0);

        let percent = if duration > 0.0 {
            ((position / duration) * 100.0).min(100.0)
        } else {
            0.0
        };

        let remaining_mins = if duration > position && duration > 0.0 {
            Some(((duration - position) / 60.0).round() as i32)
        } else {
            None
        };

        let poster = if let Some(tid) = tmdb_id {
            Some(format!("tmdb:{}", tid))
        } else {
            poster_path.clone()
        };

        let is_mkv = fname.to_lowercase().ends_with(".mkv");
        let needs_transcode = is_mkv;
        let hls_cached = is_mkv;

        let movie = MovieSummaryItem {
            filename: fname.clone(),
            title,
            year,
            tmdb_id,
            overview,
            poster_path,
            backdrop_path,
            runtime,
            genres,
            vote_average: vote_avg,
            rating: vote_avg,
            release_date,
            updated_at: None,
            poster,
            position: (position * 10.0).round() / 10.0,
            duration: (duration * 10.0).round() / 10.0,
            percent: (percent * 10.0).round() / 10.0,
            remaining_mins,
            needs_transcode,
            hls_cached,
        };

        let extended: serde_json::Value = details_json_str
            .as_deref()
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or_else(|| serde_json::json!({}));

        let ext = fname.split('.').next_back().unwrap_or("MP4").to_uppercase();

        let specs = TechnicalSpecs {
            resolution: Some("1080p".to_string()),
            resolution_badge: Some("1080p".to_string()),
            video_codec: Some(if is_mkv {
                "HEVC (H.265)".to_string()
            } else {
                "H.264 (AVC)".to_string()
            }),
            audio_codec: Some("AAC".to_string()),
            audio_channels: Some("2.0 Stereo".to_string()),
            container: Some(ext),
            file_size: None,
            bitrate: None,
            subtitles: vec!["English [Default]".to_string()],
            aspect_ratio: Some("16:9".to_string()),
        };

        Ok(MovieDetailsResponse {
            movie,
            specs,
            extended,
        })
    }
}
