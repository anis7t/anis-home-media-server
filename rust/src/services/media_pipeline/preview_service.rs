use crate::error::AppError;
use crate::models::preview::SeekPreviewMetaResponse;
use hex;
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use std::fs;
use std::path::{Path, PathBuf};

pub struct PreviewService;

impl PreviewService {
    /// Calculate deterministic SHA-256 preview cache key for a media file.
    pub fn get_preview_key(path: &Path) -> String {
        let (size, mtime_ns) = if let Ok(m) = path.metadata() {
            let size = m.len();
            let mtime = m
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            (size, mtime)
        } else {
            (0, 0)
        };

        let canon_str = path
            .canonicalize()
            .unwrap_or_else(|_| path.to_path_buf())
            .to_string_lossy()
            .to_string();

        let clean_str = canon_str.strip_prefix(r"\\?\").unwrap_or(&canon_str);
        let sig = format!("preview:{}:{}:{}", clean_str, size, mtime_ns);

        let mut hasher = Sha256::new();
        hasher.update(sig.as_bytes());
        hex::encode(hasher.finalize())
    }

    /// Resolve or create the preview cache directory for a given media file.
    pub fn get_preview_dir(path: &Path, cache_root: &Path, roots: &[PathBuf]) -> PathBuf {
        let preview_base = cache_root.join("previews");
        let primary_key = Self::get_preview_key(path);
        let primary_dir = preview_base.join(&primary_key);

        // Check for existing cache directory with thumbnails matching candidate keys
        let mut candidates = vec![primary_key];

        // Also check raw path without canonicalization
        let (size, mtime_ns) = if let Ok(m) = path.metadata() {
            let size = m.len();
            let mtime = m
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            (size, mtime)
        } else {
            (0, 0)
        };
        let raw_sig = format!("preview:{}:{}:{}", path.to_string_lossy(), size, mtime_ns);
        let mut hasher = Sha256::new();
        hasher.update(raw_sig.as_bytes());
        candidates.push(hex::encode(hasher.finalize()));

        // Also check relative to configured roots (handling .archive)
        for root in roots {
            if let Ok(rel) = path.strip_prefix(root) {
                let clean_parts: Vec<_> = rel
                    .components()
                    .filter(|c| c.as_os_str() != ".archive")
                    .collect();
                let mut clean_rel = PathBuf::new();
                for p in clean_parts {
                    clean_rel.push(p.as_os_str());
                }

                for other_root in roots {
                    let cand_path = other_root.join(&clean_rel);
                    let cand_sig = format!(
                        "preview:{}:{}:{}",
                        cand_path.to_string_lossy(),
                        size,
                        mtime_ns
                    );
                    let mut h = Sha256::new();
                    h.update(cand_sig.as_bytes());
                    candidates.push(hex::encode(h.finalize()));
                }
            }
        }

        let mut best_dir = None;
        let mut max_thumbs = -1;

        for cand in candidates {
            let dir = preview_base.join(cand);
            if dir.is_dir() {
                let count = fs::read_dir(&dir)
                    .map(|entries| {
                        entries
                            .flatten()
                            .filter(|e| {
                                e.path()
                                    .extension()
                                    .and_then(|ext| ext.to_str())
                                    .map(|ext| ext.eq_ignore_ascii_case("jpg"))
                                    .unwrap_or(false)
                            })
                            .count() as i32
                    })
                    .unwrap_or(0);

                if count > max_thumbs {
                    max_thumbs = count;
                    best_dir = Some(dir);
                }
            }
        }

        best_dir.unwrap_or(primary_dir)
    }

    /// Retrieve duration in seconds: queries PostgreSQL `progress` and `movies` table first,
    /// falling back to executing `ffprobe` if unavailable.
    pub async fn get_duration(
        path: &Path,
        rel_filename: &str,
        pool: &PgPool,
    ) -> Result<f64, AppError> {
        let bare_name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");

        // 1. Check progress table for exact duration in seconds
        let row_prog = sqlx::query_as::<_, (f64,)>(
            "SELECT duration::double precision FROM progress WHERE filename = $1 OR filename = $2 LIMIT 1",
        )
        .bind(rel_filename)
        .bind(bare_name)
        .fetch_optional(pool)
        .await
        .ok()
        .flatten();

        if let Some((duration,)) = row_prog {
            if duration > 0.0 {
                return Ok(duration);
            }
        }

        // 2. Check movies table runtime (runtime in minutes)
        let row_runtime = sqlx::query_as::<_, (Option<i32>,)>(
            "SELECT runtime FROM movies WHERE filename = $1 OR filename = $2",
        )
        .bind(rel_filename)
        .bind(bare_name)
        .fetch_optional(pool)
        .await
        .ok()
        .flatten();

        if let Some((Some(runtime),)) = row_runtime {
            if runtime > 0 {
                return Ok(runtime as f64 * 60.0);
            }
        }

        // 3. Fallback to ffprobe
        let output = tokio::process::Command::new("ffprobe")
            .arg("-v")
            .arg("error")
            .arg("-show_entries")
            .arg("format=duration")
            .arg("-of")
            .arg("default=noprint_wrappers=1:nokey=1")
            .arg(path)
            .output()
            .await
            .map_err(|e| AppError::Internal(format!("Failed to execute ffprobe: {}", e)))?;

        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            if let Ok(duration) = stdout.trim().parse::<f64>() {
                if duration > 0.0 {
                    return Ok(duration);
                }
            }
        }

        Err(AppError::NotFound(
            "Unable to determine media duration".to_string(),
        ))
    }

