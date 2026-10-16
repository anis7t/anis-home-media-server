//! Phase C4a: DLNA/UPnP discovery and control, native.
//!
//! A DLNA renderer decides whether its own FF/prev buttons work *before*
//! playback, from the fourth `protocolInfo` field and the
//! `contentFeatures.dlna.org` header it reads off the media response. Sending
//! `*` there means "no DLNA operations" and the Samsung DU7000 greys those
//! buttons out even though byte-range serving works. `DLNA_CONTENT_FEATURES` is
//! therefore the single source of truth for both, and is duplicated verbatim in
//! the media route's response headers - the two must never drift.

use quick_xml::events::Event;
use quick_xml::Reader;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr, UdpSocket};
use std::path::Path;
use std::time::{Duration, SystemTime};

pub const SSDP_ADDR: &str = "239.255.255.250";
pub const SSDP_PORT: u16 = 1900;
pub const MEDIA_RENDERER_ST: &str = "urn:schemas-upnp-org:device:MediaRenderer:1";
pub const AVTRANSPORT_ST: &str = "urn:schemas-upnp-org:service:AVTransport:1";
pub const RENDERING_ST: &str = "urn:schemas-upnp-org:service:RenderingControl:1";

/// The 4th `protocolInfo` field and the `contentFeatures.dlna.org` body.
/// `DLNA.ORG_OP=01` advertises byte-range seek; the flags mark the stream as
/// time-based and seekable; `DLNA.ORG_CI=0` means sent as-is, not converted.
/// This is the minidlna value.
pub const DLNA_CONTENT_FEATURES: &str =
    "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000";

/// UPnP faults worth explaining rather than echoing as "HTTP 500".
pub fn upnp_fault(code: &str) -> Option<&'static str> {
    match code {
        "701" => Some("The device refused that in its current state - nothing loaded, or it cannot do that."),
        "702" => Some("The device refused to play that in its current state."),
        "710" => Some("The device is busy - try again in a moment."),
        "711" => Some("The device rejected that position."),
        "716" => Some("The device is not playing yet - start playback first."),
        _ => None,
    }
}

/// A discovered renderer.
///
/// `Deserialize` as well as `Serialize`: the registry keeps devices as JSON and
/// round-trips them back into this type to issue control calls.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DlnaDevice {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub model: String,
    pub host: String,
    pub control_url: String,
    #[serde(rename = "rendering_control_url")]
    pub rendering_control_url: Option<String>,
    pub location: String,
}

/// Transport state as the players consume it.
#[derive(Debug, Clone, Serialize)]
pub struct DlnaStatus {
    pub state: String,
    pub position: f64,
    pub duration: f64,
    pub volume: f64,
    pub muted: bool,
}

/// Failure text. Our own messages already read as sentences, and upstream
/// faults are already translated in [`upnp_fault`], so there is no class-name
/// prefix to add.
pub type DlnaResult<T> = Result<T, String>;

// ------------------------------------------------------------------ XML helpers

fn local_name(raw: &[u8]) -> String {
    let s = String::from_utf8_lossy(raw);
    s.rsplit(['}', ':']).next().unwrap_or(&s).to_string()
}

/// Text of the first descendant element with this local name, namespaces
/// ignored - the UPnP responses all use default namespaces.
pub fn find_text(xml: &str, name: &str) -> Option<String> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut buf = Vec::new();
    let mut inside = false;
    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                if local_name(e.name().as_ref()) == name {
                    inside = true;
                }
            }
            Ok(Event::Empty(e)) => {
                if !inside && local_name(e.name().as_ref()) == name {
                    return Some(String::new());
                }
            }
            Ok(Event::Text(t)) => {
                if inside {
                    if let Ok(decoded) = t.unescape() {
                        if !decoded.trim().is_empty() {
                            return Some(decoded.trim().to_string());
                        }
                    }
                }
            }
            Ok(Event::CData(t)) => {
                if inside {
                    let decoded = String::from_utf8_lossy(t.as_ref()).to_string();
                    if !decoded.trim().is_empty() {
                        return Some(decoded.trim().to_string());
                    }
                }
            }
            Ok(Event::End(e)) => {
                if inside && local_name(e.name().as_ref()) == name {
                    return Some(String::new());
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
        buf.clear();
    }
    if inside {
        Some(String::new())
    } else {
        None
    }
}

