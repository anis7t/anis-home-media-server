//! `/api/cast/*` - Phase C4a, DLNA native.
//!
//! The browser and the phone app are thin clients here: they list devices, ask
//! for a filename to be cast, then poll status. Nothing that reaches a TV comes
//! from the client except a device id (resolved against the discovery cache), a
//! filename (validated by `PathResolver`) and numeric values.

use crate::error::AppError;
use crate::services::cast_registry::CastRegistry;
use axum::{
    body::Body,
    extract::{Query, State},
    http::{header, HeaderValue, Response, StatusCode},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;

#[derive(Clone)]
pub struct CastState {
    pub registry: Arc<CastRegistry>,
}

/// Actions the control endpoint accepts.
const ACTIONS: [&str; 8] = [
    "play",
    "pause",
    "stop",
    "seek",
    "volume",
    "mute",
    "subtitle",
    "subtitle_offset",
];

#[derive(Debug, Default, Deserialize)]
pub struct PlayBody {
    pub device_id: Option<String>,
    pub filename: Option<String>,
    pub position: Option<f64>,
    pub origin: Option<String>,
    pub subtitle_offset: Option<f64>,
}

#[derive(Debug, Default, Deserialize)]
pub struct ControlBody {
    pub device_id: Option<String>,
    pub action: Option<String>,
    pub value: Option<Value>,
}

#[derive(Debug, Default, Deserialize)]
pub struct DeviceQuery {
    pub refresh: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
pub struct StatusQuery {
    pub device_id: Option<String>,
}

/// `GET /api/cast/devices`
pub async fn devices(
    State(state): State<CastState>,
    Query(q): Query<DeviceQuery>,
) -> Result<Response<Body>, AppError> {
    let force = q
        .refresh
        .as_deref()
        .map(|v| matches!(v.to_lowercase().as_str(), "1" | "true" | "yes"))
        .unwrap_or(false);
    let payload = state.registry.devices(force).await;
    Ok(json_response(payload, StatusCode::OK))
}

/// `POST /api/cast/play`
pub async fn play(
    State(state): State<CastState>,
    body: Option<Json<PlayBody>>,
) -> Result<Response<Body>, AppError> {
    let payload = body.map(|Json(b)| b).unwrap_or_default();
    let device_id = payload.device_id.unwrap_or_default().trim().to_string();
    let filename = payload.filename.unwrap_or_default().trim().to_string();
    if device_id.is_empty() || filename.is_empty() {
        return Ok(json_response(
            json!({ "ok": false, "error": "device_id and filename are required" }),
            StatusCode::BAD_REQUEST,
        ));
    }

    let result = state
        .registry
        .play(
            &device_id,
            &filename,
            payload.position,
            payload.origin.as_deref(),
            payload.subtitle_offset,
            None,
        )
        .await;
    Ok(json_response(result.clone(), status_for(&result)))
}

/// `POST /api/cast/control`
pub async fn control(
    State(state): State<CastState>,
    body: Option<Json<ControlBody>>,
) -> Result<Response<Body>, AppError> {
    let payload = body.map(|Json(b)| b).unwrap_or_default();
    let device_id = payload.device_id.unwrap_or_default().trim().to_string();
    let action = payload.action.unwrap_or_default().trim().to_lowercase();
    if device_id.is_empty() {
        return Ok(json_response(
            json!({ "ok": false, "error": "device_id is required" }),
            StatusCode::BAD_REQUEST,
        ));
    }
    if !ACTIONS.contains(&action.as_str()) {
        let mut sorted: Vec<&str> = ACTIONS.to_vec();
        sorted.sort_unstable();
        return Ok(json_response(
            json!({
                "ok": false,
                "error": format!("action must be one of {:?}", sorted)
            }),
            StatusCode::BAD_REQUEST,
        ));
    }

    // Numeric coercion mirrors the Python: `subtitle_offset` defaults to 0,
    // every other numeric action demands a number, and volume is bounded.
    let raw = payload.value.unwrap_or(Value::Null);
    let value = match action.as_str() {
        // Every arm yields Option<f64>; mute's truthiness is carried as 0.0/1.0.
        "mute" => Some(if raw.is_null() { 1.0 } else if truthy(&raw) { 1.0 } else { 0.0 }),
        "subtitle" => Some(raw.as_i64().unwrap_or_else(|| {
            raw.as_str()
                .and_then(|s| s.parse::<i64>().ok())
                .unwrap_or(0)
        }) as f64),
        other => {
            let parsed = number(&raw);
            if parsed.is_none() && other != "subtitle_offset" {
                return Ok(json_response(
                    json!({ "ok": false, "error": format!("{} needs a numeric value", other) }),
                    StatusCode::BAD_REQUEST,
                ));
            }
            parsed.or(Some(0.0))
        }
    };
    if action == "volume" && value.map(|v| !(0.0..=100.0).contains(&v)).unwrap_or(true) {
        return Ok(json_response(
            json!({ "ok": false, "error": "volume must be between 0 and 100" }),
            StatusCode::BAD_REQUEST,
        ));
    }

    let result = state.registry.control(&device_id, &action, value).await;
    Ok(json_response(result.clone(), status_for(&result)))
}

/// `GET /api/cast/status`
pub async fn status(
    State(state): State<CastState>,
    Query(q): Query<StatusQuery>,
) -> Result<Response<Body>, AppError> {
    let device_id = q.device_id.unwrap_or_default().trim().to_string();
    if device_id.is_empty() {
        return Ok(json_response(
            json!({ "ok": false, "error": "device_id is required" }),
            StatusCode::BAD_REQUEST,
        ));
    }
    let result = state.registry.status(&device_id).await;
    Ok(json_response(result.clone(), status_for(&result)))
}

fn number(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.parse::<f64>().ok(),
        _ => None,
    }
}

/// Python truthiness for the values a JSON body can carry.
fn truthy(v: &Value) -> bool {
    match v {
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().map(|f| f != 0.0).unwrap_or(false),
        Value::String(s) => !s.is_empty(),
        Value::Null => false,
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    }
}

fn status_for(result: &Value) -> StatusCode {
    if result.get("ok").and_then(|v| v.as_bool()).unwrap_or(false) {
        StatusCode::OK
    } else {
        StatusCode::BAD_REQUEST
    }
}

fn json_response(value: Value, status: StatusCode) -> Response<Body> {
    let body = serde_json::to_string(&value).unwrap_or_else(|_| "{}".into());
    let mut res = Response::new(Body::from(body));
    *res.status_mut() = status;
    res.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    res
}

/// Kept for symmetry with the Python route module's surface.
#[allow(dead_code)]
type Payload = HashMap<String, Value>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_documented_action_is_accepted() {
        for a in ["play", "pause", "stop", "seek", "volume", "mute", "subtitle", "subtitle_offset"] {
            assert!(ACTIONS.contains(&a), "{}", a);
        }
        assert_eq!(ACTIONS.len(), 8);
    }

    #[test]
    fn numeric_actions_reject_a_non_number_but_subtitle_offset_defaults() {
        assert_eq!(number(&json!("abc")), None);
        assert_eq!(number(&json!("12.5")), Some(12.5));
        assert_eq!(number(&json!(12)), Some(12.0));
        assert_eq!(number(&json!(null)), None);
    }

    #[test]
    fn mute_truthiness_matches_python() {
        assert!(truthy(&json!(true)));
        assert!(truthy(&json!(1)));
        assert!(truthy(&json!("yes")));
        assert!(!truthy(&json!(false)));
        assert!(!truthy(&json!(0)));
        assert!(!truthy(&json!(null)));
    }

    #[test]
    fn status_follows_the_ok_flag() {
        assert_eq!(status_for(&json!({ "ok": true })), StatusCode::OK);
        assert_eq!(status_for(&json!({ "ok": false })), StatusCode::BAD_REQUEST);
        assert_eq!(
            status_for(&json!({})),
            StatusCode::BAD_REQUEST,
            "a response with no ok flag is not a success"
        );
    }
}