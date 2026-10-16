use axum::http::HeaderMap;
use sqlx::PgPool;

pub struct AuthService;

impl AuthService {
    /// Verify whether a request is administrator-authorized (via valid configured Admin PIN).
    ///
    /// Per AGENTS.md §4:
    /// - The Admin PIN fails closed, and has no default.
    /// - Unset/empty in database means the PIN channel is CLOSED (returns false).
    /// - Accepts PIN only from `X-Admin-Pin` header or request body. NEVER from query string.
    pub async fn is_admin_authorized(
        pool: &PgPool,
        headers: &HeaderMap,
        body_pin: Option<&str>,
    ) -> bool {
        // Query stored pin from PostgreSQL settings table
        let stored_pin: Option<String> =
            sqlx::query_scalar("SELECT value FROM settings WHERE key = 'admin_pin'")
                .fetch_optional(pool)
                .await
                .unwrap_or(None);

        let stored = stored_pin.unwrap_or_default().trim().to_string();
        if stored.is_empty() {
            // Fail closed: without a deliberately configured PIN, PIN auth is closed.
            return false;
        }

        let pin_header = headers
            .get("X-Admin-Pin")
            .and_then(|v| v.to_str().ok())
            .map(|s| s.trim());

        let candidate_pin = pin_header.or_else(|| body_pin.map(|s| s.trim()));

        if let Some(pin) = candidate_pin {
            if pin == stored {
                return true;
            }
        }

        false
    }
}