fn escape_xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#x27;")
}

// ------------------------------------------------------------- time formatting

/// `H:MM:SS.mmm`, the form renderers print and parse.
pub fn dlna_duration(seconds: f64) -> String {
    let total = if seconds > 0.0 { seconds } else { 0.0 };
    let hours = (total / 3600.0).trunc();
    let remainder = total % 3600.0;
    let minutes = (remainder / 60.0).trunc();
    let secs = remainder % 60.0;
    format!("{}:{:02}:{:06.3}", hours as i64, minutes as i64, secs)
}

/// `HH:MM:SS`, the AVTransport `Target` format.
pub fn hhmmss(seconds: f64) -> String {
    let total = if seconds > 0.0 { seconds as i64 } else { 0 };
    format!("{:02}:{:02}:{:02}", total / 3600, (total % 3600) / 60, total % 60)
}

pub fn parse_hhmmss(value: Option<&str>) -> f64 {
    let raw = match value {
        Some(v) if !v.is_empty() => v,
        _ => return 0.0,
    };
    let mut parts: Vec<f64> = Vec::new();
    for p in raw.split(':') {
        match p.parse::<f64>() {
            Ok(v) => parts.push(v),
            Err(_) => return 0.0,
        }
    }
    while parts.len() < 3 {
        parts.insert(0, 0.0);
    }
    parts[0] * 3600.0 + parts[1] * 60.0 + parts[2]
}

pub fn map_state(raw: Option<&str>) -> String {
    let state = raw.unwrap_or("").to_uppercase();
    match state.as_str() {
        "PLAYING" | "PLAY" => return "playing".into(),
        "PAUSED_PLAYBACK" | "PAUSED" | "PAUSE" => return "paused".into(),
        "TRANSITIONING" | "BUFFERING" => return "buffering".into(),
        "STOPPED" | "NO_MEDIA_PRESENT" | "IDLE" => return "stopped".into(),
        _ => {}
    }
    if state.is_empty() {
        "unknown".into()
    } else {
        state.to_lowercase()
    }
}

/// DIDL-Lite payload; renderers show this title on screen.
///
/// `size` and `duration` are what a renderer reads to draw its scrub bar and
/// to decide the item is seekable, and the fourth `protocolInfo` field is what
/// enables the transport buttons. Both are best-effort: a missing value costs
/// the attribute, never the cast.
pub fn didl_metadata(
    title: &str,
    url: &str,
    content_type: &str,
    size: Option<u64>,
    duration: Option<f64>,
) -> String {
    let mut attributes = String::new();
    if let Some(s) = size.filter(|s| *s > 0) {
        attributes.push_str(&format!(" size=\"{}\"", s));
    }
    if let Some(d) = duration.filter(|d| *d > 0.0) {
        attributes.push_str(&format!(" duration=\"{}\"", dlna_duration(d)));
    }
    format!(
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" \
         xmlns:dc=\"http://purl.org/dc/elements/1.1/\" \
         xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">\
         <item id=\"0\" parentID=\"-1\" restricted=\"1\">\
         <dc:title>{}</dc:title>\
         <upnp:class>object.item.videoItem</upnp:class>\
         <res protocolInfo=\"http-get:*:{}:{}\"{}>{}</res>\
         </item></DIDL-Lite>",
        escape_xml(title),
        content_type,
        DLNA_CONTENT_FEATURES,
        attributes,
        escape_xml(url)
    )
}

// ------------------------------------------------------------------- SOAP calls

pub fn soap_envelope(service_type: &str, action: &str, args: &[(&str, String)]) -> String {
    let inner: String = args
        .iter()
        .map(|(k, v)| format!("<{}>{}</{}>", k, escape_xml(v), k))
        .collect();
    format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\
         <s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" \
         s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">\
         <s:Body><u:{action} xmlns:u=\"{service_type}\">{}</u:{action}></s:Body></s:Envelope>",
        inner
    )
}

/// One UPnP control call. Failures carry the translated UPnP fault, because a
/// raw "HTTP 500" tells neither the user nor the player anything actionable.
pub async fn soap_call(
    client: &reqwest::Client,
    control_url: &str,
    service_type: &str,
    action: &str,
    args: &[(&str, String)],
) -> DlnaResult<String> {
    let body = soap_envelope(service_type, action, args);
    let response = client
        .post(control_url)
        .header("Content-Type", "text/xml; charset=\"utf-8\"")
        .header("SOAPAction", format!("\"{}#{}\"", service_type, action))
        .body(body)
        .send()
        .await
        .map_err(|e| format!("{}", e))?;

    let status = response.status();
    let text = response.text().await.unwrap_or_default();
    if status.is_success() {
        return Ok(text);
    }

    let code = extract_tag(&text, "errorCode");
    let description = extract_tag(&text, "errorDescription");
    let detail = code
        .as_deref()
        .and_then(upnp_fault)
        .map(|s| s.to_string())
        .or(description)
        .unwrap_or_else(|| format!("HTTP {}", status.as_u16()));
    Err(match code {
        Some(c) => format!("{} (UPnP {})", detail, c),
        None => detail,
    })
}

fn extract_tag(xml: &str, tag: &str) -> Option<String> {
    let open = format!("<{}>", tag);
    let close = format!("</{}>", tag);
    let start = xml.find(&open)? + open.len();
    let rest = &xml[start..];
    let end = rest.find(&close)?;
    Some(rest[..end].trim().to_string())
}

fn client(timeout: Duration) -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(timeout)
        // A renderer that never answers must not hold the request open.
        .build()
        .unwrap_or_default()
}

// ------------------------------------------------------------------- interfaces

/// The address other devices on the LAN reach this server on.
pub fn lan_ip() -> String {
    if let Ok(sock) = UdpSocket::bind("0.0.0.0:0") {
        // Routing-table lookup only; UDP `connect` sends no packet.
        if sock.connect("8.8.8.8:80").is_ok() {
            if let Ok(addr) = sock.local_addr() {
                let ip = addr.ip();
                if !ip.is_unspecified() {
                    return ip.to_string();
                }
            }
        }
    }
    "127.0.0.1".to_string()
}

/// Usable IPv4 addresses to send SSDP from.
///
/// An unbound multicast socket follows the OS default route, which on a
/// dual-homed host can be the wrong adapter entirely - the search then never
/// reaches the device even though the device is on the network. One socket
/// per interface removes the guesswork.
fn multicast_interfaces() -> Vec<IpAddr> {
    let mut addresses: Vec<IpAddr> = if_addrs::get_if_addrs()
        .unwrap_or_default()
        .into_iter()
        .map(|i| i.addr.ip())
        .filter(|ip| {
            ip.is_ipv4() && !ip.is_loopback() && !ip.is_unspecified()
                // Link-local cannot carry SSDP replies usefully.
                && !ip.to_string().starts_with("169.254.")
        })
        .collect();
    if addresses.is_empty() {
        if let Ok(lan) = lan_ip().parse::<IpAddr>() {
            addresses.push(lan);
        }
    }
    addresses.sort();
    addresses.dedup();
    addresses
}

// ---------------------------------------------------------------- discovery

/// SSDP M-SEARCH for MediaRenderers from every interface, then read each
/// device description.
///
/// Two search targets and two passes per interface: SSDP is lossy, and some
/// renderers only answer the service type rather than the device type.
pub async fn discover(timeout: Duration) -> DlnaResult<Vec<DlnaDevice>> {
    let message = |st: &str| {
        format!(
            "M-SEARCH * HTTP/1.1\r\nHOST: {}:{}\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: {}\r\n\r\n",
            SSDP_ADDR, SSDP_PORT, st
        )
    };

    let mut sockets = Vec::new();
    for interface in multicast_interfaces() {
        match bind_ssdp(interface) {
            Ok(sock) => sockets.push(sock),
            Err(_) => continue,
        }
    }

    let mut locations: HashMap<String, String> = HashMap::new();
    if !sockets.is_empty() {
        let targets = format!("{}\\0{}", message(MEDIA_RENDERER_ST), message(AVTRANSPORT_ST));
        let deadline = tokio::time::Instant::now() + timeout;
        for sock in &sockets {
            for _ in 0..2 {
                let _ = sock.send_to(targets.as_bytes(), (SSDP_ADDR, SSDP_PORT));
            }
        }
        'listen: loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            for sock in &sockets {
                let mut buf = vec![0u8; 4096];
                match tokio::time::timeout(remaining.min(Duration::from_millis(500)), sock.recv_from(&mut buf)).await {
                    Ok(Ok((n, addr))) => {
                        let text = String::from_utf8_lossy(&buf[..n]).to_string();
                        for line in text.lines() {
                            if line.to_lowercase().starts_with("location:") {
                                locations
                                    .entry(addr.ip().to_string())
                                    .or_insert_with(|| line.splitn(2, ':').nth(1).unwrap_or("").trim().to_string());
                            }
                        }
                    }
                    Ok(Err(_)) => continue,
                    Err(_) => {
                        // One interface timed out; try the rest until the deadline.
                        if tokio::time::Instant::now() >= deadline {
                            break 'listen;
                        }
                    }
                }
            }
        }
    }

    let http = client(Duration::from_secs(4));
    let mut devices = Vec::new();
    for location in locations.values() {
        if let Some(d) = describe_device(&http, location).await {
            devices.push(d);
        }
    }
    Ok(devices)
}

fn bind_ssdp(interface: IpAddr) -> std::io::Result<tokio::net::UdpSocket> {
    let domain = match interface {
        IpAddr::V4(_) => socket2::Domain::IPV4,
        IpAddr::V6(_) => socket2::Domain::IPV6,
    };
    let sock = socket2::Socket::new(domain, socket2::Type::DGRAM, Some(socket2::Protocol::UDP))?;
    sock.set_reuse_address(true)?;
    sock.set_multicast_loop_v4(true)?;
    sock.set_multicast_ttl_v4(2)?;
    if let IpAddr::V4(v4) = interface {
        sock.set_multicast_if_v4(&v4)?;
    }
    sock.bind(&SocketAddr::new(interface, 0).into())?;
    // Tokio's UdpSocket requires a non-blocking socket, and must be registered
    // with the reactor - hence going through std rather than binding directly.
    sock.set_nonblocking(true)?;
    let std_sock: std::net::UdpSocket = sock.into();
    tokio::net::UdpSocket::from_std(std_sock)
}

/// Read a device description, keeping only real AVTransport renderers.
async fn describe_device(http: &reqwest::Client, location: &str) -> Option<DlnaDevice> {
    let body = http.get(location).send().await.ok()?.text().await.ok()?;

    let mut av_control = None;
    let mut rendering_control = None;
    for chunk in split_services(&body) {
        let service_type = find_text(&chunk, "serviceType").unwrap_or_default();
        let control = match find_text(&chunk, "controlURL") {
            Some(c) if !c.is_empty() => c,
            _ => continue,
        };
        if service_type.starts_with(AVTRANSPORT_ST) {
            av_control = Some(url_join(location, &control));
        } else if service_type.starts_with(RENDERING_ST) {
            rendering_control = Some(url_join(location, &control));
        }
    }
    let av_control = av_control?;

    let host = location
        .split("//")
        .nth(1)
        .and_then(|rest| rest.split('/').next())
        .and_then(|h| h.split(':').next())
        .unwrap_or("")
        .to_string();
    let udn = find_text(&body, "UDN").filter(|u| !u.is_empty()).unwrap_or_else(|| {
        if host.is_empty() { location.to_string() } else { host.clone() }
    });

    Some(DlnaDevice {
        id: format!("dlna:{}", udn),
        kind: "dlna".into(),
        name: find_text(&body, "friendlyName").filter(|n| !n.is_empty())
            .unwrap_or_else(|| "DLNA device".into()),
        model: find_text(&body, "modelName").unwrap_or_default(),
        host,
        control_url: av_control,
        rendering_control_url: rendering_control,
        location: location.to_string(),
    })
}

/// Each `<service>…</service>` block, so a service's own fields cannot leak
/// into the next one's.
fn split_services(xml: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = xml;
    while let Some(start) = rest.find("<service>") {
        let after = &rest[start + "<service>".len()..];
        match after.find("</service>") {
            Some(end) => {
                out.push(after[..end].to_string());
                rest = &after[end + "</service>".len()..];
            }
            None => break,
        }
    }
    out
}

/// `scheme://authority` of a URL, with the path discarded.
///
/// The `controlURL` in a device description is resolved against the
/// description's *origin*, not its document path - keeping `/dmr` in the base
/// produced `.../dmr/upnp/control/...`, which 404s.
fn origin_of(url: &str) -> String {
    match url.split_once("://") {
        Some((scheme, rest)) => {
            let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
            format!("{}://{}", scheme, authority)
        }
        None => url.trim_end_matches('/').to_string(),
    }
}

fn url_join(base: &str, path: &str) -> String {
    if path.starts_with("http://") || path.starts_with("https://") {
        return path.to_string();
    }
    let origin = origin_of(base);
    if path.starts_with('/') {
        format!("{}{}", origin, path)
    } else {
        format!("{}/{}", origin, path)
    }
}

// --------------------------------------------------------------------- control

/// Poll GetTransportInfo until the renderer leaves the stopped state.
pub async fn wait_for_transport(http: &reqwest::Client, device: &DlnaDevice, want: &str) -> String {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(8);
    let mut state = "unknown".to_string();
    loop {
        match soap_call(http, &device.control_url, AVTRANSPORT_ST, "GetTransportInfo", &[("InstanceID", "0".into())]).await {
            Ok(info) => state = map_state(find_text(&info, "CurrentTransportState").as_deref()),
            Err(_) => return state,
        }
        if state == want || (want == "playing" && state == "paused") {
            return state;
        }
        if tokio::time::Instant::now() >= deadline {
            return state;
        }
        tokio::time::sleep(Duration::from_millis(400)).await;
    }
}

pub async fn load(
    http: &reqwest::Client,
    device: &DlnaDevice,
    url: &str,
    title: &str,
    content_type: &str,
    position: Option<f64>,
    size: Option<u64>,
    duration: Option<f64>,
) -> DlnaResult<()> {
    soap_call(
        http,
        &device.control_url,
        AVTRANSPORT_ST,
        "SetAVTransportURI",
        &[
            ("InstanceID", "0".into()),
            ("CurrentURI", url.to_string()),
            (
                "CurrentURIMetaData",
                didl_metadata(title, url, content_type, size, duration),
            ),
        ],
    )
    .await?;
    soap_call(http, &device.control_url, AVTRANSPORT_ST, "Play", &[("InstanceID", "0".into()), ("Speed", "1".into())]).await?;

    if let Some(pos) = position.filter(|p| *p != 0.0) {
        // Seek only after the renderer has the media: a stopped Samsung answers
        // HTTP 500 to a premature Seek, which used to abort the entire load.
        wait_for_transport(http, device, "playing").await;
        soap_call(
            http,
            &device.control_url,
            AVTRANSPORT_ST,
            "Seek",
            &[("InstanceID", "0".into()), ("Unit", "REL_TIME".into()), ("Target", hhmmss(pos))],
        )
        .await?;
    }
    Ok(())
}

pub async fn command(http: &reqwest::Client, device: &DlnaDevice, action: &str, value: Option<f64>) -> DlnaResult<()> {
    let url = &device.control_url;
    match action {
        "play" => soap_call(http, url, AVTRANSPORT_ST, "Play", &[("InstanceID", "0".into()), ("Speed", "1".into())]).await.map(|_| ()),
        "pause" => soap_call(http, url, AVTRANSPORT_ST, "Pause", &[("InstanceID", "0".into())]).await.map(|_| ()),
        "stop" => soap_call(http, url, AVTRANSPORT_ST, "Stop", &[("InstanceID", "0".into())]).await.map(|_| ()),
        "seek" => {
            // A paused renderer ignores a seek and a stopped one errors, so start
            // playback first when needed - seeking is a request to watch from there.
            let state = match soap_call(http, url, AVTRANSPORT_ST, "GetTransportInfo", &[("InstanceID", "0".into())]).await {
                Ok(info) => map_state(find_text(&info, "CurrentTransportState").as_deref()),
                Err(_) => "unknown".into(),
            };
            if state != "playing" {
                soap_call(http, url, AVTRANSPORT_ST, "Play", &[("InstanceID", "0".into()), ("Speed", "1".into())]).await?;
                wait_for_transport(http, device, "playing").await;
            }
            match soap_call(
                http,
                url,
                AVTRANSPORT_ST,
                "Seek",
                &[
                    ("InstanceID", "0".into()),
                    ("Unit", "REL_TIME".into()),
                    ("Target", hhmmss(value.unwrap_or(0.0))),
                ],
            )
            .await
            {
                Ok(_) => Ok(()),
                Err(e) if e.contains("701") => Err(
                    "This device does not allow seeking from another app - use its own remote to \
                     jump ahead. (UPnP 701)"
                        .to_string(),
                ),
                Err(e) => Err(e),
            }
        }
        "volume" => {
            let control = device
                .rendering_control_url
                .as_ref()
                .ok_or_else(|| "device has no RenderingControl service".to_string())?;
            soap_call(
                http,
                control,
                RENDERING_ST,
                "SetVolume",
                &[
                    ("InstanceID", "0".into()),
                    ("Channel", "Master".into()),
                    ("DesiredVolume", format!("{}", value.unwrap_or(0.0) as i64)),
                ],
            )
            .await
            .map(|_| ())
        }
        "mute" => {
            let control = device
                .rendering_control_url
                .as_ref()
                .ok_or_else(|| "device has no RenderingControl service".to_string())?;
            soap_call(
                http,
                control,
                RENDERING_ST,
                "SetMute",
                &[
                    ("InstanceID", "0".into()),
                    ("Channel", "Master".into()),
                    ("DesiredMute", if value.unwrap_or(0.0) != 0.0 { "1".into() } else { "0".into() }),
                ],
            )
            .await
            .map(|_| ())
        }
        "subtitle" => Ok(()),
        other => Err(format!("unsupported action: {}", other)),
    }
}

pub async fn status(http: &reqwest::Client, device: &DlnaDevice) -> DlnaStatus {
    let state = match soap_call(http, &device.control_url, AVTRANSPORT_ST, "GetTransportInfo", &[("InstanceID", "0".into())]).await {
        Ok(info) => map_state(find_text(&info, "CurrentTransportState").as_deref()),
        Err(_) => "unknown".into(),
    };

    let mut position = 0.0;
    let mut duration = 0.0;
    if let Ok(info) = soap_call(http, &device.control_url, AVTRANSPORT_ST, "GetPositionInfo", &[("InstanceID", "0".into())]).await {
        position = parse_hhmmss(find_text(&info, "RelTime").as_deref());
        duration = parse_hhmmss(find_text(&info, "TrackDuration").as_deref());
    }

    let mut volume = 100.0;
    let mut muted = false;
    if let Some(control) = &device.rendering_control_url {
        if let Ok(res) = soap_call(
            http,
            control,
            RENDERING_ST,
            "GetVolume",
            &[("InstanceID", "0".into()), ("Channel", "Master".into())],
        )
        .await
        {
            if let Some(v) = find_text(&res, "CurrentVolume").and_then(|v| v.parse::<f64>().ok()) {
                volume = v;
            }
        }
        if let Ok(res) = soap_call(
            http,
            control,
            RENDERING_ST,
            "GetMute",
            &[("InstanceID", "0".into()), ("Channel", "Master".into())],
        )
        .await
        {
            if let Some(m) = find_text(&res, "CurrentMute").and_then(|m| m.trim().parse::<i64>().ok()) {
                muted = m != 0;
            }
        }
    }

    DlnaStatus { state, position, duration, volume, muted }
}

/// File size and video duration for the DIDL metadata, both best-effort.
///
/// Memoized: the same title is often cast repeatedly, and ffprobe costs
/// hundreds of milliseconds per call.
pub async fn size_and_duration(path: &Path) -> (Option<u64>, Option<f64>) {
    let size = std::fs::metadata(path).ok().map(|m| m.len()).filter(|s| *s > 0);
    let duration = crate::services::probe_service::cached_source_video_duration(path).await;
    let duration = if duration > 0.0 { Some(duration) } else { None };
    (size, duration)
}

/// Discovery results are considered fresh for this long.
pub fn is_fresh(scanned_at: SystemTime) -> bool {
    scanned_at
        .elapsed()
        .map(|e| e < Duration::from_secs(45))
        .unwrap_or(true)
}

