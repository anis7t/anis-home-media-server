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
pub struct TokenRecord {
    pub id: i64,
    pub user_id: i64,
    pub label: String,
    pub created_at: i64,
    pub last_used_at: Option<i64>,
    pub expires_at: Option<i64>,
    pub revoked_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokensResponse {
    pub tokens: Vec<TokenRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CreateTokenRequest {
    pub label: Option<String>,
    pub validity_days: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MintedToken {
    pub token: String,
    pub pairing_url: String,
    pub id: i64,
    pub label: String,
    pub expires_at: Option<i64>,
    pub warning: String,
}
