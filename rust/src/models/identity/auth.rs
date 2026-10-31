use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountResponse {
    pub authenticated: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub picture: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_admin: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub oauth_configured: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct LoginPinPayload {
    pub pin: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdminStatusResponse {
    pub is_admin: bool,
    pub has_pin: bool,
    pub user: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AdminVerifyRequest {
    pub pin: Option<String>,
    pub admin_pin: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdminVerifyResponse {
    pub success: bool,
    pub admin: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AdminPinUpdateRequest {
    pub new_pin: Option<String>,
    pub current_pin: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AllowlistResponse {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub success: Option<bool>,
    pub stored: Vec<String>,
    pub environment: Vec<String>,
    pub effective: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AllowlistUpdateRequest {
    pub emails: Option<Vec<String>>,
    pub admin_pin: Option<String>,
    pub pin: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdminOtpGenerateResponse {
    pub otp: String,
    pub expires_at: chrono::DateTime<chrono::Utc>,
    pub expires_in: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AdminOtpVerifyRequest {
    pub otp: Option<String>,
    #[serde(default)]
    pub code: Option<String>,
    #[serde(default)]
    pub pin: Option<String>,
    #[serde(default)]
    pub admin_email: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdminOtpVerifyResponse {
    pub success: bool,
    pub admin: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_token: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdminOtpRevokeResponse {
    pub success: bool,
    pub revoked: u64,
}
