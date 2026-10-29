//! Where a cast device fetches media from, and the guard on that choice.
//!
//! The URL handed to a TV is always `<origin>/media/<file>` with the file
//! validated locally, so the only freedom a client gets is **which host the TV
//! fetches**. That is an SSRF pivot if left unvalidated, so an explicit origin
//! is honoured only for private LAN addresses, loopback and the configured
//! public hostname.
//!
//! Two subtleties, both learned the hard way:
//!
//! * **Loopback is valid as a guard but useless as a target.** A device told to
//!   fetch from `127.0.0.1` fetches from itself, which is how a live cast died
//!   with UPnP 716. So loopback is *rejected* for the device even though it
//!   passes the private-host test.
//! * **A client that reached us over loopback cannot be used as the origin.**
//!   A browser on this machine asks for `http://127.0.0.1:8001/...`, and a TV
//!   cannot follow that. The LAN address is used instead.

/// RFC 1918 / loopback / link-local, for host strings.
pub fn is_private_host(host: &str) -> bool {
    let host = host.trim().trim_matches(['[', ']']).to_lowercase();
    if host == "localhost" {
        return true;
    }
    if let Ok(ip) = host.parse::<std::net::IpAddr>() {
        return match ip {
            std::net::IpAddr::V4(v4) => v4.is_private() || v4.is_loopback() || v4.is_link_local(),
            std::net::IpAddr::V6(v6) => {
                v6.is_loopback()
                    || (v6.segments()[0] & 0xfe00) == 0xfc00
                    || (v6.segments()[0] & 0xffc0) == 0xfe80
            }
        };
    }
    false
}

/// 127.0.0.0/8, localhost and IPv6 loopback: reachable only from this machine.
pub fn is_loopback_host(host: &str) -> bool {
    let cleaned = host.trim().to_lowercase();
    let cleaned = cleaned.trim_matches(['[', ']']);
    if cleaned == "localhost" || cleaned == "::1" || cleaned == "0.0.0.0" {
        return true;
    }
    cleaned.starts_with("127.")
}

struct ParsedOrigin {
    scheme: String,
    host: String,
    port: Option<u16>,
}

/// Accept an explicit cast origin only when it cannot be used as an SSRF pivot.
pub fn validate_origin(origin: &str, public_host: Option<&str>) -> Option<String> {
    let origin = origin.trim();
    if origin.is_empty() {
        return None;
    }
    let (scheme, rest) = origin.split_once("://")?;
    if scheme != "http" && scheme != "https" {
        return None;
    }
    // A path, query or fragment means the caller is trying to aim the device
    // somewhere other than an origin.
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    if rest.contains('/') && !rest.trim_end_matches('/').is_empty() {
        let tail = rest.split_once('/').map(|(_, t)| t).unwrap_or("");
        if !tail.is_empty() {
            return None;
        }
    }
    if rest.contains('?') || rest.contains('#') {
        return None;
    }
    if authority.is_empty() {
        return None;
    }

    let (host, port) = match authority.rsplit_once(':') {
        Some((h, p)) if !h.is_empty() && p.chars().all(|c| c.is_ascii_digit()) && !p.is_empty() => {
            match p.parse::<u16>() {
                Ok(v) => (h.to_string(), Some(v)),
                Err(_) => return None,
            }
        }
        _ => (authority.to_string(), None),
    };
    let host = host.trim_matches(['[', ']']).to_string();

    let mut allowed = is_private_host(&host);
    if !allowed {
        if let Some(public) = public_host.filter(|p| !p.is_empty()) {
            allowed = public.eq_ignore_ascii_case(&host);
        }
    }
    if !allowed {
        return None;
    }

    let parsed = ParsedOrigin {
        scheme: scheme.to_string(),
        host,
        port,
    };
    Some(render(&parsed))
}

fn render(p: &ParsedOrigin) -> String {
    match p.port {
        Some(port) => format!("{}://{}:{}", p.scheme, p.host, port),
        None => format!("{}://{}", p.scheme, p.host),
    }
}

/// The origin a device should fetch media from.
///
/// `None` is the common, correct answer: a TV on the same network should always
/// fetch from the LAN address.
pub fn resolve_origin(
    origin: Option<&str>,
    request_base: Option<&str>,
    server_port: u16,
) -> Option<String> {
    let public_host = std::env::var("MEDIA_SERVER_PUBLIC_HOST").ok();

    if let Some(candidate) = origin.and_then(|o| validate_origin(o, public_host.as_deref())) {
        let host = candidate
            .split("://")
            .nth(1)
            .and_then(|rest| rest.split(':').next())
            .unwrap_or("");
        if is_loopback_host(host) {
            // Valid as a guard, useless as a target: a device told to fetch
            // from loopback fetches from itself.
            return None;
        }
        return Some(candidate);
    }

    if let Some(base) = request_base.filter(|b| !b.is_empty()) {
        let (scheme, rest) = base.split_once("://")?;
        let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
        let (host, port) = match authority.rsplit_once(':') {
            Some((h, p)) if p.chars().all(|c| c.is_ascii_digit()) && !p.is_empty() => {
                (h.to_string(), p.parse::<u16>().unwrap_or(server_port))
            }
            _ => (authority.to_string(), server_port),
        };
        let host = host.trim_matches(['[', ']']).to_string();
        if host.is_empty() {
            return None;
        }
        if is_loopback_host(&host) {
            // The client reached us over loopback; the device cannot follow it.
            return None;
        }
        if is_private_host(&host) {
            return Some(render(&ParsedOrigin {
                scheme: scheme.to_string(),
                host,
                port: Some(port),
            }));
        }
    }
    None
}

