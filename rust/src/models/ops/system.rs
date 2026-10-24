use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CpuInfo {
    pub percent: f32,
    pub cores: usize,
    pub label: String,
    pub display: String,
    pub sub: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryInfo {
    pub percent: f32,
    pub used: u64,
    pub total: u64,
    pub free: u64,
    pub label: String,
    pub display: String,
    pub sub: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DriveInfo {
    pub drive: String,
    pub label: String,
    pub percent: f32,
    pub used: u64,
    pub free: u64,
    pub total: u64,
    pub used_str: String,
    pub free_str: String,
    pub total_str: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StorageInfo {
    pub percent: f32,
    pub used: u64,
    pub free: u64,
    pub total: u64,
    pub used_str: String,
    pub free_str: String,
    pub total_str: String,
    pub label: String,
    pub display: String,
    pub sub: String,
    pub drives: Vec<DriveInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GpuInfo {
    pub available: bool,
    pub percent: u32,
    pub vram_used: Option<u64>,
    pub vram_total: Option<u64>,
    pub card: String,
    pub label: String,
    pub display: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiskIoInfo {
    pub read_rate: f64,
    pub write_rate: f64,
    pub read_str: String,
    pub write_str: String,
    pub label: String,
    pub display: String,
    pub sub: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkInfo {
    pub rx_rate: f64,
    pub tx_rate: f64,
    pub rx_str: String,
    pub tx_str: String,
    pub label: String,
    pub display: String,
    pub sub: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SystemTelemetryResponse {
    pub cpu: CpuInfo,
    pub gpu: GpuInfo,
    pub memory: MemoryInfo,
    pub disk_io: DiskIoInfo,
    pub storage: StorageInfo,
    pub network: NetworkInfo,
}
