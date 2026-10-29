//! Hardware GPU detection, AMF hardware encoding validation, and multi-adapter worker management.
//!
//! Mirrors `app/services/gpu_service.py` to provide native dual-GPU (AMD Radeon RX 560X discrete `dx11:1`
//! and AMD Radeon Vega 8 integrated `dx11:0`) orchestration in Rust.

use crate::services::probe_service::ProbeStream;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tracing::{debug, info};

/// Subprocess priority level for GPU and CPU media processing tasks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum SubprocessPriority {
    /// Interactive user playback (live chunk transcoding, HLS stream generation).
    InteractivePlayback = 0,
    /// Fast user-facing media inspection (ffprobe metadata querying).
    InteractiveProbe = 1,
    /// Background asset generation (seek preview frames, subtitle classification).
    BackgroundExtract = 2,
    /// Bulk offline transcoding and caching worker.
    BackgroundPreTranscode = 3,
}

/// Deterministic kill-on-drop process supervisor guard.
///
/// Ensures child processes spawned by ffmpeg/ffprobe do not linger as orphaned
/// zombie processes if an HTTP connection aborts, a task times out, or the guard drops.
pub struct ProcessGuard {
    child: Option<tokio::process::Child>,
    pub pid: Option<u32>,
    _permit: Option<OwnedSemaphorePermit>,
}

impl ProcessGuard {
    pub fn new(child: tokio::process::Child, permit: Option<OwnedSemaphorePermit>) -> Self {
        let pid = child.id();
        Self {
            child: Some(child),
            pid,
            _permit: permit,
        }
    }

    pub fn inner_mut(&mut self) -> Option<&mut tokio::process::Child> {
        self.child.as_mut()
    }

    pub async fn wait(&mut self) -> std::io::Result<std::process::ExitStatus> {
        if let Some(mut child) = self.child.take() {
            child.wait().await
        } else {
            Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                "Process already waited or terminated",
            ))
        }
    }

    pub async fn kill(&mut self) -> std::io::Result<()> {
        if let Some(mut child) = self.child.take() {
            let res = child.start_kill();
            #[cfg(windows)]
            if let Some(pid) = self.pid {
                let _ = std::process::Command::new("taskkill")
                    .args(["/F", "/T", "/PID", &pid.to_string()])
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status();
            }
            res
        } else {
            Ok(())
        }
    }
}

impl Drop for ProcessGuard {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            if let Ok(None) = child.try_wait() {
                let _ = child.start_kill();
                #[cfg(windows)]
                if let Some(pid) = self.pid {
                    let _ = std::process::Command::new("taskkill")
                        .args(["/F", "/T", "/PID", &pid.to_string()])
                        .stdout(std::process::Stdio::null())
                        .stderr(std::process::Stdio::null())
                        .status();
                }
            }
        }
    }
}

static PLAYBACK_SEMAPHORE: OnceLock<Arc<Semaphore>> = OnceLock::new();
static BACKGROUND_SEMAPHORE: OnceLock<Arc<Semaphore>> = OnceLock::new();

fn playback_semaphore() -> Arc<Semaphore> {
    PLAYBACK_SEMAPHORE
        .get_or_init(|| Arc::new(Semaphore::new(4)))
        .clone()
}

fn background_semaphore() -> Arc<Semaphore> {
    BACKGROUND_SEMAPHORE
        .get_or_init(|| Arc::new(Semaphore::new(2)))
        .clone()
}

