//! Cast transport: TLS to 8009, length-prefixed frames, request/response.
//!
//! ## On certificate validation
//!
//! Cast receivers present **self-signed X.509 v1** certificates. Measured on
//! the DU7000: `subject == issuer`, `Version 1`.
//!
//! That v1 detail is not cosmetic. rustls-webpki accepts **only v3** and
//! rejects a v1 certificate while extracting its public key - before any
//! verifier of ours runs - so rustls cannot speak to a Cast receiver at all.
//! This module therefore uses the Windows Schannel stack through `native-tls`,
//! which accepts them.
//!
//! What is bypassed is only the *trust chain*. Schannel still verifies the
//! handshake signature against the certificate's public key, so a passive
//! third party cannot simply impersonate the television; only a party able to
//! intercept and rewrite traffic is unprotected, and there is no certificate
//! here to check such a party against in any case.
//!
//! Connections are only ever opened to a `host:port` that discovery returned.
//! A client-supplied host never reaches this code: the cast routes resolve a
//! device id against the discovery cache and pass the stored host.

use crate::services::cast_proto::{
    self, CastMessage, DEFAULT_RECEIVER_ID, NS_CONNECTION, NS_HEARTBEAT,
};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::time::timeout;

/// Dial and handshake budget. Generous: a receiver that is waking from sleep
/// can take several seconds to answer.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(12);
const IO_TIMEOUT: Duration = Duration::from_secs(8);

/// PING before a command when the connection has been idle this long. The
/// receiver closes a connection silent for ~10s.
const HEARTBEAT_AFTER_IDLE: Duration = Duration::from_secs(5);

fn tls_connector() -> Result<tokio_native_tls::TlsConnector, String> {
    let connector = native_tls::TlsConnector::builder()
        // Self-signed, so there is no chain to validate against.
        .danger_accept_invalid_certs(true)
        .danger_accept_invalid_hostnames(true)
        // The certificate's CN is a UUID, not the host we dialled.
        .use_sni(false)
        .build()
        .map_err(|e| e.to_string())?;
    Ok(tokio_native_tls::TlsConnector::from(connector))
}

/// A live connection to one receiver.
pub struct CastConnection {
    stream: tokio_native_tls::TlsStream<TcpStream>,
    source_id: String,
    buffer: Vec<u8>,
    next_request_id: i64,
    last_activity: std::time::Instant,
    /// The launched media app's `transportId`.
    ///
    /// This is a **per-session UUID**, not the constant
    /// `urn:x-cast:com.google.cast.media-receiver` that the documentation and
    /// most examples show. Addressing media messages at the constant instead
    /// is what a receiver answers with `CLOSE` on the connection namespace:
    /// there is no virtual connection to that id, because the app's real
    /// transport is the UUID the receiver itself reported.
    app_transport: Option<String>,
}

impl CastConnection {
    /// Record the launched app's transport id.
    pub fn set_app_transport(&mut self, transport_id: String) {
        self.app_transport = Some(transport_id);
    }

    /// Where media-namespace messages must be addressed.
    pub fn app_transport(&self) -> &str {
        self.app_transport
            .as_deref()
            .unwrap_or(crate::services::cast_proto::MEDIA_RECEIVER_TRANSPORT_FALLBACK)
    }
}

/// One session id per connection, so two casts to the same receiver do not
/// collide.
///
/// Shaped as `sender-<uuid>` because that is what every real Cast client sends
/// and a receiver may reasonably key on the form. The value is derived from
/// the clock plus a counter rather than a uuid crate.
fn make_source_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let hi = nanos;
    let lo = n.wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ (nanos.rotate_left(17));
    format!(
        "sender-{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
        (hi >> 32) as u32,
        (hi >> 16) as u16,
        hi as u16,
        ((lo >> 48) as u16) | 0x4000,
        lo & 0x0000_FFFF_FFFF_FFFF
    )
}

impl CastConnection {
    pub async fn connect(host: &str) -> Result<Self, String> {
        let addr = format!("{}:8009", host);
        let tcp = timeout(CONNECT_TIMEOUT, TcpStream::connect(&addr))
            .await
            .map_err(|_| format!("timed out connecting to {}", addr))?
            .map_err(|e| format!("could not reach {}: {}", addr, e))?;
        tcp.set_nodelay(true).ok();

        let connector = tls_connector()?;
        let stream = timeout(CONNECT_TIMEOUT, connector.connect(host, tcp))
            .await
            .map_err(|_| format!("TLS handshake timed out for {}", host))?
            .map_err(|e| format!("TLS handshake failed for {}: {}", host, e))?;

        Ok(Self {
            stream,
            source_id: make_source_id(),
            buffer: Vec::with_capacity(4096),
            next_request_id: 1,
            last_activity: std::time::Instant::now(),
            app_transport: None,
        })
    }

    pub fn source_id(&self) -> &str {
        &self.source_id
    }

