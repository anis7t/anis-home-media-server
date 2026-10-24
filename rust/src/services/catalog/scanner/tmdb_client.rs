use super::models::{
    TmdbFindResponse, TmdbMovieDetails, TmdbMovieResult, TmdbSearchResponse,
};
use crate::error::AppError;
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, USER_AGENT};
use serde_json::json;
use std::time::Duration;
use tracing::{debug, warn};

const TMDB_API_BASE: &str = "https://api.themoviedb.org/3";
const MAX_RETRIES: u32 = 4;
const RETRY_BASE_DELAY_SECS: u64 = 3;

#[derive(Clone)]
pub struct TmdbClient {
    client: reqwest::Client,
    base_url: String,
}

impl TmdbClient {
    /// Create a new TMDb client with bearer token authentication.
    pub fn new(token: String) -> Self {
        let mut default_headers = HeaderMap::new();
        let mut auth_val = HeaderValue::from_str(&format!("Bearer {}", token.trim()))
            .unwrap_or_else(|_| HeaderValue::from_static(""));
        auth_val.set_sensitive(true);
        default_headers.insert(AUTHORIZATION, auth_val);
        default_headers.insert(
            USER_AGENT,
            HeaderValue::from_static("Mozilla/5.0 (Windows NT 10.0; Win64; x64) LocalMediaServer/1.0"),
        );

        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(20))
            .default_headers(default_headers)
            .build()
            .unwrap_or_default();

        let base_url = std::env::var("TMDB_API_BASE_URL")
            .unwrap_or_else(|_| TMDB_API_BASE.to_string());

