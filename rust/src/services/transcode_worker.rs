//! Multi-GPU Transcode Worker Execution Engine.
//!
//! Claims transcode jobs from PostgreSQL `transcode_jobs`, provisions AMF hardware encoder
//! pipelines across discrete RX 560X (`dx11:1`) and integrated Vega 8 (`dx11:0`), executes
//! strided HLS chunks concurrently, renews leases, reports telemetry, and publishes complete playlists.

use crate::error::AppError;
use crate::models::job::TranscodeJob;
use crate::services::chunk_transcode::{
    ChunkTranscodeService, TranscodeChunk, DEFAULT_CHUNK_DURATION, MIN_COVERAGE_RATIO,
};
use crate::services::gpu_service::{GPUWorkerConfig, GpuService};
use crate::services::hls_service::HlsService;
use crate::services::job_service::JobService;
use crate::services::path_resolver::PathResolver;
use crate::services::probe_service::ProbeService;
use sqlx::PgPool;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;
use tracing::{error, info, warn};

pub struct TranscodeWorker;

impl TranscodeWorker {
    /// Spawns the background transcode worker loop.
    pub fn start_worker(
        pool: PgPool,
        roots: Arc<Vec<PathBuf>>,
        cache_dir: Arc<PathBuf>,
        worker_id: String,
        shutdown: Arc<AtomicBool>,
    ) {
        tokio::spawn(async move {
            info!("Transcode worker [{}] started", worker_id);
            // Brief boot delay to ensure database connection pool is warm
            tokio::time::sleep(Duration::from_secs(3)).await;

            while !shutdown.load(Ordering::SeqCst) {
                match Self::process_next_job(&pool, &roots, &cache_dir, &worker_id, &shutdown).await {
                    Ok(true) => {
                        // Work was done; check for next job immediately
                    }
                    Ok(false) => {
                        // Queue was empty; idle sleep
                        tokio::time::sleep(Duration::from_secs(2)).await;
                    }
                    Err(e) => {
                        warn!("Transcode worker [{}] encountered error: {}", worker_id, e);
                        tokio::time::sleep(Duration::from_secs(3)).await;
                    }
                }
            }

            info!("Transcode worker [{}] shutting down", worker_id);
        });
    }

    /// Claim and process one job from the queue. Returns `true` if a job was found and processed.
    pub async fn process_next_job(
        pool: &PgPool,
        roots: &[PathBuf],
        cache_dir: &Path,
        worker_id: &str,
        shutdown: &AtomicBool,
    ) -> Result<bool, AppError> {
        let job = match JobService::claim_next(pool, worker_id, 300).await? {
            Some(j) => j,
            None => return Ok(false),
        };

        info!(
            "Worker [{}] claimed transcode job #{} for '{}' (priority {})",
            worker_id, job.id, job.filename, job.priority
        );

        if let Err(e) = Self::execute_job(pool, roots, cache_dir, worker_id, &job, shutdown).await {
            error!(
                "Worker [{}] failed job #{} ({}): {}",
                worker_id, job.id, job.filename, e
            );
            let _ = JobService::fail(pool, job.id, worker_id, &e.to_string()).await;
        }

        Ok(true)
    }

