use axum::{
    body::Body,
    http::{header, Request, Response, StatusCode},
};
use http_body_util::BodyExt;
use media_server_api::{
    db,
    routes::upload::{build_upload_routes, UploadState},
    test_support,
};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use tower::ServiceExt;

struct UploadCtx {
    app: axum::Router,
    pool: sqlx::PgPool,
    root: PathBuf,
    target: PathBuf,
    tmp: PathBuf,
    admin_session: String,
}

impl UploadCtx {
    async fn new() -> Self {
        dotenvy::dotenv().ok();
        let config = test_support::test_config().await;
        let pool = db::create_pool(&config.database_url)
            .await
            .expect("Failed to connect to test database");

        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let sub = format!("sub_upload_test_{}_{}", std::process::id(), nonce);
        let session_id = format!("sess_upload_test_{}_{}", std::process::id(), nonce);

        sqlx::query(
            "INSERT INTO users (google_sub, email, name, role, created_at, last_login_at) \
             VALUES ($1, $2, 'Upload Admin', 'admin', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) \
             ON CONFLICT (google_sub) DO UPDATE SET email = EXCLUDED.email, role = EXCLUDED.role",
        )
        .bind(&sub)
        .bind("admin.upload@example.com")
        .execute(&pool)
        .await
        .unwrap();

        let user_id: i64 = sqlx::query_scalar("SELECT id FROM users WHERE google_sub = $1")
            .bind(&sub)
            .fetch_one(&pool)
            .await
            .unwrap();

        sqlx::query(
            "INSERT INTO sessions (id, user_id, email, role, expires_at) \
             VALUES ($1, $2, $3, 'admin', CURRENT_TIMESTAMP + INTERVAL '30 days') \
             ON CONFLICT (id) DO UPDATE SET user_id = EXCLUDED.user_id, \
                 email = EXCLUDED.email, role = EXCLUDED.role, expires_at = EXCLUDED.expires_at",
        )
        .bind(&session_id)
        .bind(user_id)
        .bind("admin.upload@example.com")
        .execute(&pool)
        .await
        .unwrap();

        let root =
            std::env::temp_dir().join(format!("ms_upload_it_{}_{}", std::process::id(), nonce));
        let target = root.join("media");
        let tmp = root.join("tmp");
        std::fs::create_dir_all(&target).unwrap();
        std::fs::create_dir_all(&tmp).unwrap();

        let scan_trigger: Arc<dyn Fn() -> bool + Send + Sync> = Arc::new(|| false);
        let app = build_upload_routes(UploadState {
            pool: Arc::new(pool.clone()),
            media_root: target.clone(),
            upload_tmp: tmp.clone(),
            upload_target_dir: target.clone(),
            scan_trigger,
        });

        Self {
            app,
            pool,
            root,
            target,
            tmp,
            admin_session: session_id,
        }
    }

    async fn restore_pin(&self) {
        let _ = sqlx::query("DELETE FROM sessions WHERE id = $1")
            .bind(&self.admin_session)
            .execute(&self.pool)
            .await;
    }

    async fn remove_movie(&self, filename: &str) {
        let _ = sqlx::query("DELETE FROM movies WHERE filename = $1")
            .bind(filename)
            .execute(&self.pool)
            .await;
    }
}

