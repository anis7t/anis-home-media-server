use crate::error::AppError;
use crate::models::job::{EnqueueJobRequest, TranscodeJob};
use crate::services::auth_service::AuthService;
use crate::services::chunk_transcode::ChunkTranscodeService;
use crate::services::hls_service::HlsService;
use crate::services::job_service::JobService;
use crate::services::path_resolver::PathResolver;
use crate::services::storage_service::StorageService;
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use sqlx::PgPool;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone)]
pub struct JobState {
    pub pool: Arc<PgPool>,
    pub roots: Arc<Vec<PathBuf>>,
    pub cache_dir: Arc<PathBuf>,
}

/// `POST /api/transcode/jobs/{*path}` - single entry point for job actions.
///
/// The tail is dispatched internally: a `.../cancel` suffix cancels, anything
/// else is treated as a filename and enqueued. Registering separate
/// `/jobs/{*filename}` and `/jobs/{*filename}/cancel` routes is not possible:
/// axum's radix router rejects the second as conflicting with the first, and
/// that conflict panics the whole router at startup (AGENTS.md §9).
pub async fn jobs_dispatch_handler(
    State(state): State<JobState>,
    Path(path): Path<String>,
    body: Option<Json<EnqueueJobRequest>>,
) -> Result<(StatusCode, Json<serde_json::Value>), AppError> {
    let decoded = percent_decode(&path);
    if let Some(filename) = decoded.strip_suffix("/cancel") {
        if filename.is_empty() {
            return Err(AppError::BadRequest("Filename is required".to_string()));
        }
        let body = cancel_job_inner(state, filename).await?;
        return Ok((StatusCode::OK, body));
    }
    if decoded.is_empty() {
        return Err(AppError::BadRequest("Filename is required".to_string()));
    }
    enqueue_job_inner(state, &decoded, body).await
}

/// Job filenames legitimately contain spaces, brackets and Unicode, so a
/// wildcard path arrives percent-encoded.
pub fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok();
            if let Some(v) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).replace('+', " ")
}

async fn enqueue_job_inner(
    state: JobState,
    filename: &str,
    body: Option<Json<EnqueueJobRequest>>,
) -> Result<(StatusCode, Json<serde_json::Value>), AppError> {
    let req = body.map(|Json(b)| b).unwrap_or_default();
    let mode = req.mode.clone().unwrap_or_else(|| "hls".to_string());
    let force = req.force.unwrap_or(false);
    let priority = req
        .priority
        .unwrap_or(crate::services::job_service::PRIORITY_BACKGROUND);

    let job =
        JobService::enqueue_with_priority(&state.pool, filename, &mode, force, priority).await?;

    Ok((
        StatusCode::ACCEPTED,
        Json(serde_json::json!({ "job": job })),
    ))
}

async fn cancel_job_inner(
    state: JobState,
    filename: &str,
) -> Result<Json<serde_json::Value>, AppError> {
    let mode = "hls";
    let job = JobService::get_by_filename(&state.pool, filename, mode).await?;
    match job {
        Some(j) => {
            // No owner supplied from the API: only a queued job may be
            // canceled this way. A running job must be canceled by its
            // lease owner, which is the worker loop (6C).
            let canceled = JobService::cancel(&state.pool, j.id, None).await?;
            let current = JobService::get_by_id(&state.pool, j.id).await?;
            Ok(Json(serde_json::json!({
                "canceled": canceled,
                "job": current,
            })))
        }
        None => Ok(Json(serde_json::json!({
            "canceled": false,
            "job": serde_json::Value::Null,
            "message": "No job for this filename",
        }))),
    }
}

