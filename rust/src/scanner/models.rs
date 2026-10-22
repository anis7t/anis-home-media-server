use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct TmdbMovieResult {
    pub id: i64,
    pub title: Option<String>,
    pub release_date: Option<String>,
    pub overview: Option<String>,
    pub poster_path: Option<String>,
    pub backdrop_path: Option<String>,
    pub vote_average: Option<f64>,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct TmdbSearchResponse {
    #[serde(default)]
    pub page: i64,
    #[serde(default)]
    pub results: Vec<TmdbMovieResult>,
    #[serde(default)]
    pub total_results: i64,
    #[serde(default)]
    pub total_pages: i64,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct TmdbFindResponse {
    #[serde(default)]
    pub movie_results: Vec<TmdbMovieResult>,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct TmdbGenre {
    #[serde(default)]
    pub id: i64,
    #[serde(default)]
    pub name: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct TmdbProductionCompany {
    #[serde(default)]
    pub id: i64,
    #[serde(default)]
    pub name: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct TmdbCastMember {
    pub name: Option<String>,
    pub character: Option<String>,
    pub profile_path: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct TmdbCrewMember {
    pub name: Option<String>,
    pub job: Option<String>,
    pub department: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct TmdbCredits {
    #[serde(default)]
    pub cast: Vec<TmdbCastMember>,
    #[serde(default)]
    pub crew: Vec<TmdbCrewMember>,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct TmdbCertificationEntry {
    pub certification: Option<String>,
    pub release_date: Option<String>,
    #[serde(rename = "type")]
    pub release_type: Option<i64>,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct TmdbCountryReleaseDates {
    pub iso_3166_1: Option<String>,
    #[serde(default)]
    pub release_dates: Vec<TmdbCertificationEntry>,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct TmdbReleaseDatesResults {
    #[serde(default)]
    pub results: Vec<TmdbCountryReleaseDates>,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct TmdbVideoEntry {
    pub key: Option<String>,
    pub site: Option<String>,
    pub name: Option<String>,
    #[serde(rename = "type")]
    pub video_type: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct TmdbVideosResults {
    #[serde(default)]
    pub results: Vec<TmdbVideoEntry>,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct TmdbMovieDetails {
    pub id: i64,
    pub title: Option<String>,
    pub release_date: Option<String>,
    pub overview: Option<String>,
    pub poster_path: Option<String>,
    pub backdrop_path: Option<String>,
    pub runtime: Option<i64>,
    #[serde(default)]
    pub genres: Vec<TmdbGenre>,
    pub vote_average: Option<f64>,
    pub tagline: Option<String>,
    pub imdb_id: Option<String>,
    #[serde(default)]
    pub production_companies: Vec<TmdbProductionCompany>,
    pub credits: Option<TmdbCredits>,
    pub release_dates: Option<TmdbReleaseDatesResults>,
    pub videos: Option<TmdbVideosResults>,
}
