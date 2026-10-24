use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SubtitleTrack {
    pub id: String,
    pub name: String,
    pub src: String,
    pub lang: String,
    pub label: String,
    pub default: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubtitleListResponse {
    pub tracks: Vec<SubtitleTrack>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubtitleUploadResponse {
    pub success: bool,
    pub filename: String,
    pub language: String,
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmbeddedSubtitleStream {
    pub index: usize,
    pub codec_name: String,
    pub language: String,
    pub title: Option<String>,
}
