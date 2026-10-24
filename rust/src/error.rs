use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;

#[derive(Debug)]
#[allow(dead_code)]
pub enum AppError {
    NotFound(String),
    BadRequest(String),
    Forbidden(String),
    Unauthorized(String),
    UnsupportedMediaType(String),
    PayloadTooLarge(String),
    /// Rate limited. Carries the number of seconds the caller must wait, which
    /// becomes the `Retry-After` response header.
    TooManyRequests(u64),
    BadGateway(String),
    ServiceUnavailable(String),
    Internal(String),
    Database(sqlx::Error),
}

impl std::fmt::Display for AppError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AppError::NotFound(msg) => write!(f, "Not Found: {}", msg),
            AppError::BadRequest(msg) => write!(f, "Bad Request: {}", msg),
            AppError::Forbidden(msg) => write!(f, "Forbidden: {}", msg),
            AppError::Unauthorized(msg) => write!(f, "Unauthorized: {}", msg),
            AppError::UnsupportedMediaType(msg) => write!(f, "Unsupported Media Type: {}", msg),
            AppError::PayloadTooLarge(msg) => write!(f, "Payload Too Large: {}", msg),
            AppError::TooManyRequests(secs) => {
                write!(f, "Too Many Requests: retry after {}s", secs)
            }
            AppError::BadGateway(msg) => write!(f, "Bad Gateway: {}", msg),
            AppError::ServiceUnavailable(msg) => write!(f, "Service Unavailable: {}", msg),
            AppError::Internal(msg) => write!(f, "Internal Error: {}", msg),
            AppError::Database(err) => write!(f, "Database Error: {}", err),
        }
    }
}

impl std::error::Error for AppError {}

impl From<sqlx::Error> for AppError {
    fn from(err: sqlx::Error) -> Self {
        match err {
            sqlx::Error::RowNotFound => AppError::NotFound("Record not found".to_string()),
            _ => AppError::Database(err),
        }
    }
}

impl From<serde_json::Error> for AppError {
    fn from(err: serde_json::Error) -> Self {
        AppError::Internal(format!("Serialization error: {}", err))
    }
}

impl From<std::io::Error> for AppError {
    fn from(err: std::io::Error) -> Self {
        AppError::Internal(format!("I/O error: {}", err))
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        // A refusal must tell the caller when to come back: an SSE client that
        // retries with no delay turns a rate limit into a busy loop.
        let retry_after_secs = match &self {
            AppError::TooManyRequests(secs) => Some(*secs),
            _ => None,
        };

        let (status, error_message) = match self {
            AppError::NotFound(msg) => (StatusCode::NOT_FOUND, msg),
            AppError::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg),
            AppError::Forbidden(msg) => (StatusCode::FORBIDDEN, msg),
            AppError::Unauthorized(msg) => (StatusCode::UNAUTHORIZED, msg),
            AppError::UnsupportedMediaType(msg) => (StatusCode::UNSUPPORTED_MEDIA_TYPE, msg),
            AppError::PayloadTooLarge(msg) => (StatusCode::PAYLOAD_TOO_LARGE, msg),
            AppError::TooManyRequests(secs) => (
                StatusCode::TOO_MANY_REQUESTS,
                format!(
                    "Too many requests. Please wait {} second(s) and try again.",
                    secs
                ),
            ),
            AppError::BadGateway(msg) => (StatusCode::BAD_GATEWAY, msg),
            AppError::ServiceUnavailable(msg) => (StatusCode::SERVICE_UNAVAILABLE, msg),
            AppError::Internal(msg) => (StatusCode::INTERNAL_SERVER_ERROR, msg),
            AppError::Database(err) => {
                tracing::error!("Database query failed: {:?}", err);
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Internal database error".to_string(),
                )
            }
        };

        let body = Json(json!({
            "error": error_message,
            "status": status.as_u16(),
        }));

        let mut response = (status, body).into_response();
        if let Some(secs) = retry_after_secs {
            if let Ok(value) = axum::http::HeaderValue::from_str(&secs.to_string()) {
                response
                    .headers_mut()
                    .insert(axum::http::header::RETRY_AFTER, value);
            }
        }
        response
    }
}