    /// Calculate sampling interval, thumbnail count, and preview metadata response.
    pub fn calculate_meta(duration: f64, rel_filename: &str) -> SeekPreviewMetaResponse {
        let interval = if duration < 1800.0 {
            5.0
        } else if duration < 7200.0 {
            10.0
        } else {
            15.0
        };

        let count = ((duration - 0.001) / interval).floor() as u64 + 1;

        SeekPreviewMetaResponse {
            duration,
            interval,
            count: count.max(1),
            base_url: format!("/seek-preview/{}", rel_filename),
        }
    }

    /// Ensure exactly one seek preview thumbnail JPEG is cached and return its path.
    pub async fn ensure_thumbnail(
        video_path: &Path,
        index: u64,
        duration: f64,
        interval: f64,
        preview_dir: &Path,
    ) -> Result<PathBuf, AppError> {
        fs::create_dir_all(preview_dir)
            .map_err(|e| AppError::Internal(format!("Failed to create preview dir: {}", e)))?;

        let thumb_name = format!("thumb_{:05}.jpg", index);
        let target = preview_dir.join(&thumb_name);

        if target.is_file() && target.metadata().map(|m| m.len() > 0).unwrap_or(false) {
            return Ok(target);
        }

        let timestamp = (index as f64 * interval).min((duration - 0.05).max(0.0));
        let temp_target = preview_dir.join(format!("thumb_{:05}.part.jpg", index));

        let output = tokio::process::Command::new("ffmpeg")
            .arg("-hide_banner")
            .arg("-loglevel")
            .arg("error")
            .arg("-ss")
            .arg(format!("{:.3}", timestamp))
            .arg("-i")
            .arg(video_path)
            .arg("-frames:v")
            .arg("1")
            .arg("-vf")
            .arg("scale=320:-2")
            .arg("-q:v")
            .arg("5")
            .arg("-y")
            .arg(&temp_target)
            .output()
            .await
            .map_err(|e| AppError::Internal(format!("Failed to execute ffmpeg: {}", e)))?;

        if output.status.success() && temp_target.is_file() {
            fs::rename(&temp_target, &target)
                .map_err(|e| AppError::Internal(format!("Failed to rename thumb: {}", e)))?;
            Ok(target)
        } else {
            let _ = fs::remove_file(&temp_target);
            Err(AppError::Internal(
                "FFmpeg failed to extract preview frame".to_string(),
            ))
        }
    }

    /// Generate standard WebVTT storyboard mapping time intervals to thumbnail URLs.
    pub fn generate_storyboard_vtt(meta: &SeekPreviewMetaResponse, rel_filename: &str) -> String {
        let mut lines = vec!["WEBVTT\n".to_string()];

        for i in 0..meta.count {
            let start_s = i as f64 * meta.interval;
            let end_s = ((i + 1) as f64 * meta.interval).min(meta.duration);

            let start_ts = Self::format_vtt_ts(start_s);
            let end_ts = Self::format_vtt_ts(end_s);

            lines.push(format!(
                "{} --> {}\n/seek-preview/{}/thumb_{:05}.jpg\n",
                start_ts, end_ts, rel_filename, i
            ));
        }

        lines.join("\n")
    }

    fn format_vtt_ts(seconds: f64) -> String {
        let nh = (seconds / 3600.0).floor() as u64;
        let nm = ((seconds % 3600.0) / 60.0).floor() as u64;
        let ns = seconds % 60.0;
        format!("{:02}:{:02}:{:06.3}", nh, nm, ns)
    }
}