pub const HLS_MAX_HEIGHT: i64 = 1080;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum GpuBackend {
    Amf,
    Vaapi,
    Cpu,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct GPUWorkerConfig {
    pub adapter_id: u32,
    pub name: String,
    pub backend: GpuBackend,
    pub is_discrete: bool,
}

impl GPUWorkerConfig {
    /// Return FFmpeg input / device initialization arguments.
    pub fn get_ffmpeg_init_args(&self) -> Vec<String> {
        match self.backend {
            GpuBackend::Amf => vec![
                "-init_hw_device".into(),
                format!("d3d11va=dx11:{}", self.adapter_id),
                "-init_hw_device".into(),
                "amf=amf@dx11".into(),
                "-filter_hw_device".into(),
                "amf".into(),
                "-hwaccel".into(),
                "d3d11va".into(),
                "-hwaccel_device".into(),
                self.adapter_id.to_string(),
            ],
            GpuBackend::Vaapi => {
                let dev = std::env::var("MEDIA_SERVER_VAAPI_DEVICE")
                    .unwrap_or_else(|_| "/dev/dri/renderD128".into());
                vec![
                    "-vaapi_device".into(),
                    dev.clone(),
                    "-hwaccel".into(),
                    "vaapi".into(),
                    "-hwaccel_device".into(),
                    dev,
                ]
            }
            GpuBackend::Cpu => Vec::new(),
        }
    }

    /// Return FFmpeg video encoder arguments.
    ///
    /// `use_vpp_amf=false` drops the vpp_amf scaling stage and lets the D3D11VA decoder
    /// feed the encoder directly. That is only valid when the source needs neither a resize
    /// nor a depth change: h264_amf cannot accept 10-bit on drivers older than 23.30,
    /// and a source taller than the target profile would be emitted at full height.
    pub fn get_ffmpeg_video_args(
        &self,
        use_vpp_amf: bool,
        target_height: Option<u32>,
    ) -> Vec<String> {
        let height = target_height.unwrap_or(HLS_MAX_HEIGHT as u32);
        let is_4k = height >= 2160;
        match self.backend {
            GpuBackend::Amf => {
                let vf = if use_vpp_amf {
                    format!("vpp_amf=h='min({},ih)':w=-2:format=nv12", height)
                } else {
                    "null".to_string()
                };
                let quality =
                    std::env::var("MEDIA_SERVER_AMF_QUALITY").unwrap_or_else(|_| "speed".into());
                let qp_i = std::env::var("MEDIA_SERVER_AMF_QP_I").unwrap_or_else(|_| "22".into());
                let qp_p = std::env::var("MEDIA_SERVER_AMF_QP_P").unwrap_or_else(|_| "24".into());

                let mut args = vec![
                    "-vf".into(),
                    vf,
                    "-c:v".into(),
                    if is_4k {
                        "hevc_amf".into()
                    } else {
                        "h264_amf".into()
                    },
                ];
                if is_4k {
                    args.push("-tag:v".into());
                    args.push("hvc1".into());
                }
                args.extend([
                    "-quality".into(),
                    quality,
                    "-rc".into(),
                    "cqp".into(),
                    "-qp_i".into(),
                    qp_i,
                    "-qp_p".into(),
                    qp_p,
                ]);
                args
            }
            GpuBackend::Vaapi => {
                let qp = std::env::var("MEDIA_SERVER_VAAPI_QP").unwrap_or_else(|_| "24".into());
                let mut args = vec![
                    "-vf".into(),
                    format!("format=nv12,hwupload,scale_vaapi=w=-2:h={}", height),
                    "-c:v".into(),
                    if is_4k {
                        "hevc_vaapi".into()
                    } else {
                        "h264_vaapi".into()
                    },
                ];
                if is_4k {
                    args.push("-tag:v".into());
                    args.push("hvc1".into());
                }
                args.extend(["-qp".into(), qp, "-pix_fmt".into(), "nv12".into()]);
                args
            }
            GpuBackend::Cpu => {
                let preset = std::env::var("MEDIA_SERVER_TRANSCODE_PRESET")
                    .unwrap_or_else(|_| "superfast".into());
                let crf =
                    std::env::var("MEDIA_SERVER_TRANSCODE_CRF").unwrap_or_else(|_| "23".into());
                let mut args = vec![
                    "-vf".into(),
                    format!("scale=-2:'min(ih,{})',format=yuv420p", height),
                    "-c:v".into(),
                    if is_4k {
                        "libx265".into()
                    } else {
                        "libx264".into()
                    },
                ];
                if is_4k {
                    args.push("-tag:v".into());
                    args.push("hvc1".into());
                }
                args.extend([
                    "-preset".into(),
                    preset,
                    "-crf".into(),
                    crf,
                    "-pix_fmt".into(),
                    "yuv420p".into(),
                ]);
                args
            }
        }
    }
}

static CACHED_GPUS: OnceLock<Mutex<Option<Vec<GPUWorkerConfig>>>> = OnceLock::new();

fn gpu_cache() -> &'static Mutex<Option<Vec<GPUWorkerConfig>>> {
    CACHED_GPUS.get_or_init(|| Mutex::new(None))
}