    /// Execute a claimed transcode job across multi-GPU chunk pipelines.
    async fn execute_job(
        pool: &PgPool,
        roots: &[PathBuf],
        cache_dir: &Path,
        worker_id: &str,
        job: &TranscodeJob,
        shutdown: &AtomicBool,
    ) -> Result<(), AppError> {
        let video_path = PathResolver::resolve_media_path(&job.filename, roots)
            .map_err(|e| AppError::NotFound(format!("Media file not found: {}", e)))?;

        let hls_dir = HlsService::find_hls_dir(&video_path, roots, cache_dir);
        tokio::fs::create_dir_all(&hls_dir).await.map_err(|e| {
            AppError::Internal(format!("Failed to create HLS cache directory: {}", e))
        })?;

        let playlist_path = hls_dir.join("playlist.m3u8");

        // 1. Probe source properties
        let probe = ProbeService::probe(&video_path).await;
        let total_duration = ProbeService::source_video_duration(&video_path).await;

        if total_duration <= 0.0 {
            return Err(AppError::Internal("Source video duration is zero or unreadable".into()));
        }

        // 2. Select AMF strategy and expand workers
        let (use_vpp_amf, worker_count) =
            GpuService::select_amf_strategy(probe.first_stream("video"));
        let base_gpus = GpuService::get_gpu_workers();
        let workers = GpuService::expand_workers(&base_gpus, worker_count);

        info!(
            "Job #{}: duration={:.1}s, vpp_amf={}, workers={} ({})",
            job.id,
            total_duration,
            use_vpp_amf,
            workers.len(),
            workers
                .iter()
                .map(|w| w.name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        );

        // 3. Plan chunks
        let all_chunks = ChunkTranscodeService::plan_chunks(total_duration, DEFAULT_CHUNK_DURATION);
        if all_chunks.is_empty() {
            return Err(AppError::Internal("No chunks planned for video".into()));
        }

        // Filter out already rendered chunks
        let mut pending_chunks = Vec::new();
        for c in &all_chunks {
            if !ChunkTranscodeService::chunk_output_ok(&hls_dir, c) {
                pending_chunks.push(c.clone());
            }
        }

        info!(
            "Job #{}: {} of {} chunks pending execution",
            job.id,
            pending_chunks.len(),
            all_chunks.len()
        );

        // 4. Initial master playlist update
        let initial_encoded = ChunkTranscodeService::update_master_playlist(
            &hls_dir,
            &playlist_path,
            total_duration,
            false,
        )
        .unwrap_or(0.0);

        let initial_pct = (initial_encoded / total_duration * 100.0).clamp(0.0, 100.0);
        let _ = JobService::update_progress(pool, job.id, worker_id, Some(initial_pct), None, None, None).await;

        let start_time = Instant::now();
        let active_pids: Arc<Mutex<HashSet<u32>>> = Arc::new(Mutex::new(HashSet::new()));

        // Process chunks with bounded concurrency corresponding to worker slots
        let concurrency = workers.len().max(1);
        let mut last_lease_renew = Instant::now();
        let mut chunk_idx = 0;

        // Background 1.5-second cadence progress monitor
        let job_done = Arc::new(AtomicBool::new(false));
        let job_done_clone = job_done.clone();
        let pool_clone = pool.clone();
        let hls_dir_clone = hls_dir.clone();
        let playlist_path_clone = playlist_path.clone();
        let job_id = job.id;
        let worker_id_str = worker_id.to_string();

        let progress_updater_handle = tokio::spawn(async move {
            let mut rate_samples: Vec<(Instant, f64)> = Vec::new();
            rate_samples.push((start_time, initial_encoded));

            while !job_done_clone.load(Ordering::Relaxed) {
                tokio::time::sleep(Duration::from_millis(1500)).await;

                if job_done_clone.load(Ordering::Relaxed) {
                    break;
                }

                let encoded_sec = ChunkTranscodeService::update_master_playlist(
                    &hls_dir_clone,
                    &playlist_path_clone,
                    total_duration,
                    false,
                )
                .unwrap_or(0.0);

                let now = Instant::now();
                rate_samples.push((now, encoded_sec));
                if rate_samples.len() > 120 {
                    rate_samples.remove(0);
                }

                let pct = (encoded_sec / total_duration * 100.0).clamp(0.0, 100.0);

                // Trailing rate window: 90s window, min 15s span
                let cutoff = now.checked_sub(Duration::from_secs(90)).unwrap_or(now);
                let mut base_t = rate_samples[0].0;
                let mut base_s = rate_samples[0].1;
                for (t, s) in &rate_samples {
                    if *t >= cutoff {
                        base_t = *t;
                        base_s = *s;
                        break;
                    }
                }

                let span = now.duration_since(base_t).as_secs_f64();
                let delta = (encoded_sec - base_s).max(0.0);
                let speed = if span >= 15.0 && delta > 0.0 {
                    Some(delta / span)
                } else {
                    let total_elapsed = now.duration_since(start_time).as_secs_f64();
                    let newly_encoded = (encoded_sec - initial_encoded).max(0.0);
                    if total_elapsed > 5.0 && newly_encoded > 0.0 {
                        Some(newly_encoded / total_elapsed)
                    } else {
                        None
                    }
                };

                let remaining_sec = (total_duration - encoded_sec).max(0.0);
                let eta = speed.filter(|s| *s > 0.05).map(|s| remaining_sec / s);

                let _ = JobService::update_progress(
                    &pool_clone,
                    job_id,
                    &worker_id_str,
                    Some(pct),
                    speed,
                    None,
                    eta,
                )
                .await;

                let _ = ChunkTranscodeService::write_progress_file(
                    &hls_dir_clone,
                    encoded_sec,
                    speed.unwrap_or(1.0),
                    false,
                );
            }
        });

        let run_result: Result<(), AppError> = async {
            while chunk_idx < pending_chunks.len() {
                if shutdown.load(Ordering::SeqCst) {
                    return Err(AppError::Internal("Worker interrupted by server shutdown".into()));
                }

                // Check if job was cancelled in DB
                if let Ok(Some(current)) = JobService::get_by_id(pool, job.id).await {
                    if current.status == "canceled" {
                        info!("Job #{} was canceled; stopping execution", job.id);
                        return Ok(());
                    }
                }

                // Renew lease every 45s
                if last_lease_renew.elapsed() > Duration::from_secs(45) {
                    let renewed = JobService::renew_lease(pool, job.id, worker_id, 300).await?;
                    if !renewed {
                        return Err(AppError::Internal("Lost lease ownership of transcode job".into()));
                    }
                    last_lease_renew = Instant::now();
                }

                // Batch up to `concurrency` chunks
                let batch_end = (chunk_idx + concurrency).min(pending_chunks.len());
                let batch = &pending_chunks[chunk_idx..batch_end];

                let mut tasks = Vec::new();
                for (i, chunk) in batch.iter().enumerate() {
                    let worker_cfg = workers[i % workers.len()].clone();
                    let v_path = video_path.clone();
                    let h_dir = hls_dir.clone();
                    let c_item = chunk.clone();
                    let pids = active_pids.clone();

                    tasks.push(tokio::spawn(async move {
                        Self::execute_single_chunk(
                            &v_path,
                            &h_dir,
                            &c_item,
                            &worker_cfg,
                            use_vpp_amf,
                            pids,
                        )
                        .await
                    }));
                }

                // Wait for batch completion
                for task in tasks {
                    match task.await {
                        Ok(Ok(())) => {}
                        Ok(Err(e)) => return Err(e),
                        Err(join_err) => {
                            return Err(AppError::Internal(format!("Chunk task join error: {}", join_err)))
                        }
                    }
                }

                chunk_idx = batch_end;
            }
            Ok(())
        }
        .await;

        job_done.store(true, Ordering::Relaxed);
        let _ = progress_updater_handle.await;

        if let Err(e) = run_result {
            // Clean up any active child ffmpeg processes on Windows to prevent orphaned locks
            for pid in active_pids.lock().await.iter() {
                let _ = std::process::Command::new("taskkill")
                    .args(["/PID", &pid.to_string(), "/F", "/T"])
                    .output();
            }
            return Err(e);
        }

        // 5. Finalize and validate coverage
        let final_encoded = ChunkTranscodeService::update_master_playlist(
            &hls_dir,
            &playlist_path,
            total_duration,
            true, // Appends #EXT-X-ENDLIST
        )
        .unwrap_or(0.0);

        let coverage_ratio = final_encoded / total_duration;
        info!(
            "Job #{}: transcode complete. Final coverage: {:.1}s / {:.1}s ({:.1}%)",
            job.id,
            final_encoded,
            total_duration,
            coverage_ratio * 100.0
        );

        if coverage_ratio < MIN_COVERAGE_RATIO {
            warn!(
                "Job #{} coverage {:.1}% is below threshold {:.1}%, but sealing output",
                job.id,
                coverage_ratio * 100.0,
                MIN_COVERAGE_RATIO * 100.0
            );
        }

        let _ = ChunkTranscodeService::write_progress_file(&hls_dir, final_encoded, 1.0, true);
        JobService::complete(pool, job.id, worker_id).await?;

        info!("Job #{} successfully completed and published", job.id);
        Ok(())
    }

    /// Spawns FFmpeg subprocess to render one chunk.
    async fn execute_single_chunk(
        video_path: &Path,
        hls_dir: &Path,
        chunk: &TranscodeChunk,
        worker: &GPUWorkerConfig,
        use_vpp_amf: bool,
        active_pids: Arc<Mutex<HashSet<u32>>>,
    ) -> Result<(), AppError> {
        let chunk_pl = hls_dir.join(format!("chunk_{}.m3u8", chunk.chunk_id));

        let mut cmd = tokio::process::Command::new("ffmpeg");
        cmd.arg("-hide_banner").arg("-y");

        // HW Init
        for arg in worker.get_ffmpeg_init_args() {
            cmd.arg(arg);
        }

        // Input seeking
        cmd.arg("-ss")
            .arg(format!("{:.3}", chunk.start_time))
            .arg("-t")
            .arg(format!("{:.3}", chunk.duration))
            .arg("-i")
            .arg(video_path);

        // Video encoding args
        for arg in worker.get_ffmpeg_video_args(use_vpp_amf) {
            cmd.arg(arg);
        }

        // Audio args (standard stereo AAC 192k)
        cmd.arg("-c:a")
            .arg("aac")
            .arg("-b:a")
            .arg("192k")
            .arg("-ac")
            .arg("2");

        // HLS output container args
        cmd.arg("-output_ts_offset")
            .arg(format!("{:.3}", chunk.start_time))
            .arg("-muxdelay")
            .arg("0")
            .arg("-force_key_frames")
            .arg("expr:gte(t,n_forced*4)")
            .arg("-f")
            .arg("hls")
            .arg("-hls_time")
            .arg(crate::services::chunk_transcode::SEGMENT_TARGET_DURATION.to_string())
            .arg("-hls_list_size")
            .arg("0")
            .arg("-hls_flags")
            .arg("independent_segments")
            .arg("-start_number")
            .arg(chunk.start_seg.to_string())
            .arg("-hls_segment_filename")
            .arg(hls_dir.join("segment_%06d.ts"))
            .arg("-nostats")
            .arg(&chunk_pl);

        cmd.stdout(std::process::Stdio::null());
        cmd.stderr(std::process::Stdio::piped());

        let child = cmd.spawn().map_err(|e| {
            AppError::Internal(format!(
                "Failed to spawn FFmpeg for chunk {}: {}",
                chunk.chunk_id, e
            ))
        })?;

        let child_pid = child.id();
        if let Some(pid) = child_pid {
            active_pids.lock().await.insert(pid);
        }

        let output = child.wait_with_output().await.map_err(|e| {
            AppError::Internal(format!("FFmpeg wait error on chunk {}: {}", chunk.chunk_id, e))
        })?;

        if let Some(pid) = child_pid {
            active_pids.lock().await.remove(&pid);
        }

        if !output.status.success() {
            let stderr_text = String::from_utf8_lossy(&output.stderr);
            let last_err = stderr_text
                .lines()
                .filter(|l| !l.trim().is_empty())
                .last()
                .unwrap_or("unknown FFmpeg failure");
            return Err(AppError::Internal(format!(
                "Chunk {} failed on {}: {}",
                chunk.chunk_id, worker.name, last_err
            )));
        }

        // Validate chunk produced usable output
        if !ChunkTranscodeService::chunk_output_ok(hls_dir, chunk) {
            return Err(AppError::Internal(format!(
                "Chunk {} on {} failed output verification",
                chunk.chunk_id, worker.name
            )));
        }

        Ok(())
    }
}
