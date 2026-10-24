use serde::{Deserialize, Serialize};

/// Response returned by the single-file upload route and by the chunked
/// upload's `complete` route. Mirrors the Flask-era
/// `UploadSuccessResponse` schema.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UploadSuccessResponse {
    pub success: bool,
    pub filename: String,
    pub title: String,
    pub year: Option<i32>,
    pub needs_transcode: bool,
    pub details_url: String,
}

/// Body of `POST /api/upload/chunk/init`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChunkInitRequest {
    pub filename: String,
    pub size: u64,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub overwrite: Option<bool>,
}

/// Response of `POST /api/upload/chunk/init` and `GET /api/upload/chunk/{id}`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChunkStatusResponse {
    pub success: bool,
    pub upload_id: String,
    pub filename: String,
    pub size: u64,
    pub offset: u64,
    pub chunk_size: u64,
}

/// Response of `POST /api/upload/chunk/{id}`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChunkAppendResponse {
    pub success: bool,
    pub upload_id: String,
    pub offset: u64,
    pub size: u64,
    pub complete: bool,
}

/// Persisted per-upload manifest. The ID is the file stem; the manifest name
/// is `<id>.json` and the data file is `<id>.part`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UploadManifest {
    /// Sanitized original filename, without a title override.
    pub filename: String,
    pub size: u64,
    pub created_at: i64,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub overwrite: bool,
}
