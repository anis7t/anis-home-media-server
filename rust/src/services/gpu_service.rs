//! Hardware GPU detection, AMF hardware encoding validation, and multi-adapter worker management.
//!
//! Mirrors `app/services/gpu_service.py` to provide native dual-GPU (AMD Radeon RX 560X discrete `dx11:1`
//! and AMD Radeon Vega 8 integrated `dx11:0`) orchestration in Rust.

use crate::services::probe_service::ProbeStream;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use tracing::{debug, info};

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
    pub fn get_ffmpeg_video_args(&self, use_vpp_amf: bool, target_height: Option<u32>) -> Vec<String> {
        let height = target_height.unwrap_or(HLS_MAX_HEIGHT as u32);
        match self.backend {
            GpuBackend::Amf => {
                let vf = if use_vpp_amf {
                    format!("vpp_amf=h='min({},ih)':w=-2:format=nv12", height)
                } else {
                    "null".to_string()
                };
                let quality = std::env::var("MEDIA_SERVER_AMF_QUALITY")
                    .unwrap_or_else(|_| "speed".into());
                let qp_i = std::env::var("MEDIA_SERVER_AMF_QP_I")
                    .unwrap_or_else(|_| "22".into());
                let qp_p = std::env::var("MEDIA_SERVER_AMF_QP_P")
                    .unwrap_or_else(|_| "24".into());
                vec![
                    "-vf".into(),
                    vf,
                    "-c:v".into(),
                    "h264_amf".into(),
                    "-quality".into(),
                    quality,
                    "-rc".into(),
                    "cqp".into(),
                    "-qp_i".into(),
                    qp_i,
                    "-qp_p".into(),
                    qp_p,
                ]
            }
            GpuBackend::Vaapi => {
                let qp = std::env::var("MEDIA_SERVER_VAAPI_QP")
                    .unwrap_or_else(|_| "24".into());
                vec![
                    "-vf".into(),
                    format!("format=nv12,hwupload,scale_vaapi=w=-2:h={}", height),
                    "-c:v".into(),
                    "h264_vaapi".into(),
                    "-qp".into(),
                    qp,
                    "-pix_fmt".into(),
                    "nv12".into(),
                ]
            }
            GpuBackend::Cpu => {
                let preset = std::env::var("MEDIA_SERVER_TRANSCODE_PRESET")
                    .unwrap_or_else(|_| "superfast".into());
                let crf = std::env::var("MEDIA_SERVER_TRANSCODE_CRF")
                    .unwrap_or_else(|_| "23".into());
                vec![
                    "-vf".into(),
                    format!("scale=-2:'min(ih,{})',format=yuv420p", height),
                    "-c:v".into(),
                    "libx264".into(),
                    "-preset".into(),
                    preset,
                    "-crf".into(),
                    crf,
                    "-pix_fmt".into(),
                    "yuv420p".into(),
                ]
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
                debug!("Cannot spawn ffmpeg to probe D3D11 adapter {}: {}", adapter_idx, e);
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

        let count: usize = if needs_vpp || target_h >= 1440 {
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
}