    async fn write_frame(&mut self, msg: &CastMessage) -> Result<(), String> {
        let frame = msg.encode_frame();
        timeout(IO_TIMEOUT, self.stream.write_all(&frame))
            .await
            .map_err(|_| "write timed out".to_string())?
            .map_err(|e| e.to_string())?;
        self.last_activity = std::time::Instant::now();
        Ok(())
    }

    /// Read one frame, waiting for it to arrive.
    async fn read_frame(&mut self) -> Result<CastMessage, String> {
        loop {
            let messages = cast_proto::parse_frames(&mut self.buffer).map_err(|e| e.0)?;
            if let Some(msg) = messages.into_iter().next() {
                self.last_activity = std::time::Instant::now();
                return Ok(msg);
            }
            let mut chunk = [0u8; 4096];
            let n = timeout(IO_TIMEOUT, self.stream.read(&mut chunk))
                .await
                .map_err(|_| "read timed out".to_string())?
                .map_err(|e| e.to_string())?;
            if n == 0 {
                return Err("receiver closed the connection".into());
            }
            self.buffer.extend_from_slice(&chunk[..n]);
        }
    }

    /// Every frame the receiver pushes within `window`, without matching.
    ///
    /// A receiver answers a LOAD on the media namespace and separately pushes
    /// `RECEIVER_STATUS` / `MEDIA_STATUS` on its own initiative. Correlating by
    /// `requestId` is correct for a request, but a receiver that answers
    /// differently from expectation then looks identical to one that never
    /// answered — so this exists to see what actually arrived.
    pub async fn drain(&mut self, window: Duration) -> Vec<CastMessage> {
        let deadline = tokio::time::Instant::now() + window;
        let mut out = Vec::new();
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            match timeout(remaining, self.read_frame()).await {
                Ok(Ok(msg)) => out.push(msg),
                Ok(Err(_)) | Err(_) => break,
            }
        }
        out
    }

    /// Write a message with no heartbeat and no reply handling.
    ///
    /// Kept separate from [`Self::send`] so the heartbeat path cannot recurse
    /// into itself - `send` calls `ensure_alive`, which must therefore not call
    /// `send`.
    pub(crate) async fn send_raw(
        &mut self,
        namespace: &str,
        destination: &str,
        payload: serde_json::Value,
    ) -> Result<(), String> {
        let msg = CastMessage::text(
            &self.source_id.clone(),
            destination,
            namespace,
            &payload.to_string(),
        );
        self.write_frame(&msg).await
    }

    /// Send a message and ignore the reply, after honouring the heartbeat.
    pub async fn send(
        &mut self,
        namespace: &str,
        destination: &str,
        payload: serde_json::Value,
    ) -> Result<(), String> {
        self.ensure_alive().await?;
        self.send_raw(namespace, destination, payload).await
    }

    /// Send a request and wait for the matching response.
    ///
    /// Matching is by `requestId`. Unsolicited traffic the receiver pushes -
    /// `MEDIA_STATUS` on transitions, for instance - is consumed and
    /// discarded rather than mistaken for the answer.
    pub async fn request(
        &mut self,
        namespace: &str,
        destination: &str,
        payload: serde_json::Value,
    ) -> Result<serde_json::Value, String> {
        self.ensure_alive().await?;
        let request_id = self.next_request_id;
        self.next_request_id += 1;

        let mut payload = payload;
        payload["requestId"] = serde_json::json!(request_id);
        let msg = CastMessage::text(
            &self.source_id.clone(),
            destination,
            namespace,
            &payload.to_string(),
        );
        self.write_frame(&msg).await?;

        let deadline = tokio::time::Instant::now() + IO_TIMEOUT;
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                return Err(format!(
                    "no response to request {} in {:?}",
                    request_id, IO_TIMEOUT
                ));
            }
            let msg = match timeout(remaining, self.read_frame()).await {
                Ok(result) => result?,
                Err(_) => {
                    return Err(format!(
                        "no response to request {} in {:?}",
                        request_id, IO_TIMEOUT
                    ));
                }
            };

            // A receiver may PING us, and expects a PONG. Answering is not
            // optional: a receiver that pings into silence tears the virtual
            // connection down, and the symptom is a CLOSE arriving mid-request
            // with no further replies.
            if msg.namespace == NS_HEARTBEAT && msg.message_type().as_deref() == Some("PING") {
                self.send_raw(
                    NS_HEARTBEAT,
                    &msg.source_id,
                    serde_json::json!({ "type": "PONG" }),
                )
                .await?;
                continue;
            }

            if msg.request_id() == Some(request_id) {
                return Ok(serde_json::from_str(msg.text_payload().unwrap_or("{}"))
                    .unwrap_or(serde_json::Value::Null));
            }
        }
    }

    /// Open the virtual connection, then keep it warm.
    pub async fn connect_channel(&mut self) -> Result<(), String> {
        self.send(
            NS_CONNECTION,
            DEFAULT_RECEIVER_ID,
            serde_json::json!({ "type": "CONNECT", "origin": {} }),
        )
        .await
    }

    /// PING when idle, so the receiver does not time the socket out.
    async fn ensure_alive(&mut self) -> Result<(), String> {
        if self.last_activity.elapsed() < HEARTBEAT_AFTER_IDLE {
            return Ok(());
        }
        self.send_raw(
            NS_HEARTBEAT,
            DEFAULT_RECEIVER_ID,
            serde_json::json!({ "type": "PING" }),
        )
        .await
    }

    /// POLL_AFTER_HANDSHAKE, then a bounded wait for the receiver's reply.
    pub async fn poll_after_handshake(&mut self) -> Result<(), String> {
        let pong = self
            .request(
                NS_CONNECTION,
                DEFAULT_RECEIVER_ID,
                serde_json::json!({ "type": "POLL_AFTER_HANDSHAKE" }),
            )
            .await?;
        let _ = pong;
        Ok(())
    }

    /// Close the virtual connection.
    ///
    /// This used to send `{"type": "CLOSE"}` on the connection namespace to
    /// `receiver-0` first. That is not what the working Flask path does:
    /// pychromecast sends `CLOSE` only from `disconnect_channel`, addressed to
    /// the **app's transport id** and carrying an `origin` object, and
    /// `cast.quit_app()` -> `cast.disconnect()` never sends one to `receiver-0`
    /// at all. It was added here on the assumption that a message would close the
    /// app; the correct quit (`STOP` + `sessionId`) is what actually does that,
    /// and the invented `CLOSE` was a second, wrong answer to the same question.
    ///
    /// So this now matches the working implementation: quit the app, then drop
    /// the socket.
    pub async fn close(&mut self) {
        let _ = self.stream.shutdown().await;
    }
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_ids_are_unique_per_connection() {
        let a = make_source_id();
        let b = make_source_id();
        assert_ne!(a, b, "two casts must not share a sender id");
        assert!(a.starts_with("sender-"), "{}", a);
        // UUID-shaped, because that is what every real Cast client sends.
        assert_eq!(
            a.len(),
            "sender-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx".len(),
            "{}",
            a
        );
        assert_eq!(a.chars().filter(|c| *c == '-').count(), 5, "{}", a);
    }

    #[test]
    fn the_tls_connector_builds_without_a_trust_store() {
        // No root store is loaded: a self-signed receiver certificate cannot be
        // validated against a CA, so there is nothing to configure.
        tls_connector().expect("connector");
    }

    #[tokio::test]
    async fn connecting_to_a_dead_port_fails_rather_than_hanging() {
        let result = timeout(
            Duration::from_secs(20),
            CastConnection::connect("127.0.0.1"),
        )
        .await;
        assert!(result.is_ok(), "the connect attempt itself must finish");
        match result {
            Ok(Ok(_)) => panic!("nothing is listening on 127.0.0.1:8009"),
            Ok(Err(_)) => {}
            Err(_) => panic!("connect did not return within 20s"),
        }
    }

    /// Live handshake against a real receiver.
    ///
    /// Gated, because the suite must not depend on a television being present.
    /// It prints SKIPPED rather than passing quietly, so an ungated run cannot
    /// be mistaken for a verified one.
    ///
    ///   set MEDIA_SERVER_CAST_LIVE_TESTS=1
    ///   set MEDIA_SERVER_CAST_LIVE_HOST=192.168.1.8
    #[tokio::test]
    async fn live_receiver_handshake() {
        if std::env::var("MEDIA_SERVER_CAST_LIVE_TESTS").is_err() {
            eprintln!("SKIPPED live_receiver_handshake (set MEDIA_SERVER_CAST_LIVE_TESTS=1)");
            return;
        }
        let host = match std::env::var("MEDIA_SERVER_CAST_LIVE_HOST") {
            Ok(h) if !h.is_empty() => h,
            _ => {
                eprintln!("SKIPPED live_receiver_handshake (MEDIA_SERVER_CAST_LIVE_HOST not set)");
                return;
            }
        };

        let mut conn = CastConnection::connect(&host).await.expect("TLS handshake");
        conn.connect_channel().await.expect("CONNECT");

        // A receiver answers GET_STATUS on its own namespace; getting a reply is
        // proof the framed protobuf survived the round trip in both directions.
        let reply = conn
            .request(
                crate::services::cast_proto::NS_RECEIVER,
                DEFAULT_RECEIVER_ID,
                serde_json::json!({ "type": "GET_STATUS" }),
            )
            .await
            .expect("GET_STATUS reply");

        let status = crate::services::cast_proto::parse_receiver_status(&reply.to_string());
        eprintln!("LIVE raw GET_STATUS reply: {}", reply);
        eprintln!(
            "LIVE handshake ok: volume={:?} muted={:?} as_percent={}",
            status.volume_level,
            status.volume_muted,
            status.percent_volume()
        );
        assert_eq!(
            reply["type"].as_str(),
            Some("RECEIVER_STATUS"),
            "the reply must be correlated to our requestId and typed"
        );
        assert_eq!(
            status.percent_volume(),
            100.0,
            "a receiver in standby reports no volume, so the default must hold rather \
             than being invented as 0"
        );
        conn.close().await;
    }
}
