use crate::error::AppError;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Row};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// iQOO model-code table, copied verbatim from `device_service.py`. The codes
/// are the Client Hints `Sec-CH-UA-Model` values Vivo devices send.
const IQOO_MODELS: [(&str, &str); 21] = [
    ("I2011", "iQOO 7"),
    ("I2012", "iQOO 7 Legend"),
    ("I2126", "iQOO 9 Pro"),
    ("I2202", "iQOO Neo 7"),
    ("I2208", "iQOO Z7"),
    ("I2209", "iQOO Z7 Pro"),
    ("I2217", "iQOO Neo 7 Pro"),
    ("I2220", "iQOO 11"),
    ("I2301", "iQOO 12"),
    ("I2307", "iQOO Z9"),
    ("I2308", "iQOO Z9x"),
    ("I2401", "iQOO 13"),
    ("V2202", "iQOO Neo 7"),
    ("V2164A", "iQOO 9"),
    ("V2170A", "iQOO 9 Pro"),
    ("V2231A", "iQOO 11"),
    ("V2241A", "iQOO Neo 8"),
    ("V2307A", "iQOO 12"),
    ("V2324A", "iQOO Neo 9"),
    ("V2339A", "iQOO Neo 9 Pro"),
    ("V2164B", "iQOO 9"),
];

#[derive(Debug, Clone, Serialize, Default)]
pub struct ParsedAgent {
    pub device_type: String,
    pub device_os: String,
    pub browser: String,
    pub device_name: String,
    pub device_model: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ConnectionInfo {
    pub connection_type: String,
    pub client_ip: String,
    pub public_ip: Option<String>,
    pub is_cloudflare: bool,
}

#[derive(Debug, Clone)]
pub struct GeoInfo {
    pub isp: String,
    pub city: String,
    pub country: String,
}

/// Client Hints, as read from request headers.
#[derive(Debug, Clone, Default)]
pub struct ClientHints {
    pub model: Option<String>,
    pub platform: Option<String>,
    pub platform_version: Option<String>,
    pub mobile: Option<String>,
}

/// A client-supplied device id, accepted only in the shapes this app mints.
///
/// `dev_` is the server's fingerprint family and the Flutter client's;
/// `web_` is the SPA's localStorage id (`web/src/lib/useDeviceId.ts`).
///
/// The body is restricted to ASCII so a header cannot smuggle a path
/// separator or an unbounded string into a value used as a primary key, and
/// bounded so the key stays a key. This is narrower than the `dev_`-only
/// check it replaces, which accepted any `dev_`-prefixed string at all.
fn is_client_device_id(id: &str) -> bool {
    let Some((prefix, body)) = id.split_once('_') else {
        return false;
    };
    matches!(prefix, "dev" | "web")
        && !body.is_empty()
        && body.len() <= 64
        && body
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

pub struct DeviceService;

impl DeviceService {
    /// Device id for this request: the client's own id, then a deterministic
    /// hash of client IP + User-Agent.
    ///
    /// The header wins over the cookie. `ms_device_id` is a Flask-era artefact:
    /// Flask stamped it on every HTML response for a year
    /// (`c5ee97d^:app/__init__.py`) and Rust neither mints nor refreshes it, so
    /// a stale one would otherwise shadow the live client's own id for up to a
    /// year. Browsers that visited the Flask app still carry one.
    ///
    /// Both id families this app mints are accepted: `dev_` (the fingerprint
    /// and the Flutter client) and `web_` (the SPA's `useDeviceId`). Accepting
    /// only `dev_` was the whole of Issue 14.1: `/api/progress` wrote history
    /// under `web_...` while this function discarded that header and answered
    /// with a fingerprint row, so the devices page listed a device that had
    /// never played anything.
    ///
    /// The fallback hash MUST match Flask's byte for byte: seed
    /// `"{ip}|{ua}"`, SHA-256, first 16 hex characters, prefixed `dev_`.
    /// If it diverges by even a character every existing client becomes a
    /// new device and the fleet view fragments into duplicates - the rows are
    /// keyed on this value.
    pub fn get_or_create_device_id(
        cookie_id: Option<&str>,
        header_id: Option<&str>,
        client_ip: &str,
        user_agent: &str,
    ) -> (String, bool) {
        if let Some(h) = header_id.map(str::trim).filter(|h| is_client_device_id(h)) {
            return (h.to_string(), false);
        }
        if let Some(c) = cookie_id.map(str::trim).filter(|c| is_client_device_id(c)) {
            return (c.to_string(), false);
        }
        let seed = format!("{}|{}", client_ip, user_agent);
        let digest = Sha256::digest(seed.as_bytes());
        let prefix: String = digest
            .iter()
            .take(8)
            .map(|b| format!("{:02x}", b))
            .collect();
        (format!("dev_{}", prefix), true)
    }

    /// Friendly make/model from a raw model code or Client Hints.
    pub fn resolve_device_make_model(model_raw: Option<&str>, ua: &str) -> (String, String) {
        let mut clean = model_raw
            .unwrap_or("")
            .trim()
            .trim_matches(['"', '\'', ' '])
            .trim()
            .to_string();
        // Chromium's UA-reduction dummy placeholder carries no information.
        if clean == "K" || clean == "Unknown" || clean.is_empty() {
            clean = String::new();
        }

        if !clean.is_empty() {
            let upper = clean.to_uppercase();
            if let Some((_, label)) = IQOO_MODELS.iter().find(|(code, _)| *code == upper) {
                return (format!("Vivo {}", label), format!("{} ({})", label, clean));
            }
            if is_iqoo_code(&upper) {
                return ("Vivo iQOO".to_string(), format!("iQOO ({})", clean));
            }
            if clean.to_lowercase().contains("iqoo") {
                return (format!("Vivo {}", clean), clean.clone());
            }
            if is_vivo_code(&upper) {
                return ("Vivo".to_string(), format!("Vivo ({})", clean));
            }

            if upper.starts_with("SM-") {
                let name = if upper.starts_with("SM-S9") {
                    "Samsung Galaxy S Ultra/Plus"
                } else if upper.starts_with("SM-S") {
                    "Samsung Galaxy S"
                } else if upper.starts_with("SM-A") {
                    "Samsung Galaxy A"
                } else if upper.starts_with("SM-M") {
                    "Samsung Galaxy M"
                } else if upper.starts_with("SM-F") {
                    "Samsung Galaxy Z Fold/Flip"
                } else if upper.starts_with("SM-N") {
                    "Samsung Galaxy Note"
                } else if upper.starts_with("SM-T") || upper.starts_with("SM-X") {
                    "Samsung Galaxy Tab"
                } else {
                    "Samsung Galaxy"
                };
                return (name.to_string(), clean.clone());
            }

            let lower = clean.to_lowercase();
            if lower.contains("pixel") {
                return (format!("Google {}", clean), clean.clone());
            }
            if lower.contains("oneplus")
                || ["KB20", "IN20", "NE22", "CPH2413", "CPH2449", "CPH2573"]
                    .iter()
                    .any(|p| upper.starts_with(p))
            {
                return (format!("OnePlus ({})", clean), clean.clone());
            }
            if lower.contains("redmi") {
                return (format!("Xiaomi {}", clean), clean.clone());
            }
            if lower.contains("poco") {
                return (format!("POCO {}", clean), clean.clone());
            }
            if is_xiaomi_code(&upper) {
                return ("Xiaomi / Redmi".to_string(), clean.clone());
            }
            if upper.starts_with("RMX") {
                return ("Realme".to_string(), format!("Realme ({})", clean));
            }
            if upper.starts_with("MOTO") || upper.starts_with("XT") {
                return ("Motorola".to_string(), clean.clone());
            }
            return (clean.clone(), clean);
        }

        // No model: recover it from a full (non-reduced) User-Agent.
        if !ua.is_empty() {
            let lower = ua.to_lowercase();
            if lower.contains("iphone") {
                return ("Apple iPhone".into(), "iPhone".into());
            }
            if lower.contains("ipad") {
                return ("Apple iPad".into(), "iPad".into());
            }
            if lower.contains("macintosh") {
                return ("Apple Mac".into(), "Mac".into());
            }
            if let Some(cand) = segment_before(ua, " Build/").or_else(|| segment_before(ua, ")")) {
                let cand = cand.trim().to_string();
                if cand != "K" && !cand.is_empty() {
                    return Self::resolve_device_make_model(Some(&cand), "");
                }
            }
            if lower.contains("android") {
                return ("Android Smartphone".into(), "Smartphone".into());
            }
        }

        ("Generic Client".into(), "Unknown Device".into())
    }

    /// OS label, refined by Client Hints where they are more precise.
    pub fn resolve_device_os(ua_os: &str, platform_raw: &str, platform_ver_raw: &str) -> String {
        let plat = platform_raw
            .trim()
            .trim_matches(['"', '\'', ' '])
            .trim()
            .to_lowercase();
        let ver = platform_ver_raw
            .trim()
            .trim_matches(['"', '\'', ' '])
            .trim()
            .to_string();
        let ua_lower = ua_os.to_lowercase();

        if plat.contains("android") || ua_lower.contains("android") {
            if !ver.is_empty() {
                if let Some(major) = ver.split('.').next().and_then(|m| m.parse::<u32>().ok()) {
                    if major >= 5 {
                        return format!("Android {}", major);
                    }
                }
            }
            return if ua_os.is_empty() {
                "Android".into()
            } else {
                ua_os.to_string()
            };
        }
        if plat.contains("windows") || ua_lower.contains("windows") {
            if !ver.is_empty() {
                if let Some(major) = ver.split('.').next().and_then(|m| m.parse::<u32>().ok()) {
                    return if major >= 13 {
                        "Windows 11".into()
                    } else {
                        "Windows 10".into()
                    };
                }
            }
            return if ua_os.is_empty() {
                "Windows".into()
            } else {
                ua_os.to_string()
            };
        }
        if plat.contains("macos") || ua_lower.contains("mac") {
            if !ver.is_empty() {
                if let Some(major) = ver.split('.').next() {
                    return format!("macOS {}", major);
                }
            }
            return if ua_os.is_empty() {
                "macOS".into()
            } else {
                ua_os.to_string()
            };
        }
        if ua_os.is_empty() {
            "Unknown OS".into()
        } else {
            ua_os.to_string()
        }
    }

    /// Full User-Agent parse, mirroring `parse_user_agent` branch for branch.
    pub fn parse_user_agent(ua: &str, ch: &ClientHints) -> ParsedAgent {
        if ua.is_empty() {
            let (name, model) = Self::resolve_device_make_model(ch.model.as_deref(), "");
            return ParsedAgent {
                device_type: if ch.mobile.as_deref() == Some("?1") {
                    "Mobile".into()
                } else {
                    "Other".into()
                },
                device_os: Self::resolve_device_os(
                    "Unknown OS",
                    ch.platform.as_deref().unwrap_or(""),
                    ch.platform_version.as_deref().unwrap_or(""),
                ),
                browser: "Unknown Browser".into(),
                device_name: name,
                device_model: Some(model),
            };
        }

        let lower = ua.to_lowercase();
        let (mut device_type, mut device_os, mut device_name, mut device_model) = (
            "Desktop".to_string(),
            "Unknown OS".to_string(),
            "Desktop PC".to_string(),
            None,
        );
        let mut browser = "Unknown Browser".to_string();

        // 1. TV / console
        if lower.contains("appletv") || lower.contains("apple tv") {
            device_type = "Smart TV".into();
            device_os = "tvOS".into();
            device_name = "Apple TV".into();
            device_model = Some("Apple TV".into());
        } else if lower.contains("tizen") {
            device_type = "Smart TV".into();
            device_os = match capture_version(ua, "Tizen") {
                Some(v) => format!("Tizen OS {}", v),
                None => "Tizen OS".into(),
            };
            device_name = "Samsung Smart TV".into();
            device_model = Some("Samsung Tizen".into());
        } else if lower.contains("web0s") || lower.contains("webos") {
            device_type = "Smart TV".into();
            device_os = "LG webOS".into();
            device_name = "LG Smart TV".into();
            device_model = Some("LG webOS".into());
        } else if lower.contains("playstation") {
            device_type = "Console".into();
            device_os = "PlayStation".into();
            device_name = "Sony PlayStation".into();
            device_model = Some("PlayStation".into());
        } else if lower.contains("xbox") {
            device_type = "Console".into();
            device_os = "Xbox OS".into();
            device_name = "Microsoft Xbox".into();
            device_model = Some("Xbox".into());
        } else if ["Roku", "SmartTV", "GoogleTV", "AndroidTV", "HbbTV", "CrKey"]
            .iter()
            .any(|k| lower.contains(&k.to_lowercase()))
        {
            device_type = "Smart TV".into();
            device_os = "Smart TV OS".into();
            device_name = "Smart TV / Streaming Stick".into();
            device_model = Some("Streaming Device".into());
        }
        // 2. Mobile / tablet / desktop
        else if lower.contains("ipad") {
            device_type = "Tablet".into();
            device_os = format_optional(
                "iPadOS",
                capture_digits(ua, "OS ").map(|v| v.replace('_', ".")),
            );
            device_name = "Apple iPad".into();
            device_model = Some("iPad".into());
        } else if lower.contains("iphone") {
            device_type = "Mobile".into();
            device_os =
                format_optional("iOS", after(ua, "iPhone OS ").map(|v| v.replace('_', ".")));
            device_name = "Apple iPhone".into();
            device_model = Some("iPhone".into());
        } else if lower.contains("android") {
            device_os = format_optional("Android", capture_version(ua, "Android"));
            if lower.contains("mobile") || ch.mobile.as_deref() == Some("?1") {
                device_type = "Mobile".into();
                let (n, m) = Self::resolve_device_make_model(ch.model.as_deref(), ua);
                device_name = if n.is_empty() {
                    "Android Smartphone".into()
                } else {
                    n
                };
                device_model = Some(m);
            } else {
                device_type = "Tablet".into();
                device_name = "Android Tablet".into();
                device_model = Some("Tablet".into());
            }
        } else if lower.contains("windows nt") {
            device_type = "Desktop".into();
            let nt = capture_version(ua, "Windows NT").unwrap_or_default();
            device_os = match nt.as_str() {
                "10.0" => "Windows 10/11".into(),
                "6.3" => "Windows 8.1".into(),
                "6.2" => "Windows 8".into(),
                "6.1" => "Windows 7".into(),
                "" => "Windows NT".into(),
                other => format!("Windows NT {}", other),
            };
            device_name = "Windows PC".into();
            device_model = Some("PC".into());
        } else if lower.contains("macintosh") || lower.contains("mac os x") {
            device_type = "Desktop".into();
            device_os =
                format_optional("macOS", after(ua, "Mac OS X").map(|v| v.replace('_', ".")));
            device_name = "Apple Mac".into();
            device_model = Some("Mac".into());
        } else if lower.contains("cros") {
            device_type = "Desktop".into();
            device_os = "ChromeOS".into();
            device_name = "Chromebook".into();
            device_model = Some("Chromebook".into());
        } else if lower.contains("linux") {
            device_type = "Desktop".into();
            device_os = "Linux".into();
            device_name = "Linux PC".into();
            device_model = Some("PC".into());
        }

        // 3. Browser, applied after the device branch exactly as in Python.
        if let Some(v) = after(ua, "Edg/")
            .or_else(|| after(ua, "EdgA/"))
            .or_else(|| after(ua, "EdgiOS/"))
            .or_else(|| after(ua, "Edge/"))
        {
            browser = format!("Edge {}", major_of(&v));
        } else if let Some(v) = after(ua, "SamsungBrowser/") {
            browser = format!("Samsung Internet {}", major_of(&v));
        } else if let Some(v) = after(ua, "Chrome/").or_else(|| after(ua, "CriOS/")) {
            browser = format!("Chrome {}", major_of(&v));
        } else if let Some(v) = after(ua, "Firefox/").or_else(|| after(ua, "FxiOS/")) {
            browser = format!("Firefox {}", major_of(&v));
        } else if lower.contains("safari") && ua.contains("Version/") {
            if let Some(v) = after(ua, "Version/") {
                browser = format!("Safari {}", major_of(&v));
            }
        } else if lower.contains("safari") && !lower.contains("chrome") {
            browser = "Safari".into();
        } else if ["curl", "python-requests", "wget"]
            .iter()
            .any(|t| lower.contains(t))
        {
            browser = ua.split('/').next().unwrap_or("").to_string();
            device_type = "Tool/Bot".into();
            device_name = "Automated Client".into();
            device_model = Some("Bot".into());
        }

        // Client Hints overrides.
        device_os = Self::resolve_device_os(
            &device_os,
            ch.platform.as_deref().unwrap_or(""),
            ch.platform_version.as_deref().unwrap_or(""),
        );
        if let Some(m) = ch.model.as_deref().filter(|m| !m.is_empty()) {
            let (n, mo) = Self::resolve_device_make_model(Some(m), ua);
            if !n.is_empty() && n != "Android Smartphone" {
                device_name = n;
            }
            if !mo.is_empty() {
                device_model = Some(mo);
            }
        }

        ParsedAgent {
            device_type,
            device_os,
            browser,
            device_name,
            device_model,
        }
    }

    /// Cloudflare / Localhost / LAN / Direct, from headers exactly as Flask.
    pub fn classify_connection(
        cf_connecting_ip: Option<&str>,
        cf_ray: Option<&str>,
        host: &str,
        x_forwarded_for: Option<&str>,
        remote_addr: &str,
    ) -> ConnectionInfo {
        let has_cf = cf_connecting_ip.is_some()
            || cf_ray.is_some()
            || host.to_lowercase().contains("trycloudflare.com");
        if has_cf {
            let ip = cf_connecting_ip
                .map(|s| s.to_string())
                .or_else(|| {
                    x_forwarded_for
                        .map(|xff| xff.split(',').next().unwrap_or("").trim().to_string())
                })
                .unwrap_or_else(|| remote_addr.to_string());
            return ConnectionInfo {
                connection_type: "Internet (Cloudflare Tunnel)".into(),
                client_ip: ip.clone(),
                public_ip: Some(ip),
                is_cloudflare: true,
            };
        }
        if remote_addr == "127.0.0.1" || remote_addr == "::1" || remote_addr == "localhost" {
            return ConnectionInfo {
                connection_type: "Localhost (127.0.0.1)".into(),
                client_ip: remote_addr.to_string(),
                public_ip: None,
                is_cloudflare: false,
            };
        }
        if is_private_ip(remote_addr) {
            return ConnectionInfo {
                connection_type: "Local Network (LAN)".into(),
                client_ip: remote_addr.to_string(),
                public_ip: None,
                is_cloudflare: false,
            };
        }
        ConnectionInfo {
            connection_type: "Internet (Direct)".into(),
            client_ip: remote_addr.to_string(),
            public_ip: Some(remote_addr.to_string()),
            is_cloudflare: false,
        }
    }

    /// MAC label.
    ///
    /// Flask resolves LAN hardware addresses from `/proc/net/arp`, a **Linux**
    /// path that does not exist on this Windows host - so on this deployment
    /// it already falls through to "LAN (ARP Pending)". That Windows
    /// behaviour is reproduced rather than "fixed": implementing an ARP read
    /// here would change what the dashboard displays.
    pub fn resolve_mac_address(client_ip: &str, connection_type: &str) -> String {
        if connection_type == "Localhost (127.0.0.1)"
            || client_ip == "127.0.0.1"
            || client_ip == "::1"
            || client_ip == "localhost"
        {
            return "Local Loopback (lo)".into();
        }
        if connection_type.contains("Internet") || connection_type.contains("Cloudflare") {
            return "WAN Proxy (Not L2 routable)".into();
        }
        "LAN (ARP Pending)".into()
    }

    /// ISP / city / country, cached in `ip_cache`.
    ///
    /// Flask performs this inside the request with a 1.5s timeout against
    /// ip-api.com. The budget is kept deliberately: a geo lookup must never
    /// turn a device heartbeat into a slow or failed request. Async here
    /// makes it cheaper, not different.
    pub async fn lookup_geoip_and_isp(
        pool: Option<&PgPool>,
        ip: &str,
        connection_type: &str,
    ) -> GeoInfo {
        if connection_type == "Localhost (127.0.0.1)" {
            return GeoInfo {
                isp: "Local Loopback".into(),
                city: "Localhost".into(),
                country: "Local System".into(),
            };
        }
        if connection_type == "Local Network (LAN)" {
            return GeoInfo {
                isp: "Local Network (LAN)".into(),
                city: "Home Network".into(),
                country: "Local Subnet".into(),
            };
        }
        if ip.is_empty() || is_private_ip(ip) {
            return GeoInfo {
                isp: "Private Network".into(),
                city: "LAN".into(),
                country: "Internal".into(),
            };
        }

        if let Some(pool) = pool {
            if let Ok(Some(row)) =
                sqlx::query("SELECT isp, city, country FROM ip_cache WHERE ip = $1")
                    .bind(ip)
                    .fetch_optional(pool)
                    .await
            {
                if let Some(isp) = row.try_get::<Option<String>, _>("isp").ok().flatten() {
                    if !isp.is_empty() {
                        return GeoInfo {
                            isp,
                            city: row
                                .try_get::<Option<String>, _>("city")
                                .ok()
                                .flatten()
                                .filter(|c| !c.is_empty())
                                .unwrap_or_else(|| "Unknown".into()),
                            country: row
                                .try_get::<Option<String>, _>("country")
                                .ok()
                                .flatten()
                                .filter(|c| !c.is_empty())
                                .unwrap_or_else(|| "Unknown".into()),
                        };
                    }
                }
            }
        }

        let default = GeoInfo {
            isp: "Cloudflare / External ISP".into(),
            city: "Internet".into(),
            country: "Remote".into(),
        };

        let url = format!(
            "http://ip-api.com/json/{}?fields=status,message,country,city,isp,org",
            ip
        );
        // GeoIP is best-effort: a failure here must degrade to the default
        // label, never surface as an error on a keepalive request.
        let client = match reqwest::Client::builder()
            .timeout(Duration::from_millis(1500))
            .build()
        {
            Ok(c) => c,
            Err(_) => return default,
        };
        let response = match client
            .get(&url)
            .header("User-Agent", "MediaServerDeviceTracker/1.0")
            .send()
            .await
        {
            Ok(r) => r,
            Err(_) => return default,
        };
        let fetched: serde_json::Value = match response.json().await {
            Ok(v) => v,
            Err(_) => return default,
        };

        if fetched.get("status").and_then(|s| s.as_str()) != Some("success") {
            return default;
        }
        let isp = fetched
            .get("isp")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .or_else(|| fetched.get("org").and_then(|v| v.as_str()))
            .unwrap_or("External ISP")
            .to_string();
        let city = fetched
            .get("city")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("Remote")
            .to_string();
        let country = fetched
            .get("country")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("Internet")
            .to_string();

        if let Some(pool) = pool {
            let org = fetched
                .get("org")
                .and_then(|v| v.as_str())
                .unwrap_or(&isp)
                .to_string();
            let _ = sqlx::query(
                "INSERT INTO ip_cache (ip, isp, org, city, country, updated_at) \
                 VALUES ($1, $2, $3, $4, $5, CURRENT_TIMESTAMP) \
                 ON CONFLICT (ip) DO UPDATE SET isp = EXCLUDED.isp, org = EXCLUDED.org, \
                 city = EXCLUDED.city, country = EXCLUDED.country, updated_at = CURRENT_TIMESTAMP",
            )
            .bind(ip)
            .bind(&isp)
            .bind(&org)
            .bind(&city)
            .bind(&country)
            .execute(pool)
            .await;
        }

        GeoInfo { isp, city, country }
    }

    /// Register or refresh a device row.
    #[allow(clippy::too_many_arguments)]
    pub async fn register_device(
        pool: &PgPool,
        device_id: &str,
        ua_str: &str,
        parsed: &ParsedAgent,
        conn: &ConnectionInfo,
        mac: &str,
        geo: &GeoInfo,
    ) {
        // The CASE expressions are load-bearing: they stop a generic
        // re-registration from overwriting a specific make/model with
        // "Android Smartphone", and preserve a detailed Android version over
        // the UA placeholder "Android 10".
        let sql = r#"
        INSERT INTO devices(
            device_id, custom_name, device_name, device_type, device_os,
            browser, user_agent, connection_type, client_ip, public_ip,
            mac_address, isp, city, country, first_seen, last_seen, device_model
        ) VALUES ($1, NULL, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
                  CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, $14)
        ON CONFLICT (device_id) DO UPDATE SET
            device_name = CASE
                WHEN EXCLUDED.device_name NOT IN ('Android Smartphone','Desktop PC','Generic Client') THEN EXCLUDED.device_name
                WHEN devices.device_name IS NOT NULL AND devices.device_name NOT IN ('Android Smartphone','Desktop PC','Generic Client') THEN devices.device_name
                ELSE EXCLUDED.device_name END,
            device_model = COALESCE(NULLIF(EXCLUDED.device_model,''), devices.device_model),
            device_type = EXCLUDED.device_type,
            device_os = CASE
                WHEN EXCLUDED.device_os LIKE 'Android %' AND EXCLUDED.device_os != 'Android 10' THEN EXCLUDED.device_os
                WHEN devices.device_os LIKE 'Android %' AND devices.device_os != 'Android 10' THEN devices.device_os
                ELSE EXCLUDED.device_os END,
            browser = EXCLUDED.browser,
            user_agent = EXCLUDED.user_agent,
            connection_type = EXCLUDED.connection_type,
            client_ip = EXCLUDED.client_ip,
            public_ip = EXCLUDED.public_ip,
            mac_address = EXCLUDED.mac_address,
            isp = EXCLUDED.isp,
            city = EXCLUDED.city,
            country = EXCLUDED.country,
            last_seen = CURRENT_TIMESTAMP
        "#;
        let res = sqlx::query(sql)
            .bind(device_id)
            .bind(&parsed.device_name)
            .bind(&parsed.device_type)
            .bind(&parsed.device_os)
            .bind(&parsed.browser)
            .bind(ua_str)
            .bind(&conn.connection_type)
            .bind(&conn.client_ip)
            .bind(conn.public_ip.as_deref())
            .bind(mac)
            .bind(&geo.isp)
            .bind(&geo.city)
            .bind(&geo.country)
            .bind(parsed.device_model.as_deref().unwrap_or(""))
            .execute(pool)
            .await;
        if let Err(e) = res {
            tracing::warn!("error registering device {}: {}", device_id, e);
        }
    }

    /// Keepalive. Returns true when the device already existed.
    ///
    /// First contact falls through to a full registration, exactly as in
    /// Flask, so a new client is not recorded as a bare row.
    pub async fn record_heartbeat(pool: &PgPool, device_id: &str, ctx: &RequestFacts) {
        let updated =
            sqlx::query("UPDATE devices SET last_seen = CURRENT_TIMESTAMP WHERE device_id = $1")
                .bind(device_id)
                .execute(pool)
                .await
                .map(|r| r.rows_affected())
                .unwrap_or(0);

        if updated == 0 {
            Self::register_from_facts(pool, device_id, ctx).await;
        }
    }

    /// Full registration from already-gathered request facts.
    pub async fn register_from_facts(pool: &PgPool, device_id: &str, ctx: &RequestFacts) {
        let parsed = Self::parse_user_agent(&ctx.user_agent, &ctx.hints);
        let mac = Self::resolve_mac_address(&ctx.conn.client_ip, &ctx.conn.connection_type);
        let geo = Self::lookup_geoip_and_isp(
            Some(pool),
            ctx.conn.public_ip.as_deref().unwrap_or(&ctx.conn.client_ip),
            &ctx.conn.connection_type,
        )
        .await;
        Self::register_device(
            pool,
            device_id,
            &ctx.user_agent,
            &parsed,
            &ctx.conn,
            &mac,
            &geo,
        )
        .await;
    }

    /// Apply high-entropy Client Hints to a known device.
    ///
    /// Returns false when the device does not exist - Flask returns False in
    /// the same case, and the endpoint reports `updated: false`.
    pub async fn update_client_hints(
        pool: &PgPool,
        device_id: &str,
        model: Option<&str>,
        platform: Option<&str>,
        platform_version: Option<&str>,
    ) -> bool {
        if device_id.is_empty() {
            return false;
        }
        let row = match sqlx::query(
            "SELECT user_agent, device_os, device_name, device_model FROM devices WHERE device_id = $1",
        )
        .bind(device_id)
        .fetch_optional(pool)
        .await
        {
            Ok(Some(r)) => r,
            _ => return false,
        };

        let ua_str: String = row
            .try_get::<Option<String>, _>("user_agent")
            .ok()
            .flatten()
            .unwrap_or_default();
        let current_os: String = row
            .try_get::<Option<String>, _>("device_os")
            .ok()
            .flatten()
            .unwrap_or_default();
        let current_name: String = row
            .try_get::<Option<String>, _>("device_name")
            .ok()
            .flatten()
            .unwrap_or_default();
        let current_model: String = row
            .try_get::<Option<String>, _>("device_model")
            .ok()
            .flatten()
            .unwrap_or_default();

        let (mut name, mut resolved_model) = Self::resolve_device_make_model(model, &ua_str);
        if name.is_empty() || name == "Android Smartphone" {
            name = current_name;
        }
        if resolved_model.is_empty() {
            resolved_model = current_model;
        }
        let os = Self::resolve_device_os(
            &current_os,
            platform.unwrap_or(""),
            platform_version.unwrap_or(""),
        );

        sqlx::query(
            "UPDATE devices SET device_name = COALESCE($1, device_name), \
             device_model = COALESCE($2, device_model), device_os = COALESCE($3, device_os), \
             last_seen = CURRENT_TIMESTAMP WHERE device_id = $4",
        )
        .bind(&name)
        .bind(&resolved_model)
        .bind(&os)
        .bind(device_id)
        .execute(pool)
        .await
        .is_ok()
    }

    /// Record that `user_id` owns `device_id`, **only if the device is
    /// currently unowned**.
    ///
    /// First authenticated owner wins. A shared browser must not silently
    /// transfer a device's ownership (and, through it, its watch history) each
    /// time a different account signs in on it; a deliberate transfer is a
    /// separate action, not a side effect of loading the device list.
    ///
    /// Returns true when this call performed the claim.
    pub async fn claim_device_for_user(pool: &PgPool, device_id: &str, user_id: i64) -> bool {
        sqlx::query("UPDATE devices SET user_id = $1 WHERE device_id = $2 AND user_id IS NULL")
            .bind(user_id)
            .bind(device_id)
            .execute(pool)
            .await
            .map(|r| r.rows_affected() > 0)
            .unwrap_or(false)
    }

    /// Whether `device_id` exists and is owned by `user_id`.
    pub async fn device_owned_by(pool: &PgPool, device_id: &str, user_id: i64) -> bool {
        let row = sqlx::query_scalar::<_, Option<i64>>(
            "SELECT user_id FROM devices WHERE device_id = $1",
        )
        .bind(device_id)
        .fetch_optional(pool)
        .await;

        match row {
            Ok(Some(Some(uid))) => uid == user_id,
            _ => false,
        }
    }

    /// Retrieve all recorded devices with network metadata and watch history.
    ///
    /// Phase 2 scoping: an admin sees every device and every history row; a
    /// signed-in caller sees the devices they own (`devices.user_id`) plus the
    /// device they are using right now (which may not be claimed yet); an
    /// anonymous caller sees only the device it is using. The filter is in SQL
    /// below, because filtering in memory after reading every row is the same
    /// query cost for a list that is always small but the wrong guarantee:
    /// rows the caller may not see would still have been read.
    pub async fn get_all_devices(
        pool: &PgPool,
        current_device_id: Option<&str>,
        caller_user_id: Option<i64>,
        is_admin: bool,
        _cache_dir: &Path,
        _roots: &[PathBuf],
    ) -> Result<(Vec<DeviceDetail>, DeviceStats), AppError> {
        let current = current_device_id.unwrap_or("");
        let dev_rows = sqlx::query(
            r#"
            SELECT
                device_id,
                custom_name,
                device_name,
                device_type,
                device_os,
                browser,
                user_agent,
                connection_type,
                client_ip,
                public_ip,
                mac_address,
                isp,
                city,
                country,
                first_seen,
                last_seen,
                device_model,
                user_id,
                u.id    AS owner_id,
                u.email AS owner_email,
                u.name  AS owner_name,
                u.role  AS owner_role
            FROM devices
            LEFT JOIN users u ON u.id = devices.user_id
            WHERE $1::boolean
               OR (CASE WHEN $2::bigint IS NOT NULL
                        THEN (user_id = $2 OR device_id = $3)
                        ELSE device_id = $3 END)
            ORDER BY last_seen DESC
            "#,
        )
        .bind(is_admin)
        .bind(caller_user_id)
        .bind(current)
        .fetch_all(pool)
        .await?;

        // History follows the *owning* device set, not merely the listed set.
        // A caller may read history for devices they own and for unowned
        // devices (a guest device before anyone signs in). A device owned by
        // somebody else may still be listed when it is the caller's current
        // device - they are physically using it - but its watch history is not
        // theirs to read.
        let device_ids: Vec<String> = dev_rows
            .iter()
            .filter(|d| {
                let owner: Option<i64> = d.try_get("user_id").ok().flatten();
                match owner {
                    None => true,
                    Some(uid) => Some(uid) == caller_user_id,
                }
            })
            .filter_map(|d| d.try_get::<String, _>("device_id").ok())
            .collect();

        let hist_rows = if is_admin {
            sqlx::query(
                r#"
                SELECT
                    h.device_id,
                    h.filename,
                    h.position::double precision as position,
                    h.duration::double precision as duration,
                    h.completed,
                    h.last_watched,
                    m.title,
                    m.year,
                    m.tmdb_id::BIGINT as tmdb_id,
                    m.poster_path
                FROM device_watch_history h
                LEFT JOIN movies m ON h.filename = m.filename
                ORDER BY h.last_watched DESC
                "#,
            )
            .fetch_all(pool)
            .await?
        } else {
            sqlx::query(
                r#"
                SELECT
                    h.device_id,
                    h.filename,
                    h.position::double precision as position,
                    h.duration::double precision as duration,
                    h.completed,
                    h.last_watched,
                    m.title,
                    m.year,
                    m.tmdb_id::BIGINT as tmdb_id,
                    m.poster_path
                FROM device_watch_history h
                LEFT JOIN movies m ON h.filename = m.filename
                WHERE h.device_id = ANY($1)
                ORDER BY h.last_watched DESC
                "#,
            )
            .bind(&device_ids)
            .fetch_all(pool)
            .await?
        };

        let now = Utc::now();
        let mut history_map: HashMap<String, Vec<WatchHistoryItem>> = HashMap::new();

        for h in hist_rows {
            let dev_id: String = h.try_get("device_id").unwrap_or_default();
            let fname: String = h.try_get("filename").unwrap_or_default();
            let pos: f64 = h.try_get("position").unwrap_or(0.0);
            let dur: f64 = h.try_get("duration").unwrap_or(0.0);
            let completed: bool = h
                .try_get::<bool, _>("completed")
                .or_else(|_| h.try_get::<i32, _>("completed").map(|c| c != 0))
                .unwrap_or(false);
            let last_watched_dt: Option<DateTime<Utc>> = h.try_get("last_watched").ok();
            let tmdb_id: Option<i64> = h
                .try_get::<Option<i64>, _>("tmdb_id")
                .ok()
                .flatten()
                .or_else(|| {
                    h.try_get::<Option<i32>, _>("tmdb_id")
                        .ok()
                        .flatten()
                        .map(|i| i as i64)
                });
            let m_title: Option<String> = h.try_get("title").ok();
            let m_year: Option<i32> = h.try_get("year").ok();

            let title = m_title.filter(|t| !t.trim().is_empty()).unwrap_or_else(|| {
                Path::new(&fname)
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or(&fname)
                    .to_string()
            });

            let year_val = match m_year {
                Some(y) => serde_json::json!(y),
                None => serde_json::json!(""),
            };

            let pct = if dur > 0.0 {
                ((pos / dur * 100.0 * 10.0).round() / 10.0).min(100.0)
            } else {
                0.0
            };

            let last_watched_str = last_watched_dt.map(format_db_timestamp).unwrap_or_default();
            let last_watched_ago = last_watched_dt
                .map(|dt| format_time_ago(dt, now))
                .unwrap_or_else(|| "Unknown".to_string());

            let m_poster: Option<String> = h.try_get("poster_path").ok().flatten();
            let poster_url = if let Some(id) = tmdb_id.filter(|&id| id > 0) {
                Some(format!("/tmdb-poster/{}", id))
            } else if m_poster.is_some() {
                Some(format!("/poster/{}", fname))
            } else {
                None
            };

            let item = WatchHistoryItem {
                filename: fname,
                title,
                year: year_val,
                position: pos,
                duration: dur,
                position_str: format_clock_time(pos),
                duration_str: format_clock_time(dur),
                percent: pct,
                completed,
                last_watched: last_watched_str,
                last_watched_ago,
                poster_url,
            };

            history_map.entry(dev_id).or_default().push(item);
        }

        let mut devices = Vec::new();

        for d in dev_rows {
            let dev_id: String = d.try_get("device_id").unwrap_or_default();
            let custom_name: Option<String> = d.try_get("custom_name").ok().flatten();
            let device_name: Option<String> = d.try_get("device_name").ok().flatten();
            let device_model: Option<String> = d.try_get("device_model").ok().flatten();
            let device_type: Option<String> = d.try_get("device_type").ok().flatten();
            let device_os: Option<String> = d.try_get("device_os").ok().flatten();
            let browser: Option<String> = d.try_get("browser").ok().flatten();
            let user_agent: Option<String> = d.try_get("user_agent").ok().flatten();
            let connection_type: Option<String> = d.try_get("connection_type").ok().flatten();
            let client_ip: Option<String> = d.try_get("client_ip").ok().flatten();
            let public_ip: Option<String> = d.try_get("public_ip").ok().flatten();
            let mac_address: Option<String> = d.try_get("mac_address").ok().flatten();
            let isp: Option<String> = d.try_get("isp").ok().flatten();
            let city: Option<String> = d.try_get("city").ok().flatten();
            let country: Option<String> = d.try_get("country").ok().flatten();

            // Attribution is admin-only. The LEFT JOIN gives every row owner
            // columns, but they are discarded for non-admin callers, so a
            // viewer's payload never carries another account's email.
            let owner = if is_admin {
                let owner_id: Option<i64> = d.try_get("owner_id").ok().flatten();
                let owner_email: Option<String> = d.try_get("owner_email").ok().flatten();
                match (owner_id, owner_email) {
                    (Some(id), Some(email)) => Some(DeviceOwner {
                        id,
                        email,
                        name: d.try_get("owner_name").ok().flatten(),
                        role: d
                            .try_get("owner_role")
                            .unwrap_or_else(|_| "viewer".to_string()),
                    }),
                    _ => None,
                }
            } else {
                None
            };

            let first_seen_dt: Option<DateTime<Utc>> = d.try_get("first_seen").ok();
            let last_seen_dt: Option<DateTime<Utc>> = d.try_get("last_seen").ok();

            let first_seen_str = first_seen_dt.map(format_db_timestamp).unwrap_or_default();
            let last_seen_str = last_seen_dt.map(format_db_timestamp).unwrap_or_default();
            let last_seen_ago = last_seen_dt
                .map(|dt| format_time_ago(dt, now))
                .unwrap_or_else(|| "Unknown".to_string());

            let is_active = last_seen_dt
                .map(|dt| (now - dt).num_seconds().max(0) <= 180)
                .unwrap_or(false);

            let is_current = current_device_id.map(|cid| cid == dev_id).unwrap_or(false);

            let display_name = custom_name
                .as_deref()
                .filter(|s| !s.trim().is_empty())
                .or_else(|| device_name.as_deref().filter(|s| !s.trim().is_empty()))
                .unwrap_or("Unknown Device")
                .to_string();

            let icon = device_icon(device_type.as_deref()).to_string();

            let watch_history = history_map.remove(&dev_id).unwrap_or_default();
            let recent_watch = watch_history.first().cloned();
            let total_watched = watch_history.len();

            devices.push(DeviceDetail {
                device_id: dev_id,
                custom_name,
                device_name,
                device_model,
                display_name,
                device_type,
                device_icon: icon,
                device_os,
                browser,
                user_agent,
                connection_type,
                client_ip,
                public_ip,
                mac_address,
                isp,
                city,
                country,
                first_seen: first_seen_str,
                last_seen: last_seen_str,
                last_seen_ago,
                is_active,
                is_current,
                recent_watch,
                watch_history,
                total_watched,
                owner,
            });
        }

        // Scoping already happened in SQL above: an admin sees every device,
        // a signed-in user sees the devices they own plus the one they are
        // using, and an anonymous caller sees only the device it is using.
        // Do not re-filter on `is_current` here - that would hide a signed-in
        // user's other devices, which is the whole point of Phase 2.

        let total_devices = devices.len();
        let active_now = devices.iter().filter(|d| d.is_active).count();
        let offline_count = total_devices.saturating_sub(active_now);
        let cloudflare_count = devices
            .iter()
            .filter(|d| {
                d.connection_type
                    .as_deref()
                    .unwrap_or("")
                    .contains("Cloudflare")
            })
            .count();
        let lan_count = devices
            .iter()
            .filter(|d| d.connection_type.as_deref().unwrap_or("").contains("LAN"))
            .count();
        let localhost_count = devices
            .iter()
            .filter(|d| {
                d.connection_type
                    .as_deref()
                    .unwrap_or("")
                    .contains("Localhost")
            })
            .count();

        let stats = DeviceStats {
            total_devices,
            active_now,
            offline_count,
            cloudflare_count,
            lan_count,
            localhost_count,
        };

        Ok((devices, stats))
    }

    /// Update custom friendly name for a device.
    pub async fn rename_device(
        pool: &PgPool,
        device_id: &str,
        new_name: Option<&str>,
    ) -> Result<(), AppError> {
        let clean = new_name.map(|n| n.trim()).filter(|n| !n.is_empty());
        sqlx::query("UPDATE devices SET custom_name = $1 WHERE device_id = $2")
            .bind(clean)
            .bind(device_id)
            .execute(pool)
            .await?;
        Ok(())
    }

    /// Permanently delete a device and its recorded watch history.
    pub async fn delete_device(pool: &PgPool, device_id: &str) -> Result<(), AppError> {
        let mut tx = pool.begin().await?;
        sqlx::query("DELETE FROM device_watch_history WHERE device_id = $1")
            .bind(device_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM devices WHERE device_id = $1")
            .bind(device_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WatchHistoryItem {
    pub filename: String,
    pub title: String,
    pub year: Value,
    pub position: f64,
    pub duration: f64,
    pub position_str: String,
    pub duration_str: String,
    pub percent: f64,
    pub completed: bool,
    pub last_watched: String,
    pub last_watched_ago: String,
    pub poster_url: Option<String>,
}

/// The account a device belongs to. Serialized on `DeviceDetail` **only for
/// admin callers**: a viewer must never receive another account's address, so
/// the mapping leaves `owner` as `None` for every non-admin response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceOwner {
    pub id: i64,
    pub email: String,
    pub name: Option<String>,
    pub role: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceDetail {
    pub device_id: String,
    pub custom_name: Option<String>,
    pub device_name: Option<String>,
    pub device_model: Option<String>,
    pub display_name: String,
    pub device_type: Option<String>,
    pub device_icon: String,
    pub device_os: Option<String>,
    pub browser: Option<String>,
    pub user_agent: Option<String>,
    pub connection_type: Option<String>,
    pub client_ip: Option<String>,
    pub public_ip: Option<String>,
    pub mac_address: Option<String>,
    pub isp: Option<String>,
    pub city: Option<String>,
    pub country: Option<String>,
    pub first_seen: String,
    pub last_seen: String,
    pub last_seen_ago: String,
    pub is_active: bool,
    pub is_current: bool,
    pub recent_watch: Option<WatchHistoryItem>,
    pub watch_history: Vec<WatchHistoryItem>,
    pub total_watched: usize,
    /// Present only when an admin is asking; `None` means unowned **or** the
    /// caller is not an admin (the two are indistinguishable on purpose).
    pub owner: Option<DeviceOwner>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceStats {
    pub total_devices: usize,
    pub active_now: usize,
    pub offline_count: usize,
    pub cloudflare_count: usize,
    pub lan_count: usize,
    pub localhost_count: usize,
}

pub fn format_clock_time(seconds: f64) -> String {
    let s = seconds.round() as i64;
    let h = s / 3600;
    let m = (s % 3600) / 60;
    let sec = s % 60;
    if h > 0 {
        format!("{}:{:02}:{:02}", h, m, sec)
    } else {
        format!("{:02}:{:02}", m, sec)
    }
}

pub fn format_db_timestamp(dt: DateTime<Utc>) -> String {
    dt.format("%Y-%m-%d %H:%M:%S").to_string()
}

pub fn format_time_ago(dt: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let diff = (now - dt).num_seconds().max(0);
    if diff < 60 {
        "Just now".to_string()
    } else if diff < 3600 {
        format!("{}m ago", diff / 60)
    } else if diff < 86400 {
        format!("{}h ago", diff / 3600)
    } else {
        format!("{}d ago", diff / 86400)
    }
}

pub fn device_icon(device_type: Option<&str>) -> &'static str {
    match device_type {
        Some("Mobile") => "📱",
        Some("Tablet") => "📟",
        Some("Smart TV") => "📺",
        Some("Console") => "🎮",
        Some("Tool/Bot") => "🤖",
        _ => "💻",
    }
}

/// Request facts gathered once, so several calls do not re-derive them.
pub struct RequestFacts {
    pub user_agent: String,
    pub hints: ClientHints,
    pub conn: ConnectionInfo,
}

fn is_iqoo_code(upper: &str) -> bool {
    upper.len() == 5 && upper.starts_with('I') && upper[1..].chars().all(|c| c.is_ascii_digit())
}

fn is_vivo_code(upper: &str) -> bool {
    // ^V\d{4}[A-Z]?$
    if !upper.starts_with('V') || upper.len() < 5 {
        return false;
    }
    if !upper[1..5].chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    upper.len() == 5 || (upper.len() == 6 && upper[5..].chars().all(|c| c.is_ascii_uppercase()))
}

fn is_xiaomi_code(upper: &str) -> bool {
    // ^(2[1-5]\d{2}|M2\d{3})
    if let Some(rest) = upper.strip_prefix('M') {
        return rest.len() >= 4
            && rest.starts_with('2')
            && rest[1..4].chars().all(|c| c.is_ascii_digit());
    }
    upper.len() >= 4
        && (upper.starts_with("21")
            || upper.starts_with("22")
            || upper.starts_with("23")
            || upper.starts_with("24")
            || upper.starts_with("25"))
        && upper[..4].chars().all(|c| c.is_ascii_digit())
}

/// Segment immediately before `marker`, delimited by the previous `;`.
///
/// Python uses `;\s*([^;]+?)\s+Build/` - the capture stops at the first
/// `;`, so it yields only the last segment. A naive "text between the first
/// '; ' and the marker" is greedy across segments and yields
/// `"Android 13; SM-A536E"` instead of `"SM-A536E"`, which then fails every
/// make/model match and collapses to "Generic Client".
fn segment_before(s: &str, marker: &str) -> Option<String> {
    let idx = s.find(marker)?;
    let head = &s[..idx];
    let after_last_sep = match head.rfind(';') {
        Some(p) => &head[p + 1..],
        None => head,
    };
    let value = after_last_sep.trim();
    if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}

fn after(s: &str, marker: &str) -> Option<String> {
    let idx = s.find(marker)?;
    let rest = &s[idx + marker.len()..];
    let end = rest
        .find(|c: char| !(c.is_ascii_digit() || c == '.'))
        .unwrap_or(rest.len());
    if end == 0 {
        return None;
    }
    Some(rest[..end].to_string())
}

fn major_of(version: &str) -> String {
    version.split('.').next().unwrap_or(version).to_string()
}

fn capture_version(ua: &str, marker: &str) -> Option<String> {
    let rest = ua[ua.find(marker)? + marker.len()..].trim_start();
    let end = rest
        .find(|c: char| !(c.is_ascii_digit() || c == '.'))
        .unwrap_or(rest.len());
    if end == 0 {
        None
    } else {
        Some(rest[..end].to_string())
    }
}

fn capture_digits(ua: &str, marker: &str) -> Option<String> {
    let rest = ua[ua.find(marker)? + marker.len()..].trim_start();
    let end = rest
        .find(|c: char| !(c.is_ascii_digit() || c == '_'))
        .unwrap_or(rest.len());
    if end == 0 {
        None
    } else {
        Some(rest[..end].to_string())
    }
}

fn format_optional(prefix: &str, value: Option<String>) -> String {
    match value {
        Some(v) if !v.is_empty() => format!("{} {}", prefix, v),
        _ => prefix.to_string(),
    }
}

/// RFC 1918 / loopback, mirroring Python's `ipaddress.is_private`.
pub fn is_private_ip(ip: &str) -> bool {
    if ip.is_empty() {
        return false;
    }
    if ip == "::1" || ip.starts_with("fe80") || ip.starts_with("fc") || ip.starts_with("fd") {
        return true;
    }
    let parts: Vec<&str> = ip.split('.').collect();
    if parts.len() != 4 {
        return false;
    }
    let mut octets = [0u8; 4];
    for (i, p) in parts.iter().enumerate() {
        match p.parse::<u8>() {
            Ok(v) => octets[i] = v,
            Err(_) => return false,
        }
    }
    match octets[0] {
        10 => true,
        127 => true,
        172 => (16..32).contains(&octets[1]),
        192 => octets[1] == 168,
        169 => octets[1] == 254,
        _ => false,
    }
}

/// Unused placeholder kept so the HashMap import stays meaningful if the
/// iQOO table is ever converted to a map.
#[allow(dead_code)]
type ModelMap = HashMap<&'static str, &'static str>;

#[cfg(test)]
mod tests {
    use super::*;

    /// Golden values, not shape.
    ///
    /// The previous version of this test asserted only prefix, length and
    /// self-determinism, so it passed while the formula diverged from
    /// Python's - the name claimed a parity it never checked. These
    /// expectations were captured from the **live Flask engine** (7/7
    /// matches) rather than computed here, so a change in Rust's formula
    /// has something real to fail against.
    #[test]
    fn deterministic_id_matches_python_golden_values() {
        let ip = "127.0.0.1";
        let cases = [
            ("", "dev_b07a760ab58004d3"),
            ("curl/8.4.0", "dev_89347728f7dbc8c0"),
            (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0 Safari/537.36",
                "dev_5aa1b96cb7cc327a",
            ),
            (
                "Mozilla/5.0 (Linux; Android 13; SM-A536E Build/TP1A) AppleWebKit/537.36 Mobile Safari/537.36",
                "dev_de0546457a544552",
            ),
            // Latin-1: the byte 0xE9 is what caught the to_str() defect.
            ("caf\u{e9}-tracker/1.0", "dev_a56184dae5b75123"),
        ];
        for (ua, want) in cases {
            let (got, is_new) = DeviceService::get_or_create_device_id(None, None, ip, ua);
            assert!(is_new);
            assert_eq!(got, want, "ua={:?}", ua);
            assert_eq!(got.len(), 20, "dev_ plus 16 hex characters");
        }
    }

    #[test]
    fn different_agents_and_addresses_hash_differently() {
        let base =
            DeviceService::get_or_create_device_id(None, None, "192.168.1.5", "Mozilla/5.0 (X11)");
        let again =
            DeviceService::get_or_create_device_id(None, None, "192.168.1.5", "Mozilla/5.0 (X11)");
        let other_ua =
            DeviceService::get_or_create_device_id(None, None, "192.168.1.5", "curl/8.0");
        let other_ip =
            DeviceService::get_or_create_device_id(None, None, "192.168.1.6", "Mozilla/5.0 (X11)");
        assert_eq!(base.0, again.0, "deterministic");
        assert_ne!(base.0, other_ua.0, "UA participates in the hash");
        assert_ne!(base.0, other_ip.0, "client IP participates in the hash");
    }

    #[test]
    fn explicit_cookie_and_header_win_over_the_hash() {
        let (id, is_new) =
            DeviceService::get_or_create_device_id(Some("dev_abc"), None, "1.2.3.4", "ua");
        assert_eq!(id, "dev_abc");
        assert!(!is_new);

        let (id, _) =
            DeviceService::get_or_create_device_id(Some("bogus"), Some("dev_hdr"), "1.2.3.4", "ua");
        assert_eq!(id, "dev_hdr", "a non-dev_ cookie must be ignored");
    }

    #[test]
    fn windows_and_lan_are_classified_from_headers() {
        let cf = DeviceService::classify_connection(
            Some("1.2.3.4"),
            None,
            "media.anisparvez.in",
            None,
            "127.0.0.1",
        );
        assert!(cf.is_cloudflare);
        assert_eq!(cf.connection_type, "Internet (Cloudflare Tunnel)");
        assert_eq!(cf.client_ip, "1.2.3.4");

        let loopback =
            DeviceService::classify_connection(None, None, "localhost:8000", None, "127.0.0.1");
        assert_eq!(loopback.connection_type, "Localhost (127.0.0.1)");

        let lan =
            DeviceService::classify_connection(None, None, "192.168.1.9:8000", None, "192.168.1.9");
        assert_eq!(lan.connection_type, "Local Network (LAN)");

        let direct =
            DeviceService::classify_connection(None, None, "example:8000", None, "8.8.8.8");
        assert_eq!(direct.connection_type, "Internet (Direct)");
    }

    #[test]
    fn mac_labels_match_the_deployed_windows_behaviour() {
        assert_eq!(
            DeviceService::resolve_mac_address("127.0.0.1", "Localhost (127.0.0.1)"),
            "Local Loopback (lo)"
        );
        assert_eq!(
            DeviceService::resolve_mac_address("1.2.3.4", "Internet (Cloudflare Tunnel)"),
            "WAN Proxy (Not L2 routable)"
        );
        assert_eq!(
            DeviceService::resolve_mac_address("192.168.1.5", "Local Network (LAN)"),
            "LAN (ARP Pending)",
            "on Windows /proc/net/arp does not exist, which is what Flask already returns"
        );
    }

    #[test]
    fn private_ip_detection() {
        for ip in [
            "192.168.1.5",
            "10.0.0.1",
            "172.16.0.1",
            "127.0.0.1",
            "169.254.1.1",
        ] {
            assert!(is_private_ip(ip), "{} should be private", ip);
        }
        for ip in ["8.8.8.8", "1.1.1.1", "172.32.0.1"] {
            assert!(!is_private_ip(ip), "{} should be public", ip);
        }
    }

    #[test]
    fn smart_tv_and_console_branches() {
        let ch = ClientHints::default();
        let tizen = DeviceService::parse_user_agent(
            "Mozilla/5.0 (SMART-TV; LINUX; Tizen 6.0) AppleWebKit/537.36",
            &ch,
        );
        assert_eq!(tizen.device_type, "Smart TV");
        assert_eq!(tizen.device_os, "Tizen OS 6.0");

        let xbox = DeviceService::parse_user_agent(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64; Xbox; Xbox One)",
            &ch,
        );
        assert_eq!(xbox.device_type, "Console");
        assert_eq!(xbox.device_os, "Xbox OS");
    }

    #[test]
    fn android_phone_versus_tablet() {
        let ch = ClientHints::default();
        let phone = DeviceService::parse_user_agent(
            "Mozilla/5.0 (Linux; Android 13; SM-A536E Build/TP1A) AppleWebKit/537.36 Mobile Safari/537.36",
            &ch,
        );
        assert_eq!(phone.device_type, "Mobile");
        assert_eq!(phone.device_os, "Android 13");
        assert_eq!(phone.device_name, "Samsung Galaxy A");

        let tablet = DeviceService::parse_user_agent(
            "Mozilla/5.0 (Linux; Android 13; SM-X710) AppleWebKit/537.36 Safari/537.36",
            &ch,
        );
        assert_eq!(tablet.device_type, "Tablet");
        assert_eq!(tablet.device_name, "Android Tablet");
    }

    #[test]
    fn windows_client_hints_refine_the_version() {
        let ch = ClientHints {
            platform: Some("\"Windows\"".into()),
            platform_version: Some("\"15.0.0\"".into()),
            ..Default::default()
        };
        let os = DeviceService::resolve_device_os("Windows NT 10.0", "\"Windows\"", "\"15.0.0\"");
        assert_eq!(os, "Windows 11");
        let _ = ch;
    }

    #[test]
    fn tool_clients_are_recognised() {
        let parsed = DeviceService::parse_user_agent("curl/8.4.0", &ClientHints::default());
        assert_eq!(parsed.device_type, "Tool/Bot");
        assert_eq!(parsed.browser, "curl");
    }
}
