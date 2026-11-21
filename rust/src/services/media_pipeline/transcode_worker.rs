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
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::sync::Mutex;
use tracing::{debug, error, info, warn};

const GPU_DIAGNOSTIC_MAX_FILE_BYTES: u64 = 4 * 1024 * 1024;
const GPU_DIAGNOSTIC_MAX_TOTAL_BYTES: u64 = 256 * 1024 * 1024;
const GPU_DIAGNOSTIC_RETENTION: Duration = Duration::from_secs(14 * 24 * 60 * 60);
const GPU_DIAGNOSTIC_TAIL_BYTES: u64 = 64 * 1024;
const GPU_DIAGNOSTIC_TRUNCATION_MARKER: &[u8] = b"\n[FFmpeg stderr log truncated at 4 MiB]\n";

async fn persist_ffmpeg_stderr<R>(mut stderr: R, mut file: tokio::fs::File) -> std::io::Result<()>
where
    R: AsyncRead + Unpin,
{
    let payload_limit =
        GPU_DIAGNOSTIC_MAX_FILE_BYTES.saturating_sub(GPU_DIAGNOSTIC_TRUNCATION_MARKER.len() as u64);
    let mut written = 0u64;
    let mut truncated = false;
    let mut write_error = None;
    let mut buffer = [0u8; 8192];

    loop {
        let read = stderr.read(&mut buffer).await?;
        if read == 0 {
            break;
        }

        let remaining = payload_limit.saturating_sub(written) as usize;
        let write = read.min(remaining);
        if write > 0 && write_error.is_none() {
            match file.write_all(&buffer[..write]).await {
                Ok(()) => written += write as u64,
                Err(error) => write_error = Some(error),
            }
        }
        truncated |= write < read;
    }

    if truncated && write_error.is_none() {
        if let Err(error) = file.write_all(GPU_DIAGNOSTIC_TRUNCATION_MARKER).await {
            write_error = Some(error);
        }
    }
    if write_error.is_none() {
        if let Err(error) = file.flush().await {
            write_error = Some(error);
        }
    }
    write_error.map_or(Ok(()), Err)
}

async fn finish_ffmpeg_stderr_capture(
    mut task: tokio::task::JoinHandle<std::io::Result<()>>,
) -> Option<String> {
    match tokio::time::timeout(Duration::from_secs(5), &mut task).await {
        Ok(Ok(Ok(()))) => None,
        Ok(Ok(Err(error))) => Some(error.to_string()),
        Ok(Err(error)) => Some(format!("stderr capture task failed: {error}")),
        Err(_) => {
            task.abort();
            let _ = task.await;
            Some("stderr capture did not stop after FFmpeg exited".into())
        }
    }
}

fn read_ffmpeg_log_tail(path: &Path) -> String {
    let Ok(mut file) = std::fs::File::open(path) else {
        return "(diagnostic log could not be reopened)".into();
    };
    let Ok(length) = file.metadata().map(|metadata| metadata.len()) else {
        return "(diagnostic log size could not be read)".into();
    };
    let start = length.saturating_sub(GPU_DIAGNOSTIC_TAIL_BYTES);
    if file.seek(SeekFrom::Start(start)).is_err() {
        return "(diagnostic log could not be read)".into();
    }
    let mut bytes = Vec::with_capacity((length - start) as usize);
    if file.read_to_end(&mut bytes).is_err() {
        return "(diagnostic log could not be read)".into();
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

fn gpu_diagnostic_log_dir() -> PathBuf {
    std::env::var_os("MEDIA_SERVER_GPU_LOG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("logs").join("gpu"))
}

fn create_gpu_diagnostic_log(
    job_id: i64,
    worker: &GPUWorkerConfig,
    chunk: &TranscodeChunk,
) -> std::io::Result<(PathBuf, std::fs::File)> {
    let directory = gpu_diagnostic_log_dir();
    std::fs::create_dir_all(&directory)?;
    prune_gpu_diagnostic_logs(&directory);

    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let adapter_name = worker
        .name
        .chars()
        .map(|ch| if ch.is_ascii_alphanumeric() { ch } else { '-' })
        .collect::<String>();
    let base = format!(
        "job-{job_id}-adapter-{}-{adapter_name}-chunk-{}-{now_ms}",
        worker.adapter_id, chunk.chunk_id
    );

    for attempt in 0..100u8 {
        let suffix = if attempt == 0 {
            String::new()
        } else {
            format!("-{attempt}")
        };
        let path = directory.join(format!("{base}{suffix}.partial.log"));
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(file) => return Ok((path, file)),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }

    Err(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        "could not allocate a unique GPU diagnostic log filename",
    ))
}

fn prune_gpu_diagnostic_logs(directory: &Path) {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return;
    };
    let now = SystemTime::now();
    let mut files = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let metadata = entry.metadata().ok()?;
            if !metadata.is_file() || !entry.file_name().to_string_lossy().starts_with("job-") {
                return None;
            }
            Some((entry.path(), metadata.len(), metadata.modified().ok()))
        })
        .collect::<Vec<_>>();

    for (path, size, modified) in &files {
        if modified.is_some_and(|time| {
            now.duration_since(time).unwrap_or_default() > GPU_DIAGNOSTIC_RETENTION
        }) && std::fs::remove_file(path).is_ok()
        {
            debug!(log_path = %path.display(), bytes = size, "Removed expired GPU diagnostic log");
        }
    }
    files.retain(|(path, _, _)| path.exists());

    let mut total = files.iter().map(|(_, size, _)| *size).sum::<u64>();
    if total <= GPU_DIAGNOSTIC_MAX_TOTAL_BYTES {
        return;
    }
    files.sort_by_key(|(_, _, modified)| *modified);
    for (path, size, _) in files {
        if total <= GPU_DIAGNOSTIC_MAX_TOTAL_BYTES {
            break;
        }
        if path
            .file_name()
            .is_some_and(|name| name.to_string_lossy().ends_with(".partial.log"))
        {
            continue;
        }
        if std::fs::remove_file(&path).is_ok() {
            total = total.saturating_sub(size);
            debug!(log_path = %path.display(), bytes = size, "Removed oldest GPU diagnostic log to enforce storage cap");
        }
    }
}

