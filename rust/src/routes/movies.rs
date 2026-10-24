use crate::error::AppError;
use crate::services::movie_service::MovieService;
use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use sqlx::PgPool;

use crate::services::auth_service::AuthService;

#[derive(Debug, Deserialize)]
pub struct MovieListQuery {
    pub q: Option<String>,
    pub sort: Option<String>,
}

pub async fn list_movies_handler(
    State(pool): State<PgPool>,
    headers: HeaderMap,
    Query(query): Query<MovieListQuery>,
) -> Result<impl IntoResponse, AppError> {
    let device_id = headers
        .get("x-device-id")
        .and_then(|v| v.to_str().ok());

    let user_id = AuthService::resolve_effective_user_id(&pool, &headers, device_id).await;

    let res = MovieService::list_movies(
        &pool,
        device_id,
        user_id,
        query.q.as_deref(),
        query.sort.as_deref(),
    )
    .await?;

    Ok(Json(res))
}

pub async fn get_movie_details_handler(
    State(pool): State<PgPool>,
    headers: HeaderMap,
    Path(filename): Path<String>,
) -> Result<impl IntoResponse, AppError> {
    let device_id = headers
        .get("x-device-id")
        .and_then(|v| v.to_str().ok());

    let user_id = AuthService::resolve_effective_user_id(&pool, &headers, device_id).await;

    let res = MovieService::get_movie_details(&pool, &filename, device_id, user_id).await?;

    Ok(Json(res))
}
