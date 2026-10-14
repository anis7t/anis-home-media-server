use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct ProgressResponse {
    pub position: f64,
    pub duration: f64,
}

#[derive(Debug, Deserialize)]
pub struct UpdateProgressRequest {
    pub filename: String,
    pub position: f64,
    pub duration: f64,
    pub device_id: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SuccessResponse {
    pub success: bool,
}