fn finalize_gpu_diagnostic_log(path: &Path, preserve: bool) -> PathBuf {
    if preserve {
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            return path.to_path_buf();
        };
        if let Some(final_name) = name.strip_suffix(".partial.log") {
            let final_path = path.with_file_name(format!("{final_name}.log"));
            match std::fs::rename(path, &final_path) {
                Ok(()) => return final_path,
                Err(error) => {
                    warn!(log_path = %path.display(), %error, "Could not finalize GPU diagnostic log");
                }
            }
        }
    } else if let Err(error) = std::fs::remove_file(path) {
        if error.kind() != std::io::ErrorKind::NotFound {
            warn!(log_path = %path.display(), %error, "Could not remove successful GPU diagnostic log");
        }
    }
    path.to_path_buf()
}

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
            tokio::time::sleep(Duration::from_secs(3)).await;
            if GpuService::is_dual_gpu_enabled() {
                info!("Dual-GPU job lanes enabled: one rendition job per physical adapter");
                let rx = Self::run_adapter_lane(
                    pool.clone(),
                    roots.clone(),
                    cache_dir.clone(),
                    format!("{worker_id}-rx"),
                    "rx",
                    shutdown.clone(),
                );
                let vega = Self::run_adapter_lane(
                    pool,
                    roots,
                    cache_dir,
                    format!("{worker_id}-vega"),
                    "vega",
                    shutdown,
                );
                tokio::join!(rx, vega);
            } else {
                info!(
                    "Transcode worker [{}] started in single-RX fail-safe mode",
                    worker_id
                );
                Self::run_adapter_lane(pool, roots, cache_dir, worker_id, "rx", shutdown).await;
            }
        });
    }

    async fn run_adapter_lane(
        pool: PgPool,
        roots: Arc<Vec<PathBuf>>,
        cache_dir: Arc<PathBuf>,
        worker_id: String,
        lane: &'static str,
        shutdown: Arc<AtomicBool>,
    ) {
        while !shutdown.load(Ordering::SeqCst) {
            let telemetry_safe = GpuService::is_dual_gpu_enabled();
            if lane == "vega" && !telemetry_safe {
                tokio::time::sleep(Duration::from_secs(2)).await;
                continue;
            }
            match Self::process_next_job_for_adapter(
                &pool,
                &roots,
                &cache_dir,
                &worker_id,
                lane,
                lane == "rx" && !telemetry_safe,
                &shutdown,
            )
            .await
            {
                Ok(true) => {}
                Ok(false) => tokio::time::sleep(Duration::from_secs(2)).await,
                Err(e) => {
                    warn!("Transcode worker [{}] encountered error: {}", worker_id, e);
                    tokio::time::sleep(Duration::from_secs(3)).await;
                }
            }
        }
        info!("Transcode worker [{}] shutting down", worker_id);
    }

    async fn process_next_job_for_adapter(
        pool: &PgPool,
        roots: &[PathBuf],
        cache_dir: &Path,
        worker_id: &str,
        lane: &str,
        allow_720p_on_rx: bool,
        shutdown: &AtomicBool,
    ) -> Result<bool, AppError> {
        let job =
            match JobService::claim_next_for_adapter(pool, worker_id, 300, lane, allow_720p_on_rx)
                .await?
            {
                Some(job) => job,
                None => return Ok(false),
            };
        info!(
            "Worker [{}] claimed job #{} ({})",
            worker_id, job.id, job.mode
        );
        if let Err(e) = Self::execute_job(
            pool,
            roots,
            cache_dir,
            worker_id,
            &job,
            shutdown,
            Some(lane),
        )
        .await
        {
            error!("Worker [{}] failed job #{}: {}", worker_id, job.id, e);
            let _ = JobService::fail(pool, job.id, worker_id, &e.to_string()).await;
        }
        Ok(true)
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

        if let Err(e) =
            Self::execute_job(pool, roots, cache_dir, worker_id, &job, shutdown, None).await
        {
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
        adapter_lane: Option<&str>,
    ) -> Result<(), AppError> {
        let video_path = PathResolver::resolve_media_path(&job.filename, roots)
            .map_err(|e| AppError::NotFound(format!("Media file not found: {}", e)))?;

        // 1. Probe source properties
        let probe = ProbeService::probe(&video_path).await;
        let total_duration = ProbeService::source_video_duration(&video_path).await;

        if total_duration <= 0.0 {
            return Err(AppError::Internal(
                "Source video duration is zero or unreadable".into(),
            ));
        }

        // Determine quality tier and target height from job mode
        let (_job_type, target_height, quality_label) =
            ChunkTranscodeService::parse_job_mode(&job.mode);
        if adapter_lane == Some("vega") && !GpuService::is_dual_gpu_enabled() {
            return Err(AppError::Internal(
                "Vega job dispatch denied because dual-GPU thermal admission is unsafe".into(),
            ));
        }
        if job.mode.starts_with("hls:")
            && ChunkTranscodeService::normalize_quality_label(job.mode.trim_start_matches("hls:"))
                .is_none()
        {
            return Err(AppError::BadRequest(format!(
                "Unsupported transcode quality in queued job mode: {}",
                job.mode
            )));
        }
        let source_height = probe
            .first_stream("video")
            .and_then(|s| s.height)
            .unwrap_or(0) as u32;

        // Option 1C: If default baseline pre-transcode (mode "hls"), match native source resolution (up to 4K / 2160p)
        let (effective_target_height, effective_quality_label) = if job.mode.trim() == "hls"
            || target_height.is_none()
        {
            let (target_h, label) = if source_height >= 1800 {
                (2160, "2160p")
            } else if source_height >= 1200 {
                (1440, "1440p")
            } else if source_height >= 900 {
                (1080, "1080p")
            } else if source_height >= 600 {
                (720, "720p")
            } else {
                (source_height.max(1), "720p")
            };
            (Some(target_h), label.to_string())
        } else {
            // Strict no-upscaling: clamp target_height if it exceeds source_height (when source height is known)
            let th = match target_height {
                Some(th) if source_height > 0 && th > source_height => {
                    warn!(
                        "Job #{}: requested quality {} (height {}) exceeds source height {}; clamping to source height",
                        job.id, quality_label, th, source_height
                    );
                    Some(source_height)
                }
                other => other,
            };
            (th, quality_label)
        };

        let base_hls_dir = HlsService::find_hls_dir(&video_path, roots, cache_dir);
        let hls_dir =
            ChunkTranscodeService::get_quality_hls_dir(&base_hls_dir, &effective_quality_label);
        tokio::fs::create_dir_all(&hls_dir).await.map_err(|e| {
            AppError::Internal(format!("Failed to create HLS cache directory: {}", e))
        })?;

        let playlist_path = hls_dir.join("playlist.m3u8");

        // 2. Select AMF strategy and expand workers
        let (use_vpp_amf, _) =
            GpuService::select_amf_strategy(probe.first_stream("video"), effective_target_height);
        let base_gpus = GpuService::get_gpu_workers();
        let is_4k = effective_target_height.is_some_and(|h| h >= 2160)
            || effective_quality_label == "2160p";
        let dual_gpu_enabled = GpuService::is_dual_gpu_enabled();
        let effective_lane = adapter_lane.unwrap_or(
            if dual_gpu_enabled && effective_quality_label == "720p" && !is_4k {
                "vega"
            } else {
                "rx"
            },
        );
        let mut workers: Vec<GPUWorkerConfig> = {
            let selected = if effective_lane == "vega" {
                base_gpus.iter().find(|w| !w.is_discrete)
            } else {
                base_gpus.iter().find(|w| w.is_discrete)
            };
            selected.cloned().into_iter().collect()
        };
        if workers.is_empty() {
            return Err(AppError::Internal(format!(
                "No eligible physical GPU is available for adapter lane {:?}",
                adapter_lane
            )));
        }
        if is_4k || !dual_gpu_enabled {
            if workers.len() > 1 {
                if let Some(d) = workers.iter().find(|w| w.is_discrete).cloned() {
                    workers = vec![d];
                } else {
                    workers.truncate(1);
                }
            }
            if !workers.is_empty() {
                info!(
                    "Job #{}: transcode running on single dedicated GPU ({}) for thermal and driver stability",
                    job.id,
                    workers[0].name
                );
            }
        }

        info!(
            "Job #{}: duration={:.1}s, quality={}, height={:?}, vpp_amf={}, workers={} ({})",
            job.id,
            total_duration,
            effective_quality_label,
            effective_target_height,
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
        let _ = JobService::update_progress(
            pool,
            job.id,
            worker_id,
            Some(initial_pct),
            None,
            None,
            None,
        )
        .await;

        let start_time = Instant::now();
        let active_pids: Arc<Mutex<HashSet<u32>>> = Arc::new(Mutex::new(HashSet::new()));

        // Process chunks using an asynchronous work-pool across all GPU worker slots
        let pending_chunks_arc = Arc::new(pending_chunks);
        let next_chunk_idx = Arc::new(AtomicUsize::new(0));
        let cancel_requested = Arc::new(AtomicBool::new(false));
        let was_canceled = Arc::new(AtomicBool::new(false));
        let worker_error: Arc<Mutex<Option<AppError>>> = Arc::new(Mutex::new(None));

        // Background 1.5-second cadence progress monitor
        let job_done = Arc::new(AtomicBool::new(false));
        let job_done_clone = job_done.clone();
        let pool_clone = pool.clone();
        let base_hls_dir_clone = base_hls_dir.clone();
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

                if encoded_sec > 0.0 {
                    let _ = HlsService::update_master_playlist_file(&base_hls_dir_clone);
                }
            }
        });

        // Spawn independent asynchronous worker loops for each hardware GPU worker slot
        let transcode_job_id = job.id;
        let mut worker_tasks = Vec::new();
        for (w_idx, worker_cfg) in workers.iter().enumerate() {
            let worker_cfg = worker_cfg.clone();
            let v_path = video_path.clone();
            let h_dir = hls_dir.clone();
            let pids = active_pids.clone();
            let next_idx = next_chunk_idx.clone();
            let cancel = cancel_requested.clone();
            let err_slot = worker_error.clone();
            let pending_chunks_ref = pending_chunks_arc.clone();

            worker_tasks.push(tokio::spawn(async move {
                loop {
                    if cancel.load(Ordering::Relaxed) {
                        break;
                    }
                    {
                        let guard = err_slot.lock().await;
                        if guard.is_some() {
                            break;
                        }
                    }

                    let idx = next_idx.fetch_add(1, Ordering::SeqCst);
                    if idx >= pending_chunks_ref.len() {
                        break;
                    }

                    let chunk = &pending_chunks_ref[idx];
                    if dual_gpu_enabled {
                        while !crate::services::gpu_thermal::adapter_temperature_safe(
                            worker_cfg.is_discrete,
                        ) {
                            if cancel.load(Ordering::Relaxed) {
                                break;
                            }
                            tokio::time::sleep(Duration::from_secs(5)).await;
                        }
                        if cancel.load(Ordering::Relaxed) {
                            break;
                        }
                    }
                    let chunk_res = Self::execute_single_chunk(
                        transcode_job_id,
                        &v_path,
                        &h_dir,
                        chunk,
                        &worker_cfg,
                        use_vpp_amf,
                        effective_target_height,
                        dual_gpu_enabled,
                        pids.clone(),
                    )
                    .await;

                    if let Err(e) = chunk_res {
                        error!(
                            "Worker slot {} ({}) failed chunk {}: {:?}",
                            w_idx, worker_cfg.name, chunk.chunk_id, e
                        );
                        let mut guard = err_slot.lock().await;
                        if guard.is_none() {
                            *guard = Some(e);
                        }
                        break;
                    }

                    // Inter-chunk thermal breather to prevent monotonic heat accumulation and VRM over-temp
                    let breather_ms: u64 = std::env::var("MEDIA_SERVER_CHUNK_BREATHER_MS")
                        .ok()
                        .and_then(|v| v.parse().ok())
                        .unwrap_or(1000);
                    if breather_ms > 0 {
                        tokio::time::sleep(Duration::from_millis(breather_ms)).await;
                    }
                }
            }));
        }

        let was_canceled_clone = was_canceled.clone();
        let cancel_requested_clone = cancel_requested.clone();
        let active_pids_clone = active_pids.clone();

        let run_result: Result<(), AppError> = async {
            let mut last_lease_renew = Instant::now();

            loop {
                // Check if any worker encountered an error
                {
                    let guard = worker_error.lock().await;
                    if let Some(err) = guard.as_ref() {
                        cancel_requested_clone.store(true, Ordering::Relaxed);
                        return Err(AppError::Internal(format!("Worker failed: {}", err)));
                    }
                }

                // Check if all worker tasks finished
                let all_finished = worker_tasks.iter().all(|t| t.is_finished());
                if all_finished {
                    for t in worker_tasks {
                        if let Err(join_err) = t.await {
                            return Err(AppError::Internal(format!(
                                "Worker task join error: {}",
                                join_err
                            )));
                        }
                    }
                    let guard = worker_error.lock().await;
                    if let Some(err) = guard.as_ref() {
                        return Err(AppError::Internal(format!("Worker failed: {}", err)));
                    }
                    break;
                }

                tokio::time::sleep(Duration::from_millis(1500)).await;

                if shutdown.load(Ordering::SeqCst) {
                    cancel_requested_clone.store(true, Ordering::Relaxed);
                    return Err(AppError::Internal(
                        "Worker interrupted by server shutdown".into(),
                    ));
                }

                // Check if job was cancelled in DB
                if let Ok(Some(current)) = JobService::get_by_id(pool, job.id).await {
                    if current.status == "canceled" {
                        info!("Job #{} was canceled; stopping execution", job.id);
                        was_canceled_clone.store(true, Ordering::Relaxed);
                        cancel_requested_clone.store(true, Ordering::Relaxed);
                        // Abort active FFmpeg child processes immediately
                        for pid in active_pids_clone.lock().await.iter() {
                            let _ = std::process::Command::new("taskkill")
                                .args(["/PID", &pid.to_string(), "/F", "/T"])
                                .output();
                        }
                        return Ok(());
                    }
                }

                // Renew lease every 45s
                if last_lease_renew.elapsed() > Duration::from_secs(45) {
                    let renewed = JobService::renew_lease(pool, job.id, worker_id, 300).await?;
                    if !renewed {
                        cancel_requested_clone.store(true, Ordering::Relaxed);
                        return Err(AppError::Internal(
                            "Lost lease ownership of transcode job".into(),
                        ));
                    }
                    last_lease_renew = Instant::now();
                }
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

        if was_canceled.load(Ordering::Relaxed) {
            info!(
                "Job #{} was canceled; skipping final playlist publish",
                job.id
            );
            return Ok(());
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
        let _ = HlsService::update_master_playlist_file(&base_hls_dir);
        JobService::complete(pool, job.id, worker_id).await?;

        info!("Job #{} successfully completed and published", job.id);
        Ok(())
    }

    /// Spawns FFmpeg subprocess to render one chunk.
    // This orchestration boundary keeps the media, adapter, quality, and PID
    // tracking inputs explicit for each isolated FFmpeg chunk.
    #[allow(clippy::too_many_arguments)]
    async fn execute_single_chunk(
        job_id: i64,
        video_path: &Path,
        hls_dir: &Path,
        chunk: &TranscodeChunk,
        worker: &GPUWorkerConfig,
        use_vpp_amf: bool,
        target_height: Option<u32>,
        thermal_guarded: bool,
        active_pids: Arc<Mutex<HashSet<u32>>>,
    ) -> Result<(), AppError> {
        let chunk_pl_name = format!("chunk_{}.m3u8", chunk.chunk_id);
        let init_name = format!("init_chunk_{}.mp4", chunk.chunk_id);
        let (diagnostic_path, diagnostic_file) = create_gpu_diagnostic_log(job_id, worker, chunk)
            .map_err(|error| {
                AppError::Internal(format!(
                    "Could not create GPU diagnostic log for job #{job_id}, adapter {} ({}), chunk {}: {error}",
                    worker.adapter_id, worker.name, chunk.chunk_id
                ))
            })?;

        let mut cmd = tokio::process::Command::new("ffmpeg");
        cmd.current_dir(hls_dir);
        cmd.arg("-hide_banner")
            .arg("-loglevel")
            .arg("info")
            .arg("-y");

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

        // Video encoding args with dynamic scaling
        for arg in worker.get_ffmpeg_video_args(use_vpp_amf, target_height) {
            cmd.arg(arg);
        }

        // Audio args (standard stereo AAC 192k) + disable subtitle muxing into chunks
        cmd.arg("-c:a")
            .arg("aac")
            .arg("-b:a")
            .arg("192k")
            .arg("-ac")
            .arg("2")
            .arg("-sn");

        // HLS output container args: Fragmented MP4 (fMP4)
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
            .arg("-hls_segment_type")
            .arg("fmp4")
            .arg("-hls_fmp4_init_filename")
            .arg(&init_name)
            .arg("-start_number")
            .arg(chunk.start_seg.to_string())
            .arg("-hls_segment_filename")
            .arg("segment_%06d.m4s")
            .arg("-nostats")
            .arg(&chunk_pl_name);

        cmd.stdout(std::process::Stdio::null());
        cmd.stderr(std::process::Stdio::piped());

        #[cfg(windows)]
        cmd.creation_flags(0x00004000); // BELOW_NORMAL_PRIORITY_CLASS

        let mut child = match cmd.spawn() {
            Ok(child) => child,
            Err(error) => {
                finalize_gpu_diagnostic_log(&diagnostic_path, false);
                return Err(AppError::Internal(format!(
                    "Failed to spawn FFmpeg for job #{job_id}, adapter {} ({}), chunk {}: {error}",
                    worker.adapter_id, worker.name, chunk.chunk_id
                )));
            }
        };

        let child_pid = child.id();
        info!(
            job_id,
            adapter_id = worker.adapter_id,
            adapter = %worker.name,
            chunk_id = chunk.chunk_id,
            start_seconds = chunk.start_time,
            duration_seconds = chunk.duration,
            pid = ?child_pid,
            log_path = %diagnostic_path.display(),
            "Started FFmpeg chunk on GPU adapter"
        );
        let Some(stderr) = child.stderr.take() else {
            finalize_gpu_diagnostic_log(&diagnostic_path, true);
            return Err(AppError::Internal(format!(
                "FFmpeg stderr capture unavailable for job #{job_id}, adapter {} ({}), chunk {}",
                worker.adapter_id, worker.name, chunk.chunk_id
            )));
        };
        let diagnostic_file = tokio::fs::File::from_std(diagnostic_file);
        let stderr_task =
            tokio::spawn(async move { persist_ffmpeg_stderr(stderr, diagnostic_file).await });
        if let Some(pid) = child_pid {
            active_pids.lock().await.insert(pid);
        }

        // Bounded per-chunk timeout (180s) to guard against GPU driver deadlocks
        let timeout_duration = Duration::from_secs(180);
        let mut wait = Box::pin(async {
            loop {
                match child.try_wait() {
                    Ok(Some(status)) => return Ok::<_, std::io::Error>(status),
                    Ok(None) => tokio::time::sleep(Duration::from_millis(100)).await,
                    Err(error) => return Err(error),
                }
            }
        });
        let output_result = if thermal_guarded {
            tokio::select! {
                result = tokio::time::timeout(timeout_duration, &mut wait) => result,
                _ = async {
                    loop {
                        tokio::time::sleep(Duration::from_secs(2)).await;
                        if crate::services::gpu_thermal::critical_temperature_or_sensor_loss(worker.is_discrete) {
                            break;
                        }
                    }
                } => {
                    if let Some(pid) = child_pid {
                        let _ = std::process::Command::new("taskkill")
                            .args(["/PID", &pid.to_string(), "/F", "/T"])
                            .output();
                    }
                    let _ = tokio::time::timeout(Duration::from_secs(5), &mut wait).await;
                    if let Some(pid) = child_pid {
                        active_pids.lock().await.remove(&pid);
                    }
                    let stderr_error = finish_ffmpeg_stderr_capture(stderr_task).await;
                    let retained_path = finalize_gpu_diagnostic_log(&diagnostic_path, true);
                    let stderr_tail = read_ffmpeg_log_tail(&retained_path);
                    error!(
                        job_id,
                        adapter_id = worker.adapter_id,
                        adapter = %worker.name,
                        chunk_id = chunk.chunk_id,
                        pid = ?child_pid,
                        log_path = %retained_path.display(),
                        stderr_capture_error = ?stderr_error,
                        stderr_tail = %stderr_tail,
                        "Stopped GPU FFmpeg chunk because temperature reached the critical limit or HWiNFO telemetry was lost"
                    );
                    return Err(AppError::Internal(format!(
                        "Critical GPU temperature or sensor loss on {}; stopped job #{job_id} chunk {} (FFmpeg diagnostics: {})",
                        worker.name, chunk.chunk_id, retained_path.display()
                    )));
                }
            }
        } else {
            tokio::time::timeout(timeout_duration, &mut wait).await
        };
        let status = match output_result {
            Ok(Ok(status)) => status,
            Ok(Err(e)) => {
                if let Some(pid) = child_pid {
                    active_pids.lock().await.remove(&pid);
                }
                let stderr_error = finish_ffmpeg_stderr_capture(stderr_task).await;
                let retained_path = finalize_gpu_diagnostic_log(&diagnostic_path, true);
                let stderr_tail = read_ffmpeg_log_tail(&retained_path);
                error!(
                    job_id,
                    adapter_id = worker.adapter_id,
                    adapter = %worker.name,
                    chunk_id = chunk.chunk_id,
                    pid = ?child_pid,
                    log_path = %retained_path.display(),
                    stderr_capture_error = ?stderr_error,
                    stderr_tail = %stderr_tail,
                    %e,
                    "Error while waiting for GPU FFmpeg chunk"
                );
                return Err(AppError::Internal(format!(
                    "FFmpeg wait error on job #{job_id}, adapter {} ({}), chunk {}: {} (diagnostics: {})",
                    worker.adapter_id, worker.name, chunk.chunk_id, e, retained_path.display()
                )));
            }
            Err(_) => {
                // Timeout elapsed - kill child process to release GPU contexts
                if let Some(pid) = child_pid {
                    let _ = std::process::Command::new("taskkill")
                        .args(["/PID", &pid.to_string(), "/F", "/T"])
                        .output();
                }
                let _ = tokio::time::timeout(Duration::from_secs(5), &mut wait).await;
                if let Some(pid) = child_pid {
                    active_pids.lock().await.remove(&pid);
                }
                let stderr_error = finish_ffmpeg_stderr_capture(stderr_task).await;
                let retained_path = finalize_gpu_diagnostic_log(&diagnostic_path, true);
                let stderr_tail = read_ffmpeg_log_tail(&retained_path);
                error!(
                    job_id,
                    adapter_id = worker.adapter_id,
                    adapter = %worker.name,
                    chunk_id = chunk.chunk_id,
                    pid = ?child_pid,
                    timeout_seconds = timeout_duration.as_secs(),
                    log_path = %retained_path.display(),
                    stderr_capture_error = ?stderr_error,
                    stderr_tail = %stderr_tail,
                    "GPU FFmpeg chunk timed out; possible driver hang or TDR"
                );
                return Err(AppError::Internal(format!(
                    "Job #{job_id} chunk {} on {} timed out after {}s (possible GPU hang/TDR; diagnostics: {})",
                    chunk.chunk_id,
                    worker.name,
                    timeout_duration.as_secs(),
                    retained_path.display()
                )));
            }
        };

        if let Some(pid) = child_pid {
            active_pids.lock().await.remove(&pid);
        }

        let stderr_error = finish_ffmpeg_stderr_capture(stderr_task).await;

        if !status.success() {
            let retained_path = finalize_gpu_diagnostic_log(&diagnostic_path, true);
            let stderr_text = read_ffmpeg_log_tail(&retained_path);
            let last_err = stderr_text
                .lines()
                .rfind(|l| !l.trim().is_empty())
                .unwrap_or("unknown FFmpeg failure");

            error!(
                job_id,
                adapter_id = worker.adapter_id,
                adapter = %worker.name,
                chunk_id = chunk.chunk_id,
                exit_code = ?status.code(),
                log_path = %retained_path.display(),
                stderr_capture_error = ?stderr_error,
                stderr_tail = %stderr_text,
                "AMF/GPU FFmpeg chunk failed; full stderr was retained in the diagnostic file"
            );

            return Err(AppError::Internal(format!(
                "Job #{job_id} chunk {} failed on adapter {} ({}): {} (diagnostics: {})",
                chunk.chunk_id,
                worker.adapter_id,
                worker.name,
                last_err,
                retained_path.display()
            )));
        }

        if let Some(error) = stderr_error.as_deref() {
            error!(
                job_id,
                adapter_id = worker.adapter_id,
                adapter = %worker.name,
                chunk_id = chunk.chunk_id,
                log_path = %diagnostic_path.display(),
                capture_error = error,
                "GPU FFmpeg completed, but stderr capture reported an error; diagnostic file retained"
            );
        }

        // Validate chunk produced usable output
        if !ChunkTranscodeService::chunk_output_ok(hls_dir, chunk) {
            let retained_path = finalize_gpu_diagnostic_log(&diagnostic_path, true);
            error!(
                job_id,
                adapter_id = worker.adapter_id,
                adapter = %worker.name,
                chunk_id = chunk.chunk_id,
                log_path = %retained_path.display(),
                "GPU FFmpeg exited successfully but its output failed validation; diagnostics retained"
            );
            return Err(AppError::Internal(format!(
                "Job #{job_id} chunk {} on adapter {} ({}) failed output verification (diagnostics: {})",
                chunk.chunk_id, worker.adapter_id, worker.name, retained_path.display()
            )));
        }

        // Stamp monotonic tfdt timestamps into fMP4 segments so timeline is continuous across chunks
        let _ = ChunkTranscodeService::stamp_chunk_segments_tfdt(
            hls_dir,
            chunk.chunk_id,
            chunk.start_time,
            chunk.start_seg,
        );

        finalize_gpu_diagnostic_log(&diagnostic_path, stderr_error.is_some());
        debug!(
            job_id,
            adapter_id = worker.adapter_id,
            adapter = %worker.name,
            chunk_id = chunk.chunk_id,
            "GPU FFmpeg chunk completed and passed output validation"
        );

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::gpu_service::GpuBackend;
    use crate::services::gpu_thermal::{dual_gpu_thermal_safe, read_temperatures, ThermalStatus};

    #[tokio::test]
    #[ignore = "requires both Radeon AMF adapters and fresh HWiNFO shared-memory temperatures"]
    async fn live_dual_gpu_chunk_transcode_and_diagnostic_capture() {
        assert!(
            dual_gpu_thermal_safe(),
            "dual-GPU thermal gate must be safe"
        );
        let workers = GpuService::detect_available_gpus(true);
        let rx = workers
            .iter()
            .find(|worker| worker.adapter_id == 1 && worker.backend == GpuBackend::Amf)
            .expect("RX 560X AMF adapter should be available")
            .clone();
        let vega = workers
            .iter()
            .find(|worker| worker.adapter_id == 0 && worker.backend == GpuBackend::Amf)
            .expect("Vega 8 AMF adapter should be available")
            .clone();

        let test_id = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("Rust crate should be inside the repository")
            .to_path_buf();
        let scratch = repo_root
            .join("cache/release-build/dual-gpu-validation/scratch")
            .join(format!("app-dual-gpu-{test_id}"));
        let logs = scratch.join("gpu-logs");
        let source = scratch.join("synthetic-source.mp4");
        let rx_output = scratch.join("rx-560x");
        let vega_output = scratch.join("vega-8");
        std::fs::create_dir_all(&rx_output).unwrap();
        std::fs::create_dir_all(&vega_output).unwrap();

        let old_log_dir = std::env::var_os("MEDIA_SERVER_GPU_LOG_DIR");
        std::env::set_var("MEDIA_SERVER_GPU_LOG_DIR", &logs);
        let source_status = std::process::Command::new("ffmpeg")
            .args([
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                "testsrc2=size=1280x720:rate=24:duration=3",
                "-frames:v",
                "72",
                "-c:v",
                "mpeg4",
                "-q:v",
                "5",
                "-an",
            ])
            .arg(&source)
            .status()
            .expect("FFmpeg should generate the synthetic scratch source");
        assert!(
            source_status.success(),
            "synthetic FFmpeg source generation failed"
        );

        let chunk = TranscodeChunk {
            chunk_id: 0,
            start_time: 0.0,
            duration: 3.0,
            start_seg: 0,
            expected_segs: 1,
        };
        let active_rx = Arc::new(Mutex::new(HashSet::new()));
        let active_vega = Arc::new(Mutex::new(HashSet::new()));
        let (rx_result, vega_result) = tokio::join!(
            TranscodeWorker::execute_single_chunk(
                9_000_001,
                &source,
                &rx_output,
                &chunk,
                &rx,
                false,
                Some(720),
                true,
                active_rx,
            ),
            TranscodeWorker::execute_single_chunk(
                9_000_002,
                &source,
                &vega_output,
                &chunk,
                &vega,
                false,
                Some(720),
                true,
                active_vega,
            )
        );

        std::env::remove_var("MEDIA_SERVER_GPU_LOG_DIR");
        if let Some(old) = old_log_dir {
            std::env::set_var("MEDIA_SERVER_GPU_LOG_DIR", old);
        }

        assert!(rx_result.is_ok(), "RX 560X chunk failed: {rx_result:?}");
        assert!(vega_result.is_ok(), "Vega 8 chunk failed: {vega_result:?}");
        assert!(ChunkTranscodeService::chunk_output_ok(&rx_output, &chunk));
        assert!(ChunkTranscodeService::chunk_output_ok(&vega_output, &chunk));
        assert!(
            std::fs::read_dir(&logs)
                .map(|mut entries| entries.next().is_none())
                .unwrap_or(true),
            "successful chunks should remove their temporary stderr logs"
        );
        match read_temperatures() {
            ThermalStatus::Safe(temps) => eprintln!(
                "Concurrent app chunk test temperatures: RX 560X={:.1}C, Vega 8={:.1}C, age={}s",
                temps.rx560x_c, temps.vega8_c, temps.age_secs
            ),
            ThermalStatus::Unsafe(reason) => panic!("HWiNFO readings became unsafe: {reason}"),
        }
    }

    #[tokio::test]
    async fn ffmpeg_stderr_capture_is_bounded_and_marks_truncation() {
        let test_id = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "media-server-gpu-log-test-{}-{test_id}",
            std::process::id()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("stderr.log");
        let file = tokio::fs::File::create(&path).await.unwrap();
        let (mut writer, reader) = tokio::io::duplex(16 * 1024);
        let input = vec![b'x'; GPU_DIAGNOSTIC_MAX_FILE_BYTES as usize + 1024];
        let producer = tokio::spawn(async move {
            writer.write_all(&input).await.unwrap();
        });

        persist_ffmpeg_stderr(reader, file).await.unwrap();
        producer.await.unwrap();

        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(bytes.len() as u64, GPU_DIAGNOSTIC_MAX_FILE_BYTES);
        assert!(bytes.ends_with(GPU_DIAGNOSTIC_TRUNCATION_MARKER));
        std::fs::remove_dir_all(directory).unwrap();
    }
}