        Self {
            client,
            base_url,
        }
    }

    /// Execute a GET request against TMDb with rate-limit backoff and automatic retry.
    async fn get_with_retry<T: serde::de::DeserializeOwned>(
        &self,
        endpoint: &str,
        params: &[(&str, &str)],
    ) -> Result<T, AppError> {
        let url = format!("{}{}", self.base_url, endpoint);

        for attempt in 1..=MAX_RETRIES {
            let res = self.client.get(&url).query(params).send().await;

            match res {
                Ok(response) => {
                    let status = response.status();

                    // Handle rate limiting (HTTP 429)
                    if status.as_u16() == 429 {
                        let retry_after_secs = response
                            .headers()
                            .get("Retry-After")
                            .and_then(|h| h.to_str().ok())
                            .and_then(|v| v.parse::<u64>().ok())
                            .unwrap_or(5);

                        warn!(
                            "TMDb rate limit encountered (429). Backing off for {}s (attempt {}/{})",
                            retry_after_secs, attempt, MAX_RETRIES
                        );
                        tokio::time::sleep(Duration::from_secs(retry_after_secs)).await;
                        continue;
                    }

                    if status.is_success() {
                        let parsed = response.json::<T>().await.map_err(|e| {
                            AppError::Internal(format!("Failed to parse TMDb JSON response: {}", e))
                        })?;
                        return Ok(parsed);
                    }

                    if status.as_u16() == 404 {
                        return Err(AppError::NotFound(format!("TMDb resource not found: {}", url)));
                    }

                    warn!(
                        "TMDb request failed with status {} on attempt {}/{}",
                        status, attempt, MAX_RETRIES
                    );
                }
                Err(err) => {
                    warn!(
                        "TMDb request error (attempt {}/{}): {}",
                        attempt, MAX_RETRIES, err
                    );
                }
            }

            if attempt < MAX_RETRIES {
                let delay = Duration::from_secs(RETRY_BASE_DELAY_SECS * attempt as u64);
                debug!("Retrying TMDb request in {:?}...", delay);
                tokio::time::sleep(delay).await;
            }
        }

        Err(AppError::Internal(format!(
            "TMDb request to {} failed after {} retries",
            endpoint, MAX_RETRIES
        )))
    }

    /// Search TMDb for a movie by title and optional release year.
    pub async fn search_movie(
        &self,
        title: &str,
        year: Option<i32>,
    ) -> Result<Option<TmdbMovieResult>, AppError> {
        let year_str = year.map(|y| y.to_string());
        let mut params = vec![
            ("query", title),
            ("language", "en-US"),
            ("include_adult", "false"),
        ];
        if let Some(ref y) = year_str {
            params.push(("year", y));
        }

        let resp: TmdbSearchResponse = self.get_with_retry("/search/movie", &params).await?;

        if resp.results.is_empty() {
            return Ok(None);
        }

        // If year is specified, prefer an exact release_date year prefix match
        if let Some(y) = year {
            let y_prefix = y.to_string();
            for movie in &resp.results {
                if movie
                    .release_date
                    .as_deref()
                    .unwrap_or("")
                    .starts_with(&y_prefix)
                {
                    return Ok(Some(movie.clone()));
                }
            }
        }

        // Otherwise return the first result
        Ok(resp.results.into_iter().next())
    }

    /// Find movie by external IMDb ID (e.g. "tt0133093").
    pub async fn find_by_imdb_id(
        &self,
        imdb_id: &str,
    ) -> Result<Option<TmdbMovieResult>, AppError> {
        let clean_id = format!("tt{}", imdb_id.trim().trim_start_matches(|c| c == 't' || c == 'T'));
        let endpoint = format!("/find/{}", clean_id);
        let params = [("external_source", "imdb_id")];

        let resp: TmdbFindResponse = self.get_with_retry(&endpoint, &params).await?;
        Ok(resp.movie_results.into_iter().next())
    }

    /// Fetch full movie details with credits, release dates, and videos appended.
    pub async fn get_movie_details(&self, tmdb_id: i64) -> Result<TmdbMovieDetails, AppError> {
        let endpoint = format!("/movie/{}", tmdb_id);
        let params = [
            ("language", "en-US"),
            ("append_to_response", "credits,release_dates,videos"),
        ];

        self.get_with_retry(&endpoint, &params).await
    }

    /// Synthesize canonical JSON string matching PostgreSQL `movies.details_json`.
    pub fn build_details_json(details: &TmdbMovieDetails) -> String {
        // 1. Certification from US or IN release dates
        let mut cert = String::new();
        if let Some(ref rd_results) = details.release_dates {
            for country in &rd_results.results {
                if let Some(ref iso) = country.iso_3166_1 {
                    if iso == "US" || iso == "IN" {
                        for rel in &country.release_dates {
                            if let Some(ref c) = rel.certification {
                                if !c.trim().is_empty() {
                                    cert = c.clone();
                                    break;
                                }
                            }
                        }
                        if !cert.is_empty() {
                            break;
                        }
                    }
                }
            }
        }

        // 2. Cast list (top 20)
        let cast: Vec<serde_json::Value> = details
            .credits
            .as_ref()
            .map(|c| {
                c.cast
                    .iter()
                    .take(20)
                    .map(|member| {
                        json!({
                            "name": member.name,
                            "character": member.character,
                            "profile_path": member.profile_path
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();

        // 3. Directors & Writers from crew
        let mut directors = Vec::new();
        let mut writers = Vec::new();
        if let Some(ref cred) = details.credits {
            for crew_member in &cred.crew {
                if let (Some(ref name), Some(ref job)) = (&crew_member.name, &crew_member.job) {
                    if job == "Director" {
                        directors.push(name.clone());
                    } else if job == "Writer" || job == "Screenplay" {
                        writers.push(name.clone());
                    }
                }
            }
        }

        // 4. Production companies
        let production: Vec<String> = details
            .production_companies
            .iter()
            .map(|p| p.name.clone())
            .collect();

        // 5. YouTube trailer key
        let mut trailer_key = String::new();
        if let Some(ref vids) = details.videos {
            for v in &vids.results {
                if v.site.as_deref() == Some("YouTube")
                    && matches!(v.video_type.as_deref(), Some("Trailer") | Some("Teaser"))
                {
                    if let Some(ref key) = v.key {
                        trailer_key = key.clone();
                        break;
                    }
                }
            }
        }

        json!({
            "tagline": details.tagline.as_deref().unwrap_or(""),
            "imdb_id": details.imdb_id.as_deref().unwrap_or(""),
            "certification": cert,
            "cast": cast,
            "directors": directors,
            "writers": writers,
            "production": production,
            "trailer_key": trailer_key,
        })
        .to_string()
    }
}