/// URL for a device to fetch.
pub fn build_media_url(rel_path: &str, origin: Option<&str>, hls: bool) -> String {
    let public_host = std::env::var("MEDIA_SERVER_PUBLIC_HOST").ok();
    let base = origin
        .and_then(|o| validate_origin(o, public_host.as_deref()))
        .unwrap_or_else(|| {
            format!(
                "http://{}:{}",
                crate::services::dlna_service::lan_ip(),
                std::env::var("RUST_PORT")
                    .ok()
                    .and_then(|p| p.parse().ok())
                    .unwrap_or(8000u16)
            )
        });
    let encoded = percent_encode_path(rel_path);
    if hls {
        format!("{}/hls/{}/playlist.m3u8", base, encoded)
    } else {
        format!("{}/media/{}", base, encoded)
    }
}

/// `urllib.parse.quote` with the default safe set, which leaves `/` alone so
/// subdirectory structure survives.
fn percent_encode_path(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    for byte in path.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{:02X}", byte)),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn private_and_public_hosts_are_distinguished() {
        assert!(is_private_host("192.168.1.8"));
        assert!(is_private_host("10.0.0.5"));
        assert!(is_private_host("127.0.0.1"));
        assert!(is_private_host("localhost"));
        assert!(!is_private_host("8.8.8.8"));
        assert!(!is_private_host("media.anisparvez.in"));
    }

    #[test]
    fn loopback_is_recognised_separately() {
        assert!(is_loopback_host("127.0.0.1"));
        assert!(is_loopback_host("127.1.2.3"));
        assert!(is_loopback_host("localhost"));
        assert!(is_loopback_host("::1"));
        assert!(!is_loopback_host("192.168.1.8"));
    }

    #[test]
    fn a_public_origin_is_refused() {
        assert_eq!(validate_origin("http://evil.example", None), None);
        assert_eq!(validate_origin("http://8.8.8.8:8000", None), None);
    }

    #[test]
    fn a_private_origin_is_accepted_with_its_port() {
        assert_eq!(
            validate_origin("http://192.168.1.5:9000", None).as_deref(),
            Some("http://192.168.1.5:9000")
        );
        assert_eq!(
            validate_origin("http://192.168.1.5", None).as_deref(),
            Some("http://192.168.1.5")
        );
    }

    #[test]
    fn the_configured_public_hostname_is_allowed() {
        assert_eq!(
            validate_origin("https://media.anisparvez.in", Some("media.anisparvez.in")).as_deref(),
            Some("https://media.anisparvez.in")
        );
        assert_eq!(
            validate_origin("https://other.example", Some("media.anisparvez.in")),
            None,
            "the allowlist is exactly one host, not a suffix"
        );
    }

    #[test]
    fn a_non_origin_url_is_refused() {
        assert_eq!(
            validate_origin("http://192.168.1.5/media/secret.mkv", None),
            None
        );
        assert_eq!(validate_origin("http://192.168.1.5/?a=b", None), None);
        assert_eq!(validate_origin("ftp://192.168.1.5", None), None);
        assert_eq!(validate_origin("not a url", None), None);
        assert_eq!(validate_origin("", None), None);
    }

    #[test]
    fn a_loopback_origin_falls_back_to_the_lan_address() {
        // Valid as a guard, useless as a target: the device would fetch itself.
        assert_eq!(
            resolve_origin(Some("http://127.0.0.1:8000"), None, 8000),
            None
        );
    }

    #[test]
    fn a_loopback_request_base_is_not_handed_to_the_device() {
        assert_eq!(
            resolve_origin(None, Some("http://127.0.0.1:8001/"), 8000),
            None,
            "a browser on this machine must not aim the TV at loopback"
        );
    }

    #[test]
    fn a_private_request_base_is_used() {
        assert_eq!(
            resolve_origin(None, Some("http://192.168.1.2:8000/"), 8000).as_deref(),
            Some("http://192.168.1.2:8000")
        );
    }

    #[test]
    fn media_urls_quote_the_path_but_keep_separators() {
        assert_eq!(
            build_media_url(
                "2001 A Space Odyssey (1968).mkv",
                Some("http://192.168.1.2:8000"),
                false
            ),
            "http://192.168.1.2:8000/media/2001%20A%20Space%20Odyssey%20%281968%29.mkv"
        );
        assert_eq!(
            build_media_url("sub/dir/file.mkv", Some("http://192.168.1.2:8000"), true),
            "http://192.168.1.2:8000/hls/sub/dir/file.mkv/playlist.m3u8"
        );
    }

    #[test]
    fn an_invalid_origin_is_replaced_by_the_lan_address() {
        let url = build_media_url("x.mkv", Some("http://evil.example"), false);
        assert!(url.starts_with("http://"), "{}", url);
        assert!(!url.contains("evil.example"));
    }
}
