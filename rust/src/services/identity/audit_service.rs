use crate::models::audit::{AuditLogEntry, AuditLogResponse};
use serde_json::Value;
use sqlx::{PgPool, Row};
use tracing::{error, info};

pub struct AuditService;

impl AuditService {
    /// Extract client IP address from standard reverse-proxy headers.
    pub fn extract_client_ip(headers: &axum::http::HeaderMap) -> Option<String> {
        headers
            .get("x-forwarded-for")
            .or_else(|| headers.get("x-real-ip"))
            .and_then(|v| v.to_str().ok())
            .map(|s| s.split(',').next().unwrap_or(s).trim().to_string())
    }

    /// Extract actor type and identifier from request context (admin session, user session, or admin PIN).
    pub async fn extract_actor(
        pool: &PgPool,
        headers: &axum::http::HeaderMap,
        explicit_pin: Option<&str>,
    ) -> (&'static str, String) {
        if let Some(identity) =
            crate::services::auth_service::AuthService::resolve_session_identity(pool, headers)
                .await
        {
            if identity.is_admin {
                ("admin_session", identity.email)
            } else {
                ("user_session", identity.email)
            }
        } else if crate::services::auth_service::AuthService::is_admin_authorized(
            pool,
            headers,
            explicit_pin,
        )
        .await
        {
            ("admin_pin", "pin".to_string())
        } else {
            ("guest", "anonymous".to_string())
        }
    }

    /// Persist an administrative mutation event into `audit_logs`.
    /// Logging failures are caught and logged via tracing without failing caller operations.
    pub async fn record_event(
        pool: &PgPool,
        actor_type: &str,
        actor_id: &str,
        action: &str,
        target_type: Option<&str>,
        target_id: Option<&str>,
        details: Option<Value>,
        ip_address: Option<&str>,
    ) {
        let res = sqlx::query(
            r#"
            INSERT INTO audit_logs (
                actor_type, actor_id, action, target_type, target_id, details, ip_address, created_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, CURRENT_TIMESTAMP)
            "#,
        )
        .bind(actor_type)
        .bind(actor_id)
        .bind(action)
        .bind(target_type)
        .bind(target_id)
        .bind(details)
        .bind(ip_address)
        .execute(pool)
        .await;

        if let Err(e) = res {
            error!(
                "Failed to write audit log event (action: {}, actor: {}): {}",
                action, actor_id, e
            );
        } else {
            info!(
                "Audit log: [{}] by {}:{} on {:?}:{:?}",
                action, actor_type, actor_id, target_type, target_id
            );
        }
    }

    /// Query recent audit logs with pagination and optional action filtering.
    pub async fn list_logs(
        pool: &PgPool,
        limit: Option<i64>,
        offset: Option<i64>,
        action_filter: Option<&str>,
    ) -> Result<AuditLogResponse, sqlx::Error> {
        let clamped_limit = limit.unwrap_or(50).clamp(1, 200);
        let clamped_offset = offset.unwrap_or(0).max(0);

        let (rows, total) = if let Some(act) = action_filter.filter(|a| !a.trim().is_empty()) {
            let total: i64 =
                sqlx::query_scalar("SELECT COUNT(*) FROM audit_logs WHERE action = $1")
                    .bind(act)
                    .fetch_one(pool)
                    .await?;

            let rows = sqlx::query(
                r#"
                SELECT id, actor_type, actor_id, action, target_type, target_id, details, ip_address, created_at
                FROM audit_logs
                WHERE action = $1
                ORDER BY created_at DESC
                LIMIT $2 OFFSET $3
                "#,
            )
            .bind(act)
            .bind(clamped_limit)
            .bind(clamped_offset)
            .fetch_all(pool)
            .await?;

            (rows, total)
        } else {
            let total: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_logs")
                .fetch_one(pool)
                .await?;

            let rows = sqlx::query(
                r#"
                SELECT id, actor_type, actor_id, action, target_type, target_id, details, ip_address, created_at
                FROM audit_logs
                ORDER BY created_at DESC
                LIMIT $1 OFFSET $2
                "#,
            )
            .bind(clamped_limit)
            .bind(clamped_offset)
            .fetch_all(pool)
            .await?;

            (rows, total)
        };

        let mut entries = Vec::new();
        for r in rows {
            entries.push(AuditLogEntry {
                id: r.get("id"),
                actor_type: r.get("actor_type"),
                actor_id: r.get("actor_id"),
                action: r.get("action"),
                target_type: r.get("target_type"),
                target_id: r.get("target_id"),
                details: r.get("details"),
                ip_address: r.get("ip_address"),
                created_at: r.get("created_at"),
            });
        }

        Ok(AuditLogResponse {
            logs: entries,
            total,
            limit: clamped_limit,
            offset: clamped_offset,
        })
    }
}
