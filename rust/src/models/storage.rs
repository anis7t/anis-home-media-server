use crate::models::system::StorageInfo;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CacheAuditItem {
    pub name: String,
    pub path: String,
    pub size_bytes: u64,
    pub file_count: usize,
    pub mtime: f64,
    pub source_file: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CacheAuditData {
    pub orphaned_hls: Vec<CacheAuditItem>,
    pub orphaned_previews: Vec<CacheAuditItem>,
    pub active_hls: Vec<CacheAuditItem>,
    pub active_previews: Vec<CacheAuditItem>,
    pub total_orphaned_bytes: u64,
    pub total_orphaned_dirs: usize,
    pub total_active_bytes: u64,
    pub total_active_dirs: usize,
    pub degraded: bool,
    pub degraded_reasons: Vec<String>,
    pub media_roots_missing: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StorageAuditResponse {
    pub storage: StorageInfo,
    pub audit: CacheAuditData,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PurgeResult {
    pub freed_bytes: u64,
    pub purged_count: usize,
    pub purged_dirs: Vec<String>,
    pub failed_count: usize,
    pub failed_dirs: Vec<serde_json::Value>,
    pub skipped_live_count: usize,
    pub skipped_live: Vec<String>,
    pub dry_run: bool,
    pub refused: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PurgeOrphansResponse {
    pub success: bool,
    pub result: PurgeResult,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StorageSettingsResponse {
    pub retention_policy: String,
    pub allowed_policies: Vec<String>,
    pub archive_dir: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct StorageSettingsUpdateRequest {
    pub retention_policy: Option<String>,
    pub admin_pin: Option<String>,
    pub pin: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PurgeOrphansRequest {
    pub dry_run: Option<bool>,
    pub admin_pin: Option<String>,
    pub pin: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArchiveResult {
    pub status: String,
    pub policy: String,
    pub source: String,
    pub archived_to: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArchiveMediaResponse {
    pub success: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<ArchiveResult>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}