pub struct GpuService;

impl GpuService {
    /// Test whether a specific D3D11 adapter supports AMF h264 encoding.
    pub fn probe_d3d11_adapter(adapter_idx: u32) -> Option<GPUWorkerConfig> {
        let ffmpeg = "ffmpeg";
        let mut cmd = std::process::Command::new(ffmpeg);
        cmd.args([
            "-hide_banner",
            "-init_hw_device",
            &format!("d3d11va=dx11:{}", adapter_idx),
            "-f",
            "lavfi",
            "-i",
            "color=s=256x256:d=0.08",
            "-c:v",
            "h264_amf",
            "-f",
            "null",
            "-",
        ]);
        cmd.stdout(std::process::Stdio::null());
        cmd.stderr(std::process::Stdio::piped());

        // Spawn and check with bounded timeout
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                debug!(
                    "Cannot spawn ffmpeg to probe D3D11 adapter {}: {}",
                    adapter_idx, e
                );
                return None;
            }
        };

        let start = std::time::Instant::now();
        let timeout = Duration::from_secs(8);

        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break status,
                Ok(None) => {
                    if start.elapsed() > timeout {
                        let _ = child.kill();
                        return None;
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
                Err(_) => return None,
            }
        };

        if status.success() {
            let mut stderr_bytes = Vec::new();
            if let Some(mut err_pipe) = child.stderr.take() {
                use std::io::Read;
                let _ = err_pipe.read_to_end(&mut stderr_bytes);
            }
            let stderr_text = String::from_utf8_lossy(&stderr_bytes);

            // Extract device name e.g. "Using device 1002:67df (Radeon RX 560X Series)"
            let name = if let Some(cap) = stderr_text.lines().find_map(|line| {
                if let Some(idx) = line.find("Using device ") {
                    let rest = &line[idx + 13..];
                    if let (Some(open), Some(close)) = (rest.find('('), rest.rfind(')')) {
                        if open < close {
                            return Some(rest[open + 1..close].trim().to_string());
                        }
                    }
                }
                None
            }) {
                cap
            } else {
                format!("D3D11 Adapter {}", adapter_idx)
            };

            let name_lower = name.to_lowercase();
            let is_discrete = name_lower.contains("rx ")
                || name_lower.contains("rtx")
                || name_lower.contains("geforce")
                || name_lower.contains("radeon rx")
                || name_lower.contains("dedicated");

            Some(GPUWorkerConfig {
                adapter_id: adapter_idx,
                name,
                backend: GpuBackend::Amf,
                is_discrete,
            })
        } else {
            None
        }
    }

    /// Enumerate hardware encoding adapters available on the host.
    pub fn detect_available_gpus(force_refresh: bool) -> Vec<GPUWorkerConfig> {
        let lock = gpu_cache();
        let mut guard = lock.lock().unwrap();

        if !force_refresh {
            if let Some(cached) = &*guard {
                return cached.clone();
            }
        }

        let mut gpus = Vec::new();

        if cfg!(windows) {
            // Check adapters 1 (Discrete) and 0 (Integrated)
            for idx in [1, 0] {
                if let Some(cfg) = Self::probe_d3d11_adapter(idx) {
                    gpus.push(cfg);
                }
            }
        }

        // Sort so discrete GPU is first (highest throughput priority), integrated second
        gpus.sort_by_key(|g| (!g.is_discrete, g.adapter_id != 1));

        info!(
            "Detected {} hardware GPU encoder(s): {:?}",
            gpus.len(),
            gpus.iter().map(|g| &g.name).collect::<Vec<_>>()
        );

        *guard = Some(gpus.clone());
        gpus
    }

    /// Return the ordered list of GPU workers for chunk assignment.
    pub fn get_gpu_workers() -> Vec<GPUWorkerConfig> {
        let gpus = Self::detect_available_gpus(false);
        if gpus.is_empty() {
            vec![GPUWorkerConfig {
                adapter_id: 0,
                name: "CPU Encoder".into(),
                backend: GpuBackend::Cpu,
                is_discrete: false,
            }]
        } else {
            gpus
        }
    }

    /// Check if dual-GPU chunked transcoding is enabled and supported.
    pub fn is_dual_gpu_enabled() -> bool {
        let enabled = std::env::var("MEDIA_SERVER_ENABLE_DUAL_GPU")
            .map(|v| matches!(v.to_lowercase().as_str(), "1" | "true" | "yes"))
            .unwrap_or(true);
        if !enabled {
            return false;
        }
        Self::detect_available_gpus(false).len() >= 2
    }

    /// True when per-source pipeline/worker selection is switched on.
    pub fn adaptive_strategy_enabled() -> bool {
        std::env::var("MEDIA_SERVER_TRANSCODE_STRATEGY")
            .map(|v| matches!(v.to_lowercase().as_str(), "adaptive" | "1" | "true" | "yes"))
            .unwrap_or(true)
    }

    /// True for 10-bit or higher bit-depth pixel formats (e.g. p010, yuv420p10, yuv422p10, yuv420p12),
    /// which h264_amf cannot accept directly on AMD GPU drivers (< 23.30).
    pub fn is_ten_bit(pix_fmt: Option<&str>) -> bool {
        let p = pix_fmt.unwrap_or("").to_lowercase();
        if p.is_empty() || p == "nv12" || p == "nv21" {
            return false;
        }
        p.contains("10")
            || p.contains("p016")
            || p.contains("12le")
            || p.contains("12be")
            || p.contains("14le")
            || p.contains("14be")
            || p.contains("16le")
            || p.contains("16be")
    }

    /// Return `(use_vpp_amf, worker_count)` for one source's video stream and optional target height.
    ///
    /// `use_vpp_amf` is required - never merely beneficial - whenever the source
    /// is 10-bit or taller than the target profile.
    pub fn select_amf_strategy(
        video_stream: Option<&ProbeStream>,
        target_height: Option<u32>,
    ) -> (bool, usize) {
        let height = video_stream.and_then(|s| s.height).unwrap_or(0);
        let ten_bit = Self::is_ten_bit(video_stream.and_then(|s| s.pix_fmt.as_deref()));
        let target_h = target_height.unwrap_or(HLS_MAX_HEIGHT as u32) as i64;

        let unknown = height <= 0;
        let needs_vpp = unknown || ten_bit || height > target_h;

        let count: usize = if target_h >= 2160 {
            // For 4K (2160p), constrain to 1 dedicated worker to prevent dual-GPU bus contention
            // and driver deadlocks on mobile APU/dGPU architectures.
            std::env::var("MEDIA_SERVER_TRANSCODE_WORKERS_4K")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(1)
        } else if needs_vpp || target_h >= 1440 {
            std::env::var("MEDIA_SERVER_TRANSCODE_WORKERS_MAIN10")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(2)
        } else {
            std::env::var("MEDIA_SERVER_TRANSCODE_WORKERS_8BIT")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(2)
        };

        (needs_vpp, count.max(1))
    }

    /// Expand one worker per GPU into `count` workers, weighted to the discrete GPU.
    pub fn expand_workers(workers: &[GPUWorkerConfig], count: usize) -> Vec<GPUWorkerConfig> {
        if workers.is_empty() {
            return Vec::new();
        }
        if count <= 1 {
            if let Some(d) = workers.iter().find(|w| w.is_discrete) {
                return vec![d.clone()];
            }
            return workers[..1].to_vec();
        }

        let discrete: Vec<_> = workers.iter().filter(|w| w.is_discrete).cloned().collect();
        let integrated: Vec<_> = workers.iter().filter(|w| !w.is_discrete).cloned().collect();

        let mut plan: Vec<GPUWorkerConfig> = Vec::new();
        if !discrete.is_empty() {
            let mut remaining = count;
            for w in &integrated {
                if remaining == 0 {
                    break;
                }
                plan.push(w.clone());
                remaining -= 1;
            }
            let primary = &discrete[0];
            for _ in 0..remaining {
                plan.push(primary.clone());
            }
            if plan.len() < integrated.len() {
                for w in &integrated[plan.len()..] {
                    plan.push(w.clone());
                }
            }
        } else {
            for _ in 0..count {
                plan.push(workers[0].clone());
            }
        }

        let mut out = Vec::new();
        let mut seen = std::collections::HashMap::new();
        for w in plan {
            let entry = seen.entry(w.name.clone()).or_insert(0);
            *entry += 1;
            let n = *entry;
            out.push(GPUWorkerConfig {
                adapter_id: w.adapter_id,
                name: if n == 1 {
                    w.name.clone()
                } else {
                    format!("{}#{}", w.name, n)
                },
                backend: w.backend,
                is_discrete: w.is_discrete,
            });
        }
        out
    }

    /// Spawn a managed tokio process with concurrency semaphore gating and kill-on-drop lifecycle.
    pub async fn spawn_managed(
        mut cmd: tokio::process::Command,
        priority: SubprocessPriority,
    ) -> std::io::Result<ProcessGuard> {
        let permit = match priority {
            SubprocessPriority::InteractivePlayback | SubprocessPriority::InteractiveProbe => {
                playback_semaphore().acquire_owned().await.ok()
            }
            SubprocessPriority::BackgroundExtract | SubprocessPriority::BackgroundPreTranscode => {
                background_semaphore().acquire_owned().await.ok()
            }
        };

        let child = cmd.spawn()?;
        Ok(ProcessGuard::new(child, permit))
    }

    /// Run a managed process to completion with concurrency gating.
    pub async fn run_managed(
        mut cmd: tokio::process::Command,
        priority: SubprocessPriority,
    ) -> std::io::Result<std::process::Output> {
        let sem = match priority {
            SubprocessPriority::InteractivePlayback | SubprocessPriority::InteractiveProbe => {
                playback_semaphore()
            }
            SubprocessPriority::BackgroundExtract | SubprocessPriority::BackgroundPreTranscode => {
                background_semaphore()
            }
        };
        let _permit = sem.acquire_owned().await.ok();

        cmd.output().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::hls_service::HlsService;

    #[test]
    fn test_get_ffmpeg_video_args_amf_2160p_uses_hevc_and_hvc1_tag() {
        let worker = GPUWorkerConfig {
            adapter_id: 1,
            name: "AMD Radeon RX 560X".into(),
            backend: GpuBackend::Amf,
            is_discrete: true,
        };

        let args = worker.get_ffmpeg_video_args(true, Some(2160));
        assert!(args.contains(&"-c:v".to_string()));
        let cv_idx = args.iter().position(|a| a == "-c:v").unwrap();
        assert_eq!(args[cv_idx + 1], "hevc_amf");
        assert!(args.contains(&"-tag:v".to_string()));
        let tag_idx = args.iter().position(|a| a == "-tag:v").unwrap();
        assert_eq!(args[tag_idx + 1], "hvc1");
    }

    #[test]
    fn test_get_ffmpeg_video_args_amf_1080p_and_1440p_remain_h264() {
        let worker = GPUWorkerConfig {
            adapter_id: 1,
            name: "AMD Radeon RX 560X".into(),
            backend: GpuBackend::Amf,
            is_discrete: true,
        };

        for height in [1080, 1440, 720] {
            let args = worker.get_ffmpeg_video_args(true, Some(height));
            let cv_idx = args.iter().position(|a| a == "-c:v").unwrap();
            assert_eq!(args[cv_idx + 1], "h264_amf");
            assert!(!args.contains(&"-tag:v".to_string()));
        }
    }

    #[test]
    fn test_get_ffmpeg_video_args_cpu_2160p_uses_libx265() {
        let worker = GPUWorkerConfig {
            adapter_id: 0,
            name: "CPU fallback".into(),
            backend: GpuBackend::Cpu,
            is_discrete: false,
        };

        let args_4k = worker.get_ffmpeg_video_args(false, Some(2160));
        let cv_idx = args_4k.iter().position(|a| a == "-c:v").unwrap();
        assert_eq!(args_4k[cv_idx + 1], "libx265");
        assert!(args_4k.contains(&"-tag:v".to_string()));

        let args_1080 = worker.get_ffmpeg_video_args(false, Some(1080));
        let cv_1080 = args_1080.iter().position(|a| a == "-c:v").unwrap();
        assert_eq!(args_1080[cv_1080 + 1], "libx264");
        assert!(!args_1080.contains(&"-tag:v".to_string()));
    }

    #[test]
    fn test_hls_standard_qualities_2160p_declares_hvc1() {
        let q_2160 = HlsService::STANDARD_QUALITIES
            .iter()
            .find(|(label, _, _, _, _)| *label == "2160p")
            .expect("2160p tier must exist");
        assert!(
            q_2160.4.contains("hvc1"),
            "2160p must declare hvc1 codec: {}",
            q_2160.4
        );

        let q_1440 = HlsService::STANDARD_QUALITIES
            .iter()
            .find(|(label, _, _, _, _)| *label == "1440p")
            .expect("1440p tier must exist");
        assert!(
            q_1440.4.contains("avc1"),
            "1440p must declare avc1 codec: {}",
            q_1440.4
        );
    }

    #[test]
    fn test_select_amf_strategy_2160p_selects_single_worker() {
        let (_, count) = GpuService::select_amf_strategy(None, Some(2160));
        assert_eq!(
            count, 1,
            "4K 2160p must strictly use 1 worker to prevent dual-GPU bus contention"
        );
    }

    #[test]
    fn test_expand_workers_count_1_picks_discrete() {
        let workers = vec![
            GPUWorkerConfig {
                adapter_id: 1,
                name: "AMD Radeon RX 560X".into(),
                backend: GpuBackend::Amf,
                is_discrete: true,
            },
            GPUWorkerConfig {
                adapter_id: 0,
                name: "AMD Radeon Vega 8".into(),
                backend: GpuBackend::Amf,
                is_discrete: false,
            },
        ];

        let expanded = GpuService::expand_workers(&workers, 1);
        assert_eq!(expanded.len(), 1);
        assert!(expanded[0].is_discrete);
        assert_eq!(expanded[0].name, "AMD Radeon RX 560X");
    }

    #[tokio::test]
    async fn test_subprocess_priority_ordering() {
        assert!(
            SubprocessPriority::InteractivePlayback < SubprocessPriority::BackgroundPreTranscode
        );
        assert!(SubprocessPriority::InteractiveProbe < SubprocessPriority::BackgroundExtract);
    }

    #[tokio::test]
    async fn test_process_guard_lifecycle() {
        let mut cmd = tokio::process::Command::new("powershell");
        cmd.args(["-NoProfile", "-Command", "Start-Sleep -Milliseconds 50"]);
        let guard = GpuService::spawn_managed(cmd, SubprocessPriority::InteractiveProbe).await;
        if let Ok(mut g) = guard {
            assert!(g.pid.is_some());
            let status = g.wait().await;
            assert!(status.is_ok());
        }
    }
}
