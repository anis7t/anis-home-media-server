use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MovieSummaryItem {
    pub filename: String,
    pub title: String,
    pub year: Option<i32>,
    pub tmdb_id: Option<i64>,
    pub overview: Option<String>,
    pub poster_path: Option<String>,
    pub backdrop_path: Option<String>,
    pub runtime: Option<i32>,
    pub genres: Option<String>,
    pub vote_average: Option<f64>,
    pub rating: Option<f64>,
    pub release_date: Option<String>,
    pub updated_at: Option<String>,
    pub poster: Option<String>,
    pub position: f64,
    pub duration: f64,
    pub percent: f64,
    pub remaining_mins: Option<i32>,
    pub needs_transcode: bool,
    pub hls_cached: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MovieListResponse {
    pub movies: Vec<MovieSummaryItem>,
    pub watching: Vec<MovieSummaryItem>,
    pub total: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TechnicalSpecs {
    pub resolution: Option<String>,
    pub resolution_badge: Option<String>,
    pub video_codec: Option<String>,
    pub audio_codec: Option<String>,
    pub audio_channels: Option<String>,
    pub container: Option<String>,
    pub file_size: Option<String>,
    pub bitrate: Option<String>,
    pub subtitles: Vec<String>,
    pub aspect_ratio: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MovieDetailsResponse {
    pub movie: MovieSummaryItem,
    pub specs: TechnicalSpecs,
    pub extended: serde_json::Value,
}