impl Drop for UploadCtx {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn init_req(uri: &str, session: Option<&str>, payload: &Value) -> Request<Body> {
    let mut builder = Request::builder()
        .method("POST")
        .uri(uri)
        .header(header::CONTENT_TYPE, "application/json");
    if let Some(sess) = session {
        builder = builder.header(header::COOKIE, format!("session_token={}", sess));
    }
    builder.body(Body::from(payload.to_string())).unwrap()
}

fn admin_req(method: &str, uri: &str, session: &str) -> axum::http::request::Builder {
    Request::builder()
        .method(method)
        .uri(uri)
        .header(header::COOKIE, format!("session_token={}", session))
}

async fn body_json(res: Response<Body>) -> Value {
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn upload_routes_require_admin_and_ignore_query_pins() {
    let ctx = UploadCtx::new().await;
    let payload = json!({"filename": "auth.mp4", "size": 10});

    // 1. Anonymous request without session fails 403
    let no_pin = ctx
        .app
        .clone()
        .oneshot(init_req("/api/upload/chunk/init", None, &payload))
        .await
        .unwrap();
    assert_eq!(no_pin.status(), StatusCode::FORBIDDEN);

    // 2. Legacy static X-Admin-Pin header fails 403 (decommissioned)
    let legacy_pin = ctx
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/upload/chunk/init")
                .header(header::CONTENT_TYPE, "application/json")
                .header("X-Admin-Pin", "97531")
                .body(Body::from(payload.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(legacy_pin.status(), StatusCode::FORBIDDEN);

    // 3. A query-string PIN is deliberately not read.
    let query_pin = ctx
        .app
        .clone()
        .oneshot(init_req("/api/upload/chunk/init?pin=97531", None, &payload))
        .await
        .unwrap();
    assert_eq!(query_pin.status(), StatusCode::FORBIDDEN);

    // 4. Valid admin session succeeds
    let ok = ctx
        .app
        .clone()
        .oneshot(init_req(
            "/api/upload/chunk/init",
            Some(&ctx.admin_session),
            &payload,
        ))
        .await
        .unwrap();
    assert_eq!(ok.status(), StatusCode::OK);
    let body = body_json(ok).await;
    assert_eq!(body["success"], true);
    let id = body["upload_id"].as_str().unwrap();

    let abort = admin_req(
        "DELETE",
        &format!("/api/upload/chunk/{}", id),
        &ctx.admin_session,
    )
    .body(Body::empty())
    .unwrap();
    let abort_res = ctx.app.clone().oneshot(abort).await.unwrap();
    assert_eq!(abort_res.status(), StatusCode::OK);

    ctx.restore_pin().await;
}

#[tokio::test]
async fn chunk_flow_enforces_offsets_limits_and_completes() {
    let ctx = UploadCtx::new().await;
    let name = format!("Upload Source {}.mp4", std::process::id());
    let title = format!("Upload Test {}", std::process::id());
    let final_name = format!("{}.mp4", title);

    let init = ctx
        .app
        .clone()
        .oneshot(init_req(
            "/api/upload/chunk/init",
            Some(&ctx.admin_session),
            &json!({"filename": name, "size": 12, "title": title}),
        ))
        .await
        .unwrap();
    assert_eq!(init.status(), StatusCode::OK);
    let init_body = body_json(init).await;
    let id = init_body["upload_id"].as_str().unwrap().to_string();

    // A wrong offset is a conflict that reports where the server actually is.
    let wrong_offset = admin_req(
        "POST",
        &format!("/api/upload/chunk/{}", id),
        &ctx.admin_session,
    )
    .header("X-Upload-Offset", "5")
    .body(Body::from(vec![0u8; 1]))
    .unwrap();
    let wrong_res = ctx.app.clone().oneshot(wrong_offset).await.unwrap();
    assert_eq!(wrong_res.status(), StatusCode::CONFLICT);
    let wrong_body = body_json(wrong_res).await;
    assert_eq!(wrong_body["current_offset"], 0);

    let first = admin_req(
        "POST",
        &format!("/api/upload/chunk/{}", id),
        &ctx.admin_session,
    )
    .header("X-Upload-Offset", "0")
    .body(Body::from(vec![b'a'; 5]))
    .unwrap();
    let first_res = ctx.app.clone().oneshot(first).await.unwrap();
    assert_eq!(first_res.status(), StatusCode::OK);
    assert_eq!(body_json(first_res).await["offset"], 5);

    let early_complete = admin_req(
        "POST",
        &format!("/api/upload/chunk/{}/complete", id),
        &ctx.admin_session,
    )
    .body(Body::empty())
    .unwrap();
    let early_res = ctx.app.clone().oneshot(early_complete).await.unwrap();
    assert_eq!(early_res.status(), StatusCode::BAD_REQUEST);

    // 8 MiB + 1 is under the route's transport allowance, so the handler's own
    // 8 MiB check must produce the 413.
    let oversized_handler = admin_req(
        "POST",
        &format!("/api/upload/chunk/{}", id),
        &ctx.admin_session,
    )
    .header("X-Upload-Offset", "5")
    .body(Body::from(vec![0u8; 8 * 1024 * 1024 + 1]))
    .unwrap();
    let oversized_handler_res = ctx.app.clone().oneshot(oversized_handler).await.unwrap();
    assert_eq!(
        oversized_handler_res.status(),
        StatusCode::PAYLOAD_TOO_LARGE
    );

    // 9 MiB is past the transport limit and is rejected before the handler.
    let oversized_transport = admin_req(
        "POST",
        &format!("/api/upload/chunk/{}", id),
        &ctx.admin_session,
    )
    .header("X-Upload-Offset", "5")
    .body(Body::from(vec![0u8; 9 * 1024 * 1024]))
    .unwrap();
    let oversized_transport_res = ctx.app.clone().oneshot(oversized_transport).await.unwrap();
    assert_eq!(
        oversized_transport_res.status(),
        StatusCode::PAYLOAD_TOO_LARGE
    );

    // The 12-byte declaration still has only the first 5 bytes.
    let rest = admin_req(
        "POST",
        &format!("/api/upload/chunk/{}", id),
        &ctx.admin_session,
    )
    .header("X-Upload-Offset", "5")
    .body(Body::from(vec![b'b'; 7]))
    .unwrap();
    let rest_res = ctx.app.clone().oneshot(rest).await.unwrap();
    assert_eq!(rest_res.status(), StatusCode::OK);
    let rest_body = body_json(rest_res).await;
    assert_eq!(rest_body["offset"], 12);
    assert_eq!(rest_body["complete"], true);

    let complete = admin_req(
        "POST",
        &format!("/api/upload/chunk/{}/complete", id),
        &ctx.admin_session,
    )
    .body(Body::empty())
    .unwrap();
    let complete_res = ctx.app.clone().oneshot(complete).await.unwrap();
    assert_eq!(complete_res.status(), StatusCode::OK);
    let complete_body = body_json(complete_res).await;
    assert_eq!(complete_body["success"], true);
    assert_eq!(complete_body["filename"], final_name);
    assert_eq!(complete_body["title"], title);
    assert_eq!(
        complete_body["details_url"],
        format!("/movie/{}", final_name)
    );

    let target_path = ctx.target.join(&final_name);
    assert!(target_path.is_file(), "completed upload should be on disk");
    assert_eq!(std::fs::read(&target_path).unwrap().len(), 12);
    assert!(!ctx.tmp.join(format!("{}.json", id)).exists());
    assert!(!ctx.tmp.join(format!("{}.part", id)).exists());

    let row: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM movies WHERE filename = $1")
        .bind(&final_name)
        .fetch_one(&ctx.pool)
        .await
        .unwrap();
    assert_eq!(row.0, 1);

    ctx.remove_movie(&final_name).await;
    let _ = std::fs::remove_file(&target_path);
    ctx.restore_pin().await;
}

#[tokio::test]
async fn abort_removes_temp_files() {
    let ctx = UploadCtx::new().await;
    let init = ctx
        .app
        .clone()
        .oneshot(init_req(
            "/api/upload/chunk/init",
            Some(&ctx.admin_session),
            &json!({"filename": "abort.mp4", "size": 4}),
        ))
        .await
        .unwrap();
    assert_eq!(init.status(), StatusCode::OK);
    let body = body_json(init).await;
    let id = body["upload_id"].as_str().unwrap().to_string();

    let chunk = admin_req(
        "POST",
        &format!("/api/upload/chunk/{}", id),
        &ctx.admin_session,
    )
    .header("X-Upload-Offset", "0")
    .body(Body::from(vec![b'x'; 2]))
    .unwrap();
    assert_eq!(
        ctx.app.clone().oneshot(chunk).await.unwrap().status(),
        StatusCode::OK
    );

    let abort = admin_req(
        "DELETE",
        &format!("/api/upload/chunk/{}", id),
        &ctx.admin_session,
    )
    .body(Body::empty())
    .unwrap();
    assert_eq!(
        ctx.app.clone().oneshot(abort).await.unwrap().status(),
        StatusCode::OK
    );

    assert!(!ctx.tmp.join(format!("{}.json", id)).exists());
    assert!(!ctx.tmp.join(format!("{}.part", id)).exists());
    ctx.restore_pin().await;
}

#[tokio::test]
async fn single_file_compatibility_route_writes_and_indexes() {
    let ctx = UploadCtx::new().await;
    let name = format!("Single File {}.mp4", std::process::id());
    let boundary = "----msuploadtestboundary";
    let file_bytes = b"fake but byte-addressable mp4 payload";

    let head = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\nContent-Type: video/mp4\r\n\r\n"
    );
    let mut multipart = Vec::new();
    multipart.extend_from_slice(head.as_bytes());
    multipart.extend_from_slice(file_bytes);
    multipart.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());

    let req = Request::builder()
        .method("POST")
        .uri("/api/upload")
        .header(
            header::CONTENT_TYPE,
            format!("multipart/form-data; boundary={}", boundary),
        )
        .header(
            header::COOKIE,
            format!("session_token={}", ctx.admin_session),
        )
        .body(Body::from(multipart))
        .unwrap();
    let res = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res).await;
    assert_eq!(body["success"], true);
    assert_eq!(body["filename"], name);

    let target_path = ctx.target.join(&name);
    assert_eq!(std::fs::read(&target_path).unwrap(), file_bytes);

    ctx.remove_movie(&name).await;
    let _ = std::fs::remove_file(&target_path);
    ctx.restore_pin().await;
}

#[tokio::test]
async fn upload_init_keeps_the_default_json_body_limit() {
    let ctx = UploadCtx::new().await;
    let body = vec![b'x'; 3 * 1024 * 1024];
    let req = Request::builder()
        .method("POST")
        .uri("/api/upload/chunk/init")
        .header(header::CONTENT_TYPE, "application/json")
        .header(
            header::COOKIE,
            format!("session_token={}", ctx.admin_session),
        )
        .body(Body::from(body))
        .unwrap();
    let res = ctx.app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::PAYLOAD_TOO_LARGE);
    ctx.restore_pin().await;
}