pub fn http_client(timeout: Duration) -> reqwest::Client {
    client(timeout)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protocol_info_advertises_dlna_operations() {
        // The 4th field is the whole reason the DU7000 enables FF/prev.
        assert!(DLNA_CONTENT_FEATURES.starts_with("DLNA.ORG_OP=01"));
        assert!(DLNA_CONTENT_FEATURES.contains("DLNA.ORG_CI=0"));
        let xml = didl_metadata("Title", "http://1.2.3.4:8000/media/x.mkv", "video/x-matroska", Some(1234), Some(90.5));
        let res = xml.split("<res ").nth(1).unwrap();
        assert!(res.contains(&format!("http-get:*:video/x-matroska:{}", DLNA_CONTENT_FEATURES)));
        assert!(res.contains("size=\"1234\""));
        assert!(res.contains("duration=\"0:01:30.500\""));
    }

    #[test]
    fn missing_size_and_duration_omit_the_attributes_entirely() {
        let xml = didl_metadata("T", "http://h/m.mkv", "video/x-matroska", None, None);
        assert!(!xml.contains("size="));
        assert!(!xml.contains("duration="), "a 0 duration must be omitted, not sent as 0");
    }

    #[test]
    fn title_is_xml_escaped() {
        let xml = didl_metadata("Fast & Furious <part 1>", "http://h/m.mkv", "video/x-matroska", None, None);
        assert!(xml.contains("Fast &amp; Furious &lt;part 1&gt;"));
    }

    #[test]
    fn transport_states_map_to_the_player_vocabulary() {
        assert_eq!(map_state(Some("PLAYING")), "playing");
        assert_eq!(map_state(Some("PAUSED_PLAYBACK")), "paused");
        assert_eq!(map_state(Some("TRANSITIONING")), "buffering");
        assert_eq!(map_state(Some("NO_MEDIA_PRESENT")), "stopped");
        assert_eq!(map_state(None), "unknown");
        assert_eq!(map_state(Some("")), "unknown");
    }

    #[test]
    fn time_round_trips() {
        assert_eq!(hhmmss(0.0), "00:00:00");
        assert_eq!(hhmmss(3661.0), "01:01:01");
        assert_eq!(parse_hhmmss(Some("01:01:01")), 3661.0);
        assert_eq!(parse_hhmmss(Some("00:00:30.500")), 30.5);
        assert_eq!(parse_hhmmss(None), 0.0);
        assert_eq!(parse_hhmmss(Some("garbage")), 0.0);
        // A renderer may send H:MM:SS with one field omitted.
        assert_eq!(parse_hhmmss(Some("30:00")), 1800.0);
    }

    #[test]
    fn find_text_ignores_namespaces_and_takes_the_first_match() {
        let xml = r#"<s:Envelope xmlns:s="urn:x"><s:Body><u:GetPositionInfoResponse xmlns:u="urn:y">
            <TrackDuration>0:02:03.000</TrackDuration><RelTime>0:00:10.000</RelTime>
            </u:GetPositionInfoResponse></s:Body></s:Envelope>"#;
        assert_eq!(find_text(xml, "TrackDuration").as_deref(), Some("0:02:03.000"));
        assert_eq!(find_text(xml, "RelTime").as_deref(), Some("0:00:10.000"));
        assert_eq!(find_text(xml, "Missing"), None);
    }

    #[test]
    fn service_blocks_do_not_leak_into_each_other() {
        let xml = r#"<root><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
            <controlURL>/upnp/control/AVTransport1</controlURL></service>
            <service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
            <controlURL>/upnp/control/RenderingControl1</controlURL></service></root>"#;
        let blocks = split_services(xml);
        assert_eq!(blocks.len(), 2);
        assert!(blocks[0].contains("AVTransport1"));
        assert!(!blocks[0].contains("RenderingControl1"), "a field must not leak into the next block");
    }

    #[test]
    fn soap_envelope_escapes_argument_values() {
        let xml = soap_envelope(AVTRANSPORT_ST, "Seek", &[("Target", "00:00:01".into()), ("Note", "a&b".into())]);
        assert!(xml.contains("<Target>00:00:01</Target>"));
        assert!(xml.contains("a&amp;b"));
        assert!(xml.contains(&format!("xmlns:u=\"{}\"", AVTRANSPORT_ST)));
    }

    #[test]
    fn control_urls_join_against_the_device_origin() {
        assert_eq!(
            url_join("http://192.168.1.8:9197/dmr", "/upnp/control/AVTransport1"),
            "http://192.168.1.8:9197/upnp/control/AVTransport1"
        );
        assert_eq!(
            url_join("http://192.168.1.8:9197/dmr", "upnp/control/AVTransport1"),
            "http://192.168.1.8:9197/upnp/control/AVTransport1"
        );
        assert_eq!(
            url_join("http://1.2.3.4/dmr", "http://other/x"),
            "http://other/x",
            "an absolute control URL is used as-is"
        );
    }

    #[test]
    fn lan_ip_is_a_private_address() {
        let ip = lan_ip();
        assert!(!ip.is_empty());
        assert_ne!(ip, "0.0.0.0");
    }
}