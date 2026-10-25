use media_server_api::scanner::models::*;
use media_server_api::scanner::TmdbClient;

#[test]
fn test_build_details_json_synthesis() {
    let details = TmdbMovieDetails {
        id: 27205,
        title: Some("Inception".to_string()),
        release_date: Some("2010-07-15".to_string()),
        overview: Some("Your mind is the scene of the crime.".to_string()),
        poster_path: Some("/poster.jpg".to_string()),
        backdrop_path: Some("/backdrop.jpg".to_string()),
        runtime: Some(148),
        genres: vec![TmdbGenre {
            id: 28,
            name: "Action".to_string(),
        }],
        vote_average: Some(8.4),
        tagline: Some("Your mind is the scene of the crime.".to_string()),
        imdb_id: Some("tt1375666".to_string()),
        production_companies: vec![TmdbProductionCompany {
            id: 923,
            name: "Legendary Pictures".to_string(),
        }],
        credits: Some(TmdbCredits {
            cast: vec![TmdbCastMember {
                name: Some("Leonardo DiCaprio".to_string()),
                character: Some("Cobb".to_string()),
                profile_path: Some("/leo.jpg".to_string()),
            }],
            crew: vec![
                TmdbCrewMember {
                    name: Some("Christopher Nolan".to_string()),
                    job: Some("Director".to_string()),
                    department: Some("Directing".to_string()),
                },
                TmdbCrewMember {
                    name: Some("Christopher Nolan".to_string()),
                    job: Some("Writer".to_string()),
                    department: Some("Writing".to_string()),
                },
            ],
        }),
        release_dates: Some(TmdbReleaseDatesResults {
            results: vec![TmdbCountryReleaseDates {
                iso_3166_1: Some("US".to_string()),
                release_dates: vec![TmdbCertificationEntry {
                    certification: Some("PG-13".to_string()),
                    release_date: Some("2010-07-16".to_string()),
                    release_type: Some(3),
                }],
            }],
        }),
        videos: Some(TmdbVideosResults {
            results: vec![TmdbVideoEntry {
                key: Some("YoHD9XEInc0".to_string()),
                site: Some("YouTube".to_string()),
                name: Some("Official Trailer".to_string()),
                video_type: Some("Trailer".to_string()),
            }],
        }),
    };

    let json_str = TmdbClient::build_details_json(&details);
    let parsed: serde_json::Value = serde_json::from_str(&json_str).expect("Valid JSON");

    assert_eq!(parsed["tagline"], "Your mind is the scene of the crime.");
    assert_eq!(parsed["imdb_id"], "tt1375666");
    assert_eq!(parsed["certification"], "PG-13");
    assert_eq!(parsed["trailer_key"], "YoHD9XEInc0");
    assert_eq!(parsed["cast"][0]["name"], "Leonardo DiCaprio");
    assert_eq!(parsed["cast"][0]["character"], "Cobb");
    assert_eq!(parsed["directors"][0], "Christopher Nolan");
    assert_eq!(parsed["writers"][0], "Christopher Nolan");
    assert_eq!(parsed["production"][0], "Legendary Pictures");
}

#[tokio::test]
async fn test_live_tmdb_search_if_token_configured() {
    dotenvy::dotenv().ok();
    let token = match std::env::var("TMDB_API_TOKEN") {
        Ok(t) if !t.trim().is_empty() => t.trim().trim_matches(|c| c == '"' || c == '\'').to_string(),
        _ => {
            println!("Skipping live TMDb test: TMDB_API_TOKEN not configured");
            return;
        }
    };

    let client = TmdbClient::new(token);
    let result = client.search_movie("Inception", Some(2010)).await;

    match result {
        Ok(Some(movie)) => {
            assert_eq!(movie.id, 27205);
            assert!(movie.title.unwrap_or_default().contains("Inception"));
        }
        Ok(None) => panic!("Expected Inception 2010 to be found on TMDb"),
        Err(e) => {
            // Network failure or sandboxed environment is non-fatal for unit testing
            eprintln!("Live TMDb request failed (network/connectivity): {}", e);
        }
    }
}
