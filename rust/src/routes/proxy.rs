use axum::{
    body::Body,
    extract::{Request, State},
    http::{HeaderName, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use reqwest::Client;
use serde_json::json;
use std::sync::Arc;

#[derive(Clone, Debug)]
pub struct ProxyState {
    pub client: Client,
    pub flask_origin: String,
}

impl ProxyState {
    pub fn new(flask_origin: impl Into<String>) -> Self {
        let client = Client::builder()
            .redirect(reqwest::redirect::Policy::none()) // Preserve 302 redirects for OAuth & browser navigation
            .build()
            .unwrap_or_else(|_| Client::new());
        Self {
            client,
            flask_origin: flask_origin.into(),
        }
    }
}

fn is_hop_by_hop(name: &HeaderName) -> bool {
    let s = name.as_str();
    s.eq_ignore_ascii_case("connection")
        || s.eq_ignore_ascii_case("keep-alive")
        || s.eq_ignore_ascii_case("proxy-authenticate")
        || s.eq_ignore_ascii_case("proxy-authorization")
        || s.eq_ignore_ascii_case("te")
        || s.eq_ignore_ascii_case("trailers")
        || s.eq_ignore_ascii_case("transfer-encoding")
        || s.eq_ignore_ascii_case("upgrade")
        || s.eq_ignore_ascii_case("host")
}

pub async fn proxy_handler(State(state): State<Arc<ProxyState>>, req: Request) -> Response {
    let (parts, body) = req.into_parts();
    let path_and_query = parts
        .uri
        .path_and_query()
        .map(|pq| pq.as_str())
        .unwrap_or(parts.uri.path());
    let target_url = format!(
        "{}{}",
        state.flask_origin.trim_end_matches('/'),
        path_and_query
    );

    let mut upstream_req = state.client.request(parts.method, &target_url);

    for (name, val) in &parts.headers {
        if !is_hop_by_hop(name) {
            upstream_req = upstream_req.header(name, val);
        }
    }

    // Wrap Axum incoming body stream into Reqwest body
    let body_stream = body.into_data_stream();
    upstream_req = upstream_req.body(reqwest::Body::wrap_stream(body_stream));

    match upstream_req.send().await {
        Ok(upstream_res) => {
            let status = StatusCode::from_u16(upstream_res.status().as_u16())
                .unwrap_or(StatusCode::BAD_GATEWAY);
            let mut response_builder = Response::builder().status(status);

            for (name, val) in upstream_res.headers() {
                if !is_hop_by_hop(name) {
                    response_builder = response_builder.header(name, val);
                }
            }

            let stream = upstream_res.bytes_stream();
            let body = Body::from_stream(stream);

            response_builder.body(body).unwrap_or_else(|_| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Failed to construct proxy response body",
                )
                    .into_response()
            })
        }
        Err(err) => {
            tracing::warn!("Proxy error forwarding to {}: {}", target_url, err);
            (
                StatusCode::BAD_GATEWAY,
                Json(json!({
                    "error": "Bad Gateway",
                    "message": "Failed to connect to upstream Flask backend",
                    "target": target_url,
                    "details": err.to_string(),
                })),
            )
                .into_response()
        }
    }
}