/// `POST /api/transcode/jobs/{filename}` - idempotent admission.
/// Returns 202 with the (possibly pre-existing) job. A title already in a
/// live state is not queued twice.
pub async fn enqueue_job_handler(
    State(state): State<JobState>,
    Path(filename): Path<String>,
    body: Option<Json<EnqueueJobRequest>>,
) -> Result<(StatusCode, Json<serde_json::Value>), AppError> {
    let req = body.map(|Json(b)| b).unwrap_or_default();
    let mode = req.mode.clone().unwrap_or_else(|| "hls".to_string());
    let force = req.force.unwrap_or(false);
    let priority = req
        .priority
        .unwrap_or(crate::services::job_service::PRIORITY_BACKGROUND);

    let job =
        JobService::enqueue_with_priority(&state.pool, &filename, &mode, force, priority).await?;

    Ok((
        StatusCode::ACCEPTED,
        Json(serde_json::json!({ "job": job })),
    ))
}

/// `POST /api/transcode/jobs/{filename}/cancel`
pub async fn cancel_job_handler(
    State(state): State<JobState>,
    Path(filename): Path<String>,
) -> Result<Json<serde_json::Value>, AppError> {
    let mode = "hls";
    let job = JobService::get_by_filename(&state.pool, &filename, mode).await?;
    match job {
        Some(j) => {
            // No owner supplied from the API: only a queued job may be
            // canceled this way. A running job must be canceled by its
            // lease owner, which is the worker loop (6C).
            let canceled = JobService::cancel(&state.pool, j.id, None).await?;
            let current = JobService::get_by_id(&state.pool, j.id).await?;
            Ok(Json(serde_json::json!({
                "canceled": canceled,
                "job": current,
            })))
        }
        None => Ok(Json(serde_json::json!({
            "canceled": false,
            "job": serde_json::Value::Null,
            "message": "No job for this filename",
        }))),
    }
}

/// `GET /api/transcode/jobs` - recent jobs, newest first.
pub async fn list_jobs_handler(
    State(state): State<JobState>,
) -> Result<Json<serde_json::Value>, AppError> {
    let jobs: Vec<TranscodeJob> = JobService::list(&state.pool, 100).await?;
    Ok(Json(serde_json::json!({ "jobs": jobs })))
}

fn format_bytes(bytes: u64) -> String {
    const KB: f64 = 1024.0;
    const MB: f64 = KB * 1024.0;
    const GB: f64 = MB * 1024.0;
    let b = bytes as f64;
    if b >= GB {
        format!("{:.2} GB", b / GB)
    } else if b >= MB {
        format!("{:.1} MB", b / MB)
    } else if b >= KB {
        format!("{:.1} KB", b / KB)
    } else {
        format!("{} B", bytes)
    }
}

fn target_bitrate_bps(mode: &str) -> u64 {
    let (_, height_opt, _) = ChunkTranscodeService::parse_job_mode(mode);
    match height_opt {
        Some(h) if h >= 2160 => 14_000_000 + 192_000,
        Some(h) if h >= 1080 => 4_800_000 + 192_000,
        Some(h) if h >= 720 => 2_500_000 + 192_000,
        Some(h) if h >= 480 => 1_200_000 + 128_000,
        _ => 4_800_000 + 192_000,
    }
}

fn preset_label(mode: &str) -> String {
    let (job_type, _, label) = ChunkTranscodeService::parse_job_mode(mode);
    if job_type == "direct" {
        "Direct Stream (Source)".to_string()
    } else if job_type == "compat" {
        "Direct Compatibility (1080p)".to_string()
    } else {
        format!("{} fMP4 (Dual AMF)", label)
    }
}

fn probe_job_cache_size(filename: &str, roots: &[PathBuf], cache_dir: &std::path::Path) -> u64 {
    let resolved = match PathResolver::resolve_media_path(filename, roots) {
        Ok(p) => p,
        Err(_) => return 0,
    };
    let candidates = HlsService::get_hls_candidates(&resolved, roots);
    let hls_base = cache_dir.join("hls");
    for cand in candidates {
        let cand_dir = hls_base.join(&cand);
        if cand_dir.is_dir() {
            let (size_bytes, _, _) = StorageService::get_dir_size_and_mtime(&cand_dir);
            if size_bytes > 0 {
                return size_bytes;
            }
        }
    }
    0
}

fn estimate_total_bytes(current_bytes: u64, pct: f64, runtime_min: Option<i32>, mode: &str) -> u64 {
    let dur_sec = runtime_min
        .filter(|&r| r > 0)
        .map(|r| (r * 60) as f64)
        .unwrap_or(5400.0);
    let target_rate_bps = target_bitrate_bps(mode) as f64;
    let theoretical_bytes = (target_rate_bps * dur_sec / 8.0) as u64;

    if pct >= 10.0 && current_bytes > 0 {
        let extrapolated = ((current_bytes as f64) / (pct / 100.0)) as u64;
        let weight = ((pct - 10.0) / 40.0).clamp(0.0, 1.0);
        ((extrapolated as f64 * weight) + (theoretical_bytes as f64 * (1.0 - weight))) as u64
    } else {
        theoretical_bytes
    }
}

/// `GET /api/transcodes` - active background transcodes formatted for web/mobile UI.
pub async fn active_transcodes_handler(
    State(state): State<JobState>,
) -> Result<Json<serde_json::Value>, AppError> {
    let jobs = JobService::list(&state.pool, 50).await?;

    // Batch query movie runtimes in a single roundtrip
    let filenames: Vec<String> = jobs.iter().map(|j| j.filename.clone()).collect();
    let runtimes: Vec<(String, Option<i32>)> =
        sqlx::query_as("SELECT filename, runtime FROM movies WHERE filename = ANY($1)")
            .bind(&filenames)
            .fetch_all(&*state.pool)
            .await
            .unwrap_or_default();
    let runtime_map: std::collections::HashMap<String, Option<i32>> =
        runtimes.into_iter().collect();

    let mut list = Vec::new();
    for j in jobs {
        if j.status == "running" || j.status == "queued" {
            let name_parts = j
                .filename
                .rsplit_once('/')
                .map(|(_, n)| n)
                .unwrap_or(&j.filename);
            let title = name_parts
                .rsplit_once('.')
                .map(|(n, _)| n)
                .unwrap_or(name_parts)
                .replace('.', " ");
            let pct = j.progress.unwrap_or(0.0);
            let speed_str = j.speed.map(|s| format!("{:.1}x", s));
            let fps_str = j.fps.map(|f| format!("{:.0} fps", f));
            let eta_str = j
                .eta
                .map(|e| {
                    let m = (e / 60.0).floor() as u64;
                    let s = (e % 60.0).floor() as u64;
                    if m >= 60 {
                        format!("{}h {}m", m / 60, m % 60)
                    } else {
                        format!("{}m {}s", m, s)
                    }
                })
                .unwrap_or_else(|| "calculating...".to_string());

            let runtime = runtime_map.get(&j.filename).copied().flatten();

            let (encoded_str, duration_str) = if let Some(rt_min) = runtime.filter(|&r| r > 0) {
                let dur_sec = (rt_min * 60) as f64;
                let enc_sec = (dur_sec * (pct / 100.0)).clamp(0.0, dur_sec);
                (
                    Some(format!(
                        "{}:{:02}",
                        (enc_sec / 60.0).floor() as u64,
                        (enc_sec % 60.0).floor() as u64
                    )),
                    Some(format!(
                        "{}:{:02}",
                        (dur_sec / 60.0).floor() as u64,
                        (dur_sec % 60.0).floor() as u64
                    )),
                )
            } else if let (Some(eta_val), Some(spd_val)) = (j.eta, j.speed) {
                if spd_val > 0.05 && pct > 0.0 {
                    let remaining_sec = eta_val;
                    let total_est_sec = remaining_sec / (1.0 - (pct / 100.0)).max(0.01);
                    let enc_sec = (total_est_sec * (pct / 100.0)).max(0.0);
                    (
                        Some(format!(
                            "{}:{:02}",
                            (enc_sec / 60.0).floor() as u64,
                            (enc_sec % 60.0).floor() as u64
                        )),
                        Some(format!(
                            "{}:{:02}",
                            (total_est_sec / 60.0).floor() as u64,
                            (total_est_sec % 60.0).floor() as u64
                        )),
                    )
                } else {
                    (None, None)
                }
            } else {
                (None, None)
            };

            // Only running jobs with active progress have written segments to disk; skip disk I/O for queued jobs.
            let current_bytes = if j.status == "running" && pct > 0.1 {
                probe_job_cache_size(&j.filename, &state.roots, &state.cache_dir)
            } else {
                0
            };
            let est_bytes = estimate_total_bytes(current_bytes, pct, runtime, &j.mode);
            let preset = preset_label(&j.mode);

            list.push(serde_json::json!({
                "id": j.id,
                "filename": j.filename,
                "title": title,
                "mode": j.mode,
                "preset_label": preset,
                "status": j.status,
                "percent": pct,
                "speed": speed_str,
                "fps": fps_str,
                "eta_str": eta_str,
                "encoded_str": encoded_str,
                "duration_str": duration_str,
                "current_bytes": current_bytes,
                "current_size_str": format_bytes(current_bytes),
                "estimated_total_bytes": est_bytes,
                "estimated_total_size_str": format_bytes(est_bytes),
                "poster_url": format!("/poster/{}", j.filename),
            }));
        }
    }

    // Actively running streams always come first, followed by queued streams
    list.sort_by(|a, b| {
        let a_status = a.get("status").and_then(|s| s.as_str()).unwrap_or("");
        let b_status = b.get("status").and_then(|s| s.as_str()).unwrap_or("");
        if a_status == "running" && b_status != "running" {
            std::cmp::Ordering::Less
        } else if a_status != "running" && b_status == "running" {
            std::cmp::Ordering::Greater
        } else {
            std::cmp::Ordering::Equal
        }
    });

    Ok(Json(serde_json::json!({ "transcodes": list })))
}

