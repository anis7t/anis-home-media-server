use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SeekPreviewMetaResponse {
    pub duration: f64,
    pub interval: f64,
    pub count: u64,
    pub base_url: String,
}
