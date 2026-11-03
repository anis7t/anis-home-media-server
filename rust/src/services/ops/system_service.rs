use crate::models::system::{
    CpuInfo, DiskIoInfo, DriveInfo, GpuInfo, MemoryInfo, NetworkInfo, StorageInfo,
    SystemTelemetryResponse,
};
use std::collections::HashSet;
use std::path::Path;
use std::sync::{Arc, Mutex};
use sysinfo::{Disks, System};

fn is_best_mount_for_target(target: &Path, mount: &Path, disks: &Disks) -> bool {
    target.starts_with(mount)
        && !disks.iter().any(|candidate| {
            let candidate_mount = candidate.mount_point();
            candidate_mount != mount
                && candidate_mount.components().count() > mount.components().count()
                && target.starts_with(candidate_mount)
        })
}

#[derive(Clone)]
pub struct SystemService {
    sys: Arc<Mutex<System>>,
}

impl SystemService {
    pub fn new() -> Self {
        let mut sys = System::new_all();
        sys.refresh_all();
        Self {
            sys: Arc::new(Mutex::new(sys)),
        }
    }

    pub fn get_telemetry(&self) -> SystemTelemetryResponse {
        let mut sys = self.sys.lock().unwrap();
        sys.refresh_cpu_usage();
        sys.refresh_memory();

        let cpu_pct = sys.global_cpu_usage();
        let cpu_cores = sys.cpus().len();

        let total_mem = sys.total_memory();
        let used_mem = sys.used_memory();
        let free_mem = sys.available_memory();
        let mem_pct = if total_mem > 0 {
            (used_mem as f32 / total_mem as f32) * 100.0
        } else {
            0.0
        };

        let mem_used_str = format!("{:.1} GB", used_mem as f64 / (1024.0 * 1024.0 * 1024.0));
        let mem_total_str = format!("{:.1} GB", total_mem as f64 / (1024.0 * 1024.0 * 1024.0));

        // Disk & Storage
        let disks = Disks::new_with_refreshed_list();
        let mut drives_info = Vec::new();
        let mut pool_used: u64 = 0;
        let mut pool_total: u64 = 0;
        let mut pool_free: u64 = 0;
        let container_storage_paths: Vec<std::path::PathBuf> = if cfg!(windows) {
            Vec::new()
        } else {
            std::env::var("MEDIA_SERVER_STORAGE_PATHS")
                .unwrap_or_default()
                .split(',')
                .map(str::trim)
                .filter(|path| !path.is_empty())
                .map(std::path::PathBuf::from)
                .collect()
        };
        let mut counted_container_devices = HashSet::new();

        for disk in &disks {
            let mount = disk.mount_point().to_string_lossy().to_string();
            // Explicit whitelist: strictly include only Drive D: (media storage) and Drive E: (SSD runtime & cache).
            let is_windows_storage = cfg!(windows)
                && (mount.starts_with("D:") || mount.starts_with("E:"));
            let mount_path = disk.mount_point();
            let is_container_storage = !cfg!(windows)
                && container_storage_paths
                    .iter()
                    .any(|path| is_best_mount_for_target(path, mount_path, &disks));

            if is_windows_storage || is_container_storage {
                if is_container_storage {
                    let device = disk.name().to_string_lossy().to_string();
                    let device_key = if device.is_empty() {
                        mount.clone()
                    } else {
                        device
                    };
                    if !counted_container_devices.insert(device_key) {
                        continue;
                    }
                }

                let total = disk.total_space();
                let free = disk.available_space();
                let used = total.saturating_sub(free);
                let pct = if total > 0 {
                    (used as f32 / total as f32) * 100.0
                } else {
                    0.0
                };

                let (drive, label) = if cfg!(windows) {
                    let drive_letter = mount.chars().next().unwrap_or('?').to_string();
                    let label = if drive_letter == "E" {
                        "Fast SSD (Apps & Cache)".to_string()
                    } else {
                        "Mass Storage (Flicks)".to_string()
                    };
                    (format!("{}:", drive_letter), label)
                } else {
                    (mount.clone(), format!("Container Storage ({})", mount))
                };

                let u_str = format!("{:.1} GB", used as f64 / (1024.0 * 1024.0 * 1024.0));
                let f_str = format!("{:.1} GB", free as f64 / (1024.0 * 1024.0 * 1024.0));
                let t_str = format!("{:.1} GB", total as f64 / (1024.0 * 1024.0 * 1024.0));

                drives_info.push(DriveInfo {
                    drive,
                    label,
                    percent: (pct * 10.0).round() / 10.0,
                    used,
                    free,
                    total,
                    used_str: u_str,
                    free_str: f_str,
                    total_str: t_str,
                });

                pool_used += used;
                pool_total += total;
                pool_free += free;
            }
        }

        if pool_total == 0 && !drives_info.is_empty() {
            for d in &drives_info {
                pool_used += d.used;
                pool_total += d.total;
                pool_free += d.free;
            }
        }

        let pool_pct = if pool_total > 0 {
            (pool_used as f32 / pool_total as f32) * 100.0
        } else {
            0.0
        };

        let storage_used_str = format!("{:.1} GB", pool_used as f64 / (1024.0 * 1024.0 * 1024.0));
        let storage_free_str = format!("{:.1} GB", pool_free as f64 / (1024.0 * 1024.0 * 1024.0));
        let storage_total_str = format!("{:.1} GB", pool_total as f64 / (1024.0 * 1024.0 * 1024.0));

        let drives_sub = drives_info
            .iter()
            .map(|d| format!("{} {} free", d.drive, d.free_str))
            .collect::<Vec<_>>()
            .join(" · ");

        SystemTelemetryResponse {
            cpu: CpuInfo {
                percent: (cpu_pct * 10.0).round() / 10.0,
                cores: cpu_cores,
                label: "Core Compute".to_string(),
                display: format!("{:.1}% · {} Cores", cpu_pct, cpu_cores),
                sub: format!("{} active CPU threads", cpu_cores),
            },
            gpu: GpuInfo {
                available: false,
                percent: 0,
                vram_used: None,
                vram_total: None,
                card: "d3d11".to_string(),
                label: "Graphics Engine".to_string(),
                display: "Standby · RX 560X & Vega 8".to_string(),
            },
            memory: MemoryInfo {
                percent: (mem_pct * 10.0).round() / 10.0,
                used: used_mem,
                total: total_mem,
                free: free_mem,
                label: "Memory Bank".to_string(),
                display: format!("{:.1}% · {} / {}", mem_pct, mem_used_str, mem_total_str),
                sub: format!("{} used of {}", mem_used_str, mem_total_str),
            },
            disk_io: DiskIoInfo {
                read_rate: 0.0,
                write_rate: 0.0,
                read_str: "0.0 KB/s".to_string(),
                write_str: "0.0 KB/s".to_string(),
                label: "I/O Velocity".to_string(),
                display: "▼ 0.0 KB/s R · ▲ 0.0 KB/s W".to_string(),
                sub: "Read: 0.0 KB/s · Write: 0.0 KB/s".to_string(),
            },
            storage: StorageInfo {
                percent: (pool_pct * 10.0).round() / 10.0,
                used: pool_used,
                free: pool_free,
                total: pool_total,
                used_str: storage_used_str.clone(),
                free_str: storage_free_str.clone(),
                total_str: storage_total_str.clone(),
                label: "Storage Pool".to_string(),
                display: format!(
                    "{:.1}% · {} / {}",
                    pool_pct, storage_used_str, storage_total_str
                ),
                sub: if drives_sub.is_empty() {
                    format!("{} remaining free", storage_free_str)
                } else {
                    drives_sub
                },
                drives: drives_info,
            },
            network: NetworkInfo {
                rx_rate: 0.0,
                tx_rate: 0.0,
                rx_str: "0.0 KB/s".to_string(),
                tx_str: "0.0 KB/s".to_string(),
                label: "Network Stream".to_string(),
                display: "▼ 0.0 KB/s In · ▲ 0.0 KB/s Out".to_string(),
                sub: "In: 0.0 KB/s · Out: 0.0 KB/s".to_string(),
            },
        }
    }
}

impl Default for SystemService {
    fn default() -> Self {
        Self::new()
    }
}