/// `GET /api/transcode/dashboard` - full admin transcoding telemetry & command center.
#[allow(clippy::type_complexity)]
pub async fn transcode_dashboard_handler(
    State(state): State<JobState>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, AppError> {
    let is_admin = AuthService::is_admin_authorized(&state.pool, &headers, None).await;
    if !is_admin {
        return Err(AppError::Unauthorized(
            "Administrator access required to view transcode telemetry dashboard".to_string(),
        ));
    }

    let all_jobs = JobService::list_for_dashboard(&state.pool, 50).await?;

    // Batch query movie metadata in a single roundtrip
    let filenames: Vec<String> = all_jobs.iter().map(|j| j.filename.clone()).collect();
    let movies: Vec<(String, String, Option<i32>, Option<i32>, Option<String>, Option<String>)> = sqlx::query_as(
        "SELECT filename, title, year, runtime, poster_path, backdrop_path FROM movies WHERE filename = ANY($1)",
    )
    .bind(&filenames)
    .fetch_all(&*state.pool)
    .await
    .unwrap_or_default();

    let movie_map: std::collections::HashMap<
        String,
        (
            String,
            Option<i32>,
            Option<i32>,
            Option<String>,
            Option<String>,
        ),
    > = movies
        .into_iter()
        .map(|(f, t, y, r, p, b)| (f, (t, y, r, p, b)))
        .collect();

    let mut active_jobs = Vec::new();
    let mut recent_jobs = Vec::new();

    let mut total_current_bytes: u64 = 0;
    let mut total_estimated_bytes: u64 = 0;
    let mut max_eta_sec: f64 = 0.0;
    let mut sum_eta_sec: f64 = 0.0;
    let mut running_count = 0;
    let mut queued_count = 0;

    for j in all_jobs {
        let name_parts = j
            .filename
            .rsplit_once('/')
            .map(|(_, n)| n)
            .unwrap_or(&j.filename);
        let title_guess = name_parts
            .rsplit_once('.')
            .map(|(n, _)| n)
            .unwrap_or(name_parts)
            .replace('.', " ");

        let (title, year, runtime, poster_path, backdrop_path) = match movie_map.get(&j.filename) {
            Some((t, y, r, p, b)) => (t.clone(), *y, *r, p.clone(), b.clone()),
            None => (title_guess, None, None, None, None),
        };

        let pct = j.progress.unwrap_or(0.0);
        let speed_str = j.speed.map(|s| format!("{:.1}x", s));
        let fps_str = j.fps.map(|f| format!("{:.0} fps", f));

        let rt_min = runtime.filter(|&r| r > 0).unwrap_or(100);
        let rt_sec = (rt_min * 60) as f64;
        let projected_speed = match j.mode.as_str() {
            "4k" | "2160p" | "fmp4_2160p" => 1.5,
            "720p" | "fmp4_720p" => 6.0,
            "480p" | "fmp4_480p" | "360p" | "fmp4_360p" => 8.0,
            _ => 4.0, // default 1080p combined dual-GPU speed
        };
        let projected_remaining = if j.status == "running" {
            let remaining_dur = (rt_sec * (1.0 - (pct / 100.0))).max(0.0);
            remaining_dur / projected_speed
        } else {
            rt_sec / projected_speed
        };

        let effective_eta = match j.eta.filter(|&e| e > 0.0) {
            Some(e) => e,
            None => projected_remaining,
        };

        let eta_str = if j.status == "running" {
            if let Some(eta_val) = j.eta.filter(|&e| e > 0.0) {
                let m = (eta_val / 60.0).floor() as u64;
                let s = (eta_val % 60.0).floor() as u64;
                if m >= 60 {
                    format!("{}h {}m", m / 60, m % 60)
                } else {
                    format!("{}m {}s", m, s)
                }
            } else {
                "calculating...".to_string()
            }
        } else if j.status == "queued" {
            let m = (effective_eta / 60.0).floor() as u64;
            if m >= 60 {
                format!("~{}h {}m", m / 60, m % 60)
            } else {
                format!("~{}m", m.max(1))
            }
        } else {
            "-".to_string()
        };

        let (encoded_str, duration_str) = if let Some(rt_min) = runtime.filter(|&r| r > 0) {
            let dur_sec = (rt_min * 60) as f64;
            let enc_sec = (dur_sec * (pct / 100.0)).clamp(0.0, dur_sec);
            (
                Some(format!(
                    "{}:{:02}",
                    (enc_sec / 60.0).floor() as u64,
                    (enc_sec % 60.0).floor() as u64
                )),
                Some(format!(
                    "{}:{:02}",
                    (dur_sec / 60.0).floor() as u64,
                    (dur_sec % 60.0).floor() as u64
                )),
            )
        } else if let (Some(eta_val), Some(spd_val)) = (j.eta, j.speed) {
            if spd_val > 0.05 && pct > 0.0 {
                let remaining_sec = eta_val;
                let total_est_sec = remaining_sec / (1.0 - (pct / 100.0)).max(0.01);
                let enc_sec = (total_est_sec * (pct / 100.0)).max(0.0);
                (
                    Some(format!(
                        "{}:{:02}",
                        (enc_sec / 60.0).floor() as u64,
                        (enc_sec % 60.0).floor() as u64
                    )),
                    Some(format!(
                        "{}:{:02}",
                        (total_est_sec / 60.0).floor() as u64,
                        (total_est_sec % 60.0).floor() as u64
                    )),
                )
            } else {
                (None, None)
            }
        } else {
            (None, None)
        };

        // Only running jobs with active progress probe disk cache; queued jobs have 0 bytes written.
        let current_bytes = if j.status == "running" && pct > 0.1 {
            probe_job_cache_size(&j.filename, &state.roots, &state.cache_dir)
        } else {
            0
        };
        let est_bytes = estimate_total_bytes(current_bytes, pct, runtime, &j.mode);
        let preset = preset_label(&j.mode);

        if j.status == "running" || j.status == "queued" {
            if j.status == "running" {
                running_count += 1;
            } else {
                queued_count += 1;
            }
            total_current_bytes += current_bytes;
            total_estimated_bytes += est_bytes;
            if effective_eta > max_eta_sec {
                max_eta_sec = effective_eta;
            }
            sum_eta_sec += effective_eta;

            active_jobs.push(serde_json::json!({
                "id": j.id,
                "filename": j.filename,
                "title": title,
                "year": year,
                "runtime": runtime,
                "poster_url": format!("/poster/{}", j.filename),
                "poster_path": poster_path,
                "backdrop_path": backdrop_path,
                "mode": j.mode,
                "preset_label": preset,
                "status": j.status,
                "percent": pct,
                "speed": j.speed,
                "speed_str": speed_str,
                "fps": j.fps,
                "fps_str": fps_str,
                "eta": j.eta.or(Some(effective_eta)),
                "eta_str": eta_str,
                "encoded_str": encoded_str,
                "duration_str": duration_str,
                "current_bytes": current_bytes,
                "current_size_str": format_bytes(current_bytes),
                "estimated_total_bytes": est_bytes,
                "estimated_total_size_str": format_bytes(est_bytes),
                "priority": j.priority,
                "created_at": j.created_at,
                "updated_at": j.updated_at,
            }));
        } else {
            // Recent completed / failed / canceled jobs
            let elapsed_sec = (j.updated_at - j.created_at).num_seconds().max(0) as u64;
            let elapsed_str = if elapsed_sec >= 60 {
                format!("{}m {}s", elapsed_sec / 60, elapsed_sec % 60)
            } else {
                format!("{}s", elapsed_sec)
            };

            recent_jobs.push(serde_json::json!({
                "id": j.id,
                "filename": j.filename,
                "title": title,
                "year": year,
                "poster_url": format!("/poster/{}", j.filename),
                "mode": j.mode,
                "preset_label": preset,
                "status": j.status,
                "error": j.error,
                "elapsed_sec": elapsed_sec,
                "elapsed_str": elapsed_str,
                "current_bytes": current_bytes,
                "current_size_str": format_bytes(current_bytes),
                "created_at": j.created_at,
                "updated_at": j.updated_at,
            }));
        }
    }

    // Actively running streams always come first, followed by queued streams
    active_jobs.sort_by(|a, b| {
        let a_status = a.get("status").and_then(|s| s.as_str()).unwrap_or("");
        let b_status = b.get("status").and_then(|s| s.as_str()).unwrap_or("");
        if a_status == "running" && b_status != "running" {
            std::cmp::Ordering::Less
        } else if a_status != "running" && b_status == "running" {
            std::cmp::Ordering::Greater
        } else {
            std::cmp::Ordering::Equal
        }
    });

    recent_jobs.truncate(20);

    let overall_eta_val = sum_eta_sec;
    let overall_eta_str = if overall_eta_val > 0.0 {
        let m = (overall_eta_val / 60.0).floor() as u64;
        let s = (overall_eta_val % 60.0).floor() as u64;
        if m >= 60 {
            format!("{}h {}m", m / 60, m % 60)
        } else {
            format!("{}m {}s", m, s)
        }
    } else if queued_count > 0 {
        "calculating...".to_string()
    } else {
        "0s".to_string()
    };

    let summary = serde_json::json!({
        "active_count": active_jobs.len(),
        "running_count": running_count,
        "queued_count": queued_count,
        "total_current_bytes": total_current_bytes,
        "total_current_size_str": format_bytes(total_current_bytes),
        "total_estimated_bytes": total_estimated_bytes,
        "total_estimated_size_str": format_bytes(total_estimated_bytes),
        "overall_eta_seconds": overall_eta_val,
        "overall_eta_str": overall_eta_str,
        "hardware_engine": {
            "primary": {
                "name": "AMD Radeon RX 560X",
                "adapter": 1,
                "backend": "AMF / D3D11VA (Discrete)",
                "status": if running_count > 0 { "Active Encoding" } else { "Idle / Standby" }
            },
            "secondary": {
                "name": "AMD Radeon Vega 8",
                "adapter": 0,
                "backend": "AMF / D3D11VA (Integrated)",
                "status": if running_count > 0 { "Active Encoding" } else { "Idle / Standby" }
            }
        }
    });

    Ok(Json(serde_json::json!({
        "summary": summary,
        "active_jobs": active_jobs,
        "recent_jobs": recent_jobs,
    })))
}
