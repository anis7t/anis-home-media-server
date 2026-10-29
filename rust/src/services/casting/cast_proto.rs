//! The Cast wire protocol: a protobuf `CastMessage` envelope carrying a JSON
//! payload, inside a 4-byte big-endian length prefix, over TLS.
//!
//! Hand-rolled deliberately. `CastMessage` has seven fields, six of them
//! strings or varints, and the payload *inside* it is plain JSON - so this is
//! a protobuf envelope around JSON, not a schema. Taking a dependency for
//! that would put an unmaintained crate in the one component that drives the
//! television.
//!
//! Unknown fields are skipped on decode rather than rejected: receivers add
//! fields between firmware releases, and a strict decoder would drop a cast
//! on an unrelated update.

use serde::Serialize;

pub const NS_CONNECTION: &str = "urn:x-cast:com.google.cast.tp.connection";
pub const NS_HEARTBEAT: &str = "urn:x-cast:com.google.cast.tp.heartbeat";
pub const NS_RECEIVER: &str = "urn:x-cast:com.google.cast.receiver";
pub const NS_MEDIA: &str = "urn:x-cast:com.google.cast.media";

pub const DEFAULT_RECEIVER_ID: &str = "receiver-0";
pub const DEFAULT_SENDER_ID: &str = "sender-0";
/// The default media receiver app. Its absence is what distinguishes
/// "nothing is loaded" from "still starting".
pub const MEDIA_RECEIVER_APP_ID: &str = "CC1AD845";

/// The transport id the documentation shows for the media namespace.
///
/// A fallback only. A receiver reports a **per-session UUID** as the launched
/// app's `transportId`, and that is the only address a media message may be
/// sent to - addressing this constant instead is answered with `CLOSE` on the
/// connection namespace. Measured on the DU7000, whose real transport id was
/// `d6588793-2fd5-4d73-9d3c-a0ed1f584088`.
pub const MEDIA_RECEIVER_TRANSPORT_FALLBACK: &str = "urn:x-cast:com.google.cast.media-receiver";

/// `BUFFERED`, not `LIVE`.
///
/// pychromecast defaults to `LIVE`, and a receiver told the stream is live
/// treats it as **unseekable** - so both our own Seek commands and a scrub
/// from the phone did nothing. This string is the whole of that bug.
pub const STREAM_TYPE_BUFFERED: &str = "BUFFERED";

/// How long a control command may wait for a media session to appear before
/// it is sent anyway.
pub const SESSION_WAIT: std::time::Duration = std::time::Duration::from_secs(4);

const PROTOCOL_VERSION_CASTV2_1_0: u64 = 0;
const PAYLOAD_TYPE_STRING: u64 = 0;
const PAYLOAD_TYPE_BINARY: u64 = 1;

#[derive(Debug, Clone, PartialEq)]
pub struct CastMessage {
    pub protocol_version: u64,
    pub source_id: String,
    pub destination_id: String,
    pub namespace: String,
    pub payload_type: u64,
    pub payload_utf8: Option<String>,
    pub payload_binary: Option<Vec<u8>>,
}

impl CastMessage {
    pub fn text(source_id: &str, destination_id: &str, namespace: &str, payload: &str) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION_CASTV2_1_0,
            source_id: source_id.to_string(),
            destination_id: destination_id.to_string(),
            namespace: namespace.to_string(),
            payload_type: PAYLOAD_TYPE_STRING,
            payload_utf8: Some(payload.to_string()),
            payload_binary: None,
        }
    }

    pub fn binary(source_id: &str, destination_id: &str, namespace: &str, payload: &[u8]) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION_CASTV2_1_0,
            source_id: source_id.to_string(),
            destination_id: destination_id.to_string(),
            namespace: namespace.to_string(),
            payload_type: PAYLOAD_TYPE_BINARY,
            payload_utf8: None,
            payload_binary: Some(payload.to_vec()),
        }
    }

    /// The JSON payload, or `None` for a binary message.
    pub fn text_payload(&self) -> Option<&str> {
        self.payload_utf8.as_deref()
    }

    /// `{"type": "..."}` - how a Cast message identifies itself.
    pub fn message_type(&self) -> Option<String> {
        let payload = self.payload_utf8.as_deref()?;
        let value: serde_json::Value = serde_json::from_str(payload).ok()?;
        value.get("type")?.as_str().map(|s| s.to_string())
    }

    /// `requestId`, used to match a response to its request.
    pub fn request_id(&self) -> Option<i64> {
        let payload = self.payload_utf8.as_deref()?;
        let value: serde_json::Value = serde_json::from_str(payload).ok()?;
        value.get("requestId")?.as_i64()
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(64);
        write_varint_field(&mut out, 1, self.protocol_version);
        write_string_field(&mut out, 2, &self.source_id);
        write_string_field(&mut out, 3, &self.destination_id);
        write_string_field(&mut out, 4, &self.namespace);
        write_varint_field(&mut out, 5, self.payload_type);
        if let Some(p) = &self.payload_utf8 {
            write_string_field(&mut out, 6, p);
        }
        if let Some(p) = &self.payload_binary {
            write_bytes_field(&mut out, 7, p);
        }
        out
    }

    /// Length-prefixed frame, which is what actually goes on the wire.
    pub fn encode_frame(&self) -> Vec<u8> {
        let body = self.encode();
        let mut out = Vec::with_capacity(body.len() + 4);
        out.extend_from_slice(&(body.len() as u32).to_be_bytes());
        out.extend_from_slice(&body);
        out
    }
}

// ------------------------------------------------------------------- encoding

fn write_varint(out: &mut Vec<u8>, mut value: u64) {
    loop {
        let byte = (value & 0x7f) as u8;
        value >>= 7;
        if value == 0 {
            out.push(byte);
            break;
        }
        out.push(byte | 0x80);
    }
}

fn write_tag(out: &mut Vec<u8>, field: u64, wire_type: u64) {
    write_varint(out, (field << 3) | wire_type);
}

fn write_varint_field(out: &mut Vec<u8>, field: u64, value: u64) {
    // proto3 omits zero values; both enums default to 0, so a zero protocol
    // version and a zero payload type are simply not transmitted. Receivers
    // default them correctly.
    if value == 0 {
        return;
    }
    write_tag(out, field, 0);
    write_varint(out, value);
}

fn write_bytes_field(out: &mut Vec<u8>, field: u64, value: &[u8]) {
    write_tag(out, field, 2);
    write_varint(out, value.len() as u64);
    out.extend_from_slice(value);
}

fn write_string_field(out: &mut Vec<u8>, field: u64, value: &str) {
    write_bytes_field(out, field, value.as_bytes());
}

// ------------------------------------------------------------------- decoding

#[derive(Debug)]
pub struct ProtoError(pub String);

impl std::fmt::Display for ProtoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for ProtoError {}

struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }

    fn done(&self) -> bool {
        self.pos >= self.buf.len()
    }

    fn read_byte(&mut self) -> Result<u8, ProtoError> {
        let b = *self
            .buf
            .get(self.pos)
            .ok_or_else(|| ProtoError("truncated varint".into()))?;
        self.pos += 1;
        Ok(b)
    }

    fn read_varint(&mut self) -> Result<u64, ProtoError> {
        let mut value = 0u64;
        let mut shift = 0u32;
        loop {
            let byte = self.read_byte()?;
            value |= ((byte & 0x7f) as u64) << shift;
            if byte & 0x80 == 0 {
                return Ok(value);
            }
            shift += 7;
            if shift > 63 {
                return Err(ProtoError("varint overflow".into()));
            }
        }
    }

    fn read_bytes(&mut self) -> Result<&'a [u8], ProtoError> {
        let len = self.read_varint()? as usize;
        if self.pos + len > self.buf.len() {
            return Err(ProtoError(format!(
                "length-delimited field claims {} bytes, {} remain",
                len,
                self.buf.len() - self.pos
            )));
        }
        let slice = &self.buf[self.pos..self.pos + len];
        self.pos += len;
        Ok(slice)
    }

    fn skip(&mut self, wire_type: u64) -> Result<(), ProtoError> {
        match wire_type {
            0 => {
                self.read_varint()?;
            }
            1 => {
                self.pos += 8;
                if self.pos > self.buf.len() {
                    return Err(ProtoError("truncated 64-bit field".into()));
                }
            }
            2 => {
                self.read_bytes()?;
            }
            5 => {
                self.pos += 4;
                if self.pos > self.buf.len() {
                    return Err(ProtoError("truncated 32-bit field".into()));
                }
            }
            other => {
                return Err(ProtoError(format!("unsupported wire type {}", other)));
            }
        }
        Ok(())
    }
}

impl CastMessage {
    pub fn decode(body: &[u8]) -> Result<Self, ProtoError> {
        let mut r = Reader::new(body);
        let mut msg = CastMessage {
            protocol_version: 0,
            source_id: String::new(),
            destination_id: String::new(),
            namespace: String::new(),
            payload_type: 0,
            payload_utf8: None,
            payload_binary: None,
        };
        while !r.done() {
            let key = r.read_varint()?;
            let field = key >> 3;
            let wire_type = key & 0x07;
            match (field, wire_type) {
                (1, 0) => msg.protocol_version = r.read_varint()?,
                (2, 2) => msg.source_id = to_string(r.read_bytes()?),
                (3, 2) => msg.destination_id = to_string(r.read_bytes()?),
                (4, 2) => msg.namespace = to_string(r.read_bytes()?),
                (5, 0) => msg.payload_type = r.read_varint()?,
                (6, 2) => msg.payload_utf8 = Some(to_string(r.read_bytes()?)),
                (7, 2) => msg.payload_binary = Some(r.read_bytes()?.to_vec()),
                // Unknown field: skip it rather than fail. Receivers add fields
                // between firmware releases, and a strict decoder would drop a
                // cast on an unrelated update.
                _ => r.skip(wire_type)?,
            }
        }
        Ok(msg)
    }
}

fn to_string(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).to_string()
}

/// Drain every **complete** frame from a streaming buffer.
///
/// An incomplete trailing frame is left in place rather than reported: this
/// runs on a socket read, where the rest of the frame simply has not arrived
/// yet. Returning an error there would turn normal streaming into a fault.
///
/// This must not be written as "loop until a read fails": the leftover bytes
/// are not frames, and treating them as zero-length frames produces an
/// unbounded run of empty messages.
pub fn parse_frames(buf: &mut Vec<u8>) -> Result<Vec<CastMessage>, ProtoError> {
    let mut out = Vec::new();
    let mut offset = 0usize;
    loop {
        if buf.len() - offset < 4 {
            break;
        }
        let len = u32::from_be_bytes([
            buf[offset],
            buf[offset + 1],
            buf[offset + 2],
            buf[offset + 3],
        ]) as usize;
        if buf.len() - offset < 4 + len {
            break;
        }
        if len == 0 {
            // A real frame always carries at least a source, destination and
            // namespace. Accepting a zero-length body would turn leftover or
            // zeroed bytes into a run of phantom empty messages.
            return Err(ProtoError("zero-length frame".into()));
        }
        out.push(CastMessage::decode(&buf[offset + 4..offset + 4 + len])?);
        offset += 4 + len;
    }
    buf.drain(..offset);
    Ok(out)
}

/// Decode exactly one frame from a complete buffer.
pub fn decode_frame(bytes: &[u8]) -> Result<CastMessage, ProtoError> {
    if bytes.len() < 4 {
        return Err(ProtoError("frame header incomplete".into()));
    }
    let len = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as usize;
    if bytes.len() < 4 + len {
        return Err(ProtoError("frame body incomplete".into()));
    }
    CastMessage::decode(&bytes[4..4 + len])
}

// -------------------------------------------------------------- payload types

#[derive(Debug, Clone, Serialize)]
pub struct MediaTrack {
    #[serde(rename = "trackId")]
    pub track_id: i64,
    #[serde(rename = "trackContentId")]
    pub track_content_id: String,
    #[serde(default)]
    pub language: String,
    pub subtype: String,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(rename = "trackContentType")]
    pub track_content_type: String,
    #[serde(default)]
    pub name: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct TextTrackStyle {
    #[serde(rename = "backgroundColor")]
    pub background_color: &'static str,
    #[serde(rename = "foregroundColor")]
    pub foreground_color: &'static str,
    #[serde(rename = "edgeType")]
    pub edge_type: &'static str,
    #[serde(rename = "edgeColor")]
    pub edge_color: &'static str,
    #[serde(rename = "fontScale")]
    pub font_scale: f64,
}

impl Default for TextTrackStyle {
    fn default() -> Self {
        Self {
            background_color: "#00000000",
            foreground_color: "#FFFFFFFF",
            edge_type: "OUTLINE",
            edge_color: "#000000FF",
            font_scale: 1.1,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct MediaInfo {
    pub metadata: serde_json::Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tracks: Option<Vec<MediaTrack>>,
    #[serde(rename = "textTrackStyle", skip_serializing_if = "Option::is_none")]
    pub text_track_style: Option<TextTrackStyle>,
}

/// Receiver-reported volume lives in its own namespace.
#[derive(Debug, Clone, Copy)]
pub struct ReceiverStatus {
    pub volume_level: Option<f64>,
    pub volume_muted: Option<bool>,
}

impl ReceiverStatus {
    /// `volume_level` is 0.0–1.0 on the wire; the player works in 0–100.
    pub fn percent_volume(&self) -> f64 {
        self.volume_level
            .map(|v| (v * 100.0).round())
            .unwrap_or(100.0)
    }
}

/// Parse the **receiver** (platform) volume out of a `RECEIVER_STATUS` payload.
///
/// This is the television's own speaker level — the same value the working
/// Flask path reports, from `cast.status.volume_level`. pychromecast reads it
/// as:
///
/// ```python
/// volume_data = status_data.get("volume", {})
/// ... volume_data.get("level", 1.0), volume_data.get("muted", False),
/// ```
///
/// so the fields are **nested** under `status.volume`:
///
/// ```json
/// {"status": {"volume": {"level": 0.25, "muted": false,
///                        "controlType": "attenuation"}}}
/// ```
///
/// An earlier version read `status.volume` as a scalar and `status.muted` at
/// the top level. Both lookups therefore missed on a real payload, and the
/// result was the documented fallbacks — 100 and unmuted — on **every** read,
/// which is exactly what every live run printed. Because the test fixture
/// encoded the same wrong shape, the suite stayed green.
///
/// The flat spelling is kept as a fallback: it costs nothing and tolerates a
/// receiver that flattens it. It is no longer the primary path, and the tests
/// now pin the real nested payload.
pub fn parse_receiver_status(payload: &str) -> ReceiverStatus {
    let value: serde_json::Value = match serde_json::from_str(payload) {
        Ok(v) => v,
        Err(_) => {
            return ReceiverStatus {
                volume_level: None,
                volume_muted: None,
            }
        }
    };
    let status = status_object(&value).unwrap_or(&value);

    let volume = status.get("volume");
    let read_level = |key: &str| -> Option<f64> {
        volume
            .and_then(|v| v.get(key))
            .or_else(|| status.get(key))
            .and_then(|v| v.as_f64())
    };

    ReceiverStatus {
        volume_level: read_level("level").or_else(|| volume.and_then(|v| v.as_f64())),
        volume_muted: volume
            .and_then(|v| v.get("muted"))
            .or_else(|| status.get("muted"))
            .and_then(|v| v.as_bool()),
    }
}

/// Media status from `GET_STATUS`, in the shape the players already consume.
#[derive(Debug, Clone)]
pub struct MediaStatus {
    pub state: String,
    pub position: f64,
    pub duration: f64,
}

/// The `status` member of a receiver reply, as an object.
///
/// Google documents an object. A real Samsung DU7000 sends a **list** for
/// `MEDIA_STATUS` — `{"status":[{"playerState":...}]}`, and `[]` while idle.
/// Reading that as an object yields nothing at all, so a perfectly playing cast
/// reports `unknown` with a zero position, and `seek` fails with "no media
/// session yet" on a cast that is demonstrably playing.
///
/// Every reader of `status` goes through here rather than indexing it directly.
/// The bug was fixed twice because the assumption was made in two places.
pub fn status_object(value: &serde_json::Value) -> Option<&serde_json::Value> {
    match value.get("status") {
        Some(serde_json::Value::Array(items)) => items.first(),
        Some(serde_json::Value::Object(_)) => value.get("status"),
        _ => None,
    }
}

pub fn parse_media_status(payload: &str) -> Option<MediaStatus> {
    let value: serde_json::Value = serde_json::from_str(payload).ok()?;
    let status = status_object(&value)?;

    // Idle means nothing is loaded, which is not the same as stopped.
    let player_state = status
        .get("playerState")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_uppercase();
    let state = match player_state.as_str() {
        "PLAYING" => "playing".to_string(),
        "PAUSED" => "paused".to_string(),
        "BUFFERING" => "buffering".to_string(),
        "IDLE" => "stopped".to_string(),
        "" => "unknown".to_string(),
        other => other.to_lowercase(),
    };

    let nested = status.get("media").and_then(|m| m.get("status"));
    let current = status
        .get("currentTime")
        .or_else(|| nested.and_then(|n| n.get("currentTime")))
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);
    let duration = status
        .get("duration")
        .or_else(|| nested.and_then(|n| n.get("duration")))
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);

    Some(MediaStatus {
        state,
        position: current,
        duration,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_text_message_round_trips() {
        let msg = CastMessage::text(
            "sender-abc",
            DEFAULT_RECEIVER_ID,
            NS_CONNECTION,
            r#"{"type":"CONNECT"}"#,
        );
        let bytes = msg.encode();
        let back = CastMessage::decode(&bytes).expect("decode");
        assert_eq!(back, msg);
        assert_eq!(back.message_type().as_deref(), Some("CONNECT"));
    }

    #[test]
    fn encoding_matches_the_hand_computed_bytes() {
        // CastMessage{ source_id:"sender-1", destination_id:"receiver-0",
        //               namespace:"urn:x-cast:com.google.cast.tp.heartbeat",
        //               payload_utf8:"{\"type\":\"PING\"}" }
        //
        // Fields 1 and 5 are zero-valued enums and are omitted, as proto3 does.
        let msg = CastMessage::text("sender-1", "receiver-0", NS_HEARTBEAT, r#"{"type":"PING"}"#);
        let bytes = msg.encode();

        let mut expected: Vec<u8> = Vec::new();
        expected.push(0x12);
        expected.push(8);
        expected.extend_from_slice(b"sender-1");
        expected.push(0x1a);
        expected.push(10);
        expected.extend_from_slice(b"receiver-0");
        expected.push(0x22);
        expected.push(39);
        expected.extend_from_slice(b"urn:x-cast:com.google.cast.tp.heartbeat");
        expected.push(0x32);
        expected.push(15);
        expected.extend_from_slice(br#"{"type":"PING"}"#);

        assert_eq!(
            bytes, expected,
            "wire bytes must match the protocol, not just round-trip"
        );
    }

    #[test]
    fn frames_are_length_prefixed_big_endian() {
        let msg = CastMessage::text("s", "receiver-0", NS_HEARTBEAT, r#"{"type":"PING"}"#);
        let frame = msg.encode_frame();
        let body = msg.encode();
        assert_eq!(&frame[..4], &(body.len() as u32).to_be_bytes());
        assert_eq!(&frame[4..], &body[..]);
    }

    #[test]
    fn a_buffer_holding_two_frames_yields_both() {
        let a = CastMessage::text("s", "receiver-0", NS_HEARTBEAT, r#"{"type":"PING"}"#);
        let b = CastMessage::text(
            "s",
            DEFAULT_RECEIVER_ID,
            NS_CONNECTION,
            r#"{"type":"CONNECT"}"#,
        );
        let mut buf = a.encode_frame();
        buf.extend_from_slice(&b.encode_frame());

        let frames = parse_frames(&mut buf).expect("parse");
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].message_type().as_deref(), Some("PING"));
        assert_eq!(frames[1].message_type().as_deref(), Some("CONNECT"));
        assert!(buf.is_empty(), "no bytes left over");
    }

    #[test]
    fn a_partial_frame_is_kept_for_the_next_read_not_reported_as_an_error() {
        let msg = CastMessage::text("sender-1", "receiver-0", NS_HEARTBEAT, r#"{"type":"PING"}"#);
        let frame = msg.encode_frame();
        let partial_len = frame.len() - 3;
        let mut buf = frame[..partial_len].to_vec();

        let frames = parse_frames(&mut buf).expect("a half-received frame is normal, not a fault");
        assert!(frames.is_empty(), "an incomplete frame must not decode");
        assert_eq!(buf.len(), partial_len, "it must be retained, byte for byte");

        // The rest arrives, and the frame completes.
        buf.extend_from_slice(&frame[partial_len..]);
        let frames = parse_frames(&mut buf).expect("parse");
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].message_type().as_deref(), Some("PING"));
        assert!(buf.is_empty());
    }

    #[test]
    fn a_zero_length_frame_is_a_protocol_error_not_a_run_of_phantoms() {
        // The first version of this drained consumed bytes but re-scanned the
        // zeroed tail as zero-length frames, and tried to allocate 18 GB
        // before the test binary died.
        let mut buf = vec![0u8; 64];
        let err = parse_frames(&mut buf).unwrap_err();
        assert!(err.0.contains("zero-length"), "{}", err);
    }

    #[test]
    fn unknown_fields_are_skipped_not_rejected() {
        let mut bytes =
            CastMessage::text("s", "receiver-0", NS_CONNECTION, r#"{"type":"CONNECT"}"#).encode();
        // Field 99, wire type 2 (length-delimited), one byte of payload.
        bytes.push((99 << 3) | 2);
        bytes.push(1);
        bytes.push(0xAB);
        let msg =
            CastMessage::decode(&bytes).expect("a new firmware field must not break decoding");
        assert_eq!(msg.message_type().as_deref(), Some("CONNECT"));
    }

    #[test]
    fn a_truncated_length_delimited_field_is_rejected() {
        // Claims 200 bytes, supplies 2.
        let bytes = vec![0x12, 200, 0x41, 0x42];
        assert!(CastMessage::decode(&bytes).is_err());
    }

    #[test]
    fn binary_messages_carry_their_payload() {
        let msg = CastMessage::binary("s", "receiver-0", NS_MEDIA, &[1, 2, 3, 4]);
        let back = CastMessage::decode(&msg.encode()).expect("decode");
        assert_eq!(back.payload_binary.as_deref(), Some(&[1u8, 2, 3, 4][..]));
        assert!(back.payload_utf8.is_none());
    }

    #[test]
    fn request_ids_are_extracted_for_response_matching() {
        let msg = CastMessage::text(
            "s",
            DEFAULT_RECEIVER_ID,
            NS_MEDIA,
            r#"{"type":"GET_STATUS","requestId":42}"#,
        );
        assert_eq!(msg.request_id(), Some(42));
    }

    /// The **real** `RECEIVER_STATUS` volume shape: `level` and `muted` are
    /// nested under `status.volume`.
    ///
    /// This fixture is the one that matters. The earlier fixture spelled it
    /// flat — `"volume":0.45,"muted":true` — which the parser was written to
    /// match, so the suite passed against a shape the receiver never sends and
    /// every live read silently fell back to 100 / unmuted.
    #[test]
    fn receiver_volume_is_nested_under_status_volume() {
        let payload = r#"{"type":"RECEIVER_STATUS","requestId":1,"status":{
            "applications":[{"appId":"CC1AD845","sessionId":"s-1","transportId":"t-1"}],
            "volume":{"level":0.45,"muted":true,"controlType":"attenuation"},
            "isActiveInput":true}}"#;
        let s = parse_receiver_status(payload);
        assert_eq!(
            s.volume_level,
            Some(0.45),
            "level is nested under status.volume"
        );
        assert_eq!(
            s.volume_muted,
            Some(true),
            "muted is nested under status.volume"
        );
        assert_eq!(s.percent_volume(), 45.0);
    }

    /// A real payload whose volume is an **object** must not fall back to the
    /// 100.0 default. This is the specific miss that made every live run report
    /// 100 while the speakers were demonstrably moving.
    #[test]
    fn an_object_valued_volume_is_not_reported_as_full() {
        let payload =
            r#"{"type":"RECEIVER_STATUS","status":{"volume":{"level":0.10,"muted":false}}}"#;
        let s = parse_receiver_status(payload);
        assert!(
            s.volume_level.is_some(),
            "an object volume must still yield a level"
        );
        assert_eq!(s.percent_volume(), 10.0);
    }

    /// Same shape arriving as a list, which this receiver uses elsewhere.
    #[test]
    fn nested_volume_survives_the_list_status_shape() {
        let payload =
            r#"{"type":"RECEIVER_STATUS","status":[{"volume":{"level":0.30,"muted":true}}]}"#;
        let s = parse_receiver_status(payload);
        assert_eq!(s.volume_level, Some(0.30));
        assert_eq!(s.volume_muted, Some(true));
    }

    /// The flat spelling is still tolerated, so a receiver that flattens it is
    /// not reported as full volume.
    #[test]
    fn a_flat_volume_spelling_is_still_tolerated() {
        let s = parse_receiver_status(r#"{"status":{"volume":0.45,"muted":true}}"#);
        assert_eq!(s.volume_level, Some(0.45));
        assert_eq!(s.volume_muted, Some(true));
    }

    /// A receiver in genuinely standby reports no volume at all, and that must
    /// still read as full volume and unmuted rather than as a silent television.
    #[test]
    fn an_absent_volume_still_defaults_to_full_and_unmuted() {
        let s = parse_receiver_status(r#"{"status":{"isStandBy":true}}"#);
        assert_eq!(s.volume_level, None);
        assert_eq!(s.volume_muted, None);
        assert_eq!(s.percent_volume(), 100.0);
    }

    #[test]
    fn a_list_shaped_status_is_accepted_as_well_as_an_object() {
        // Google's docs specify an object; the DU7000 sends a list. Reading it
        // as an object yielded nothing, so a working cast reported `unknown`
        // with a zero position and no error at all.
        let listed = r#"{"type":"MEDIA_STATUS","status":[{"mediaSessionId":1,"playerState":"PLAYING","currentTime":7.5,"media":{"status":{"duration":100.0}}}],"requestId":0}"#;
        let parsed = parse_media_status(listed).expect("list-shaped status");
        assert_eq!(parsed.state, "playing");
        assert_eq!(parsed.position, 7.5);
        assert_eq!(parsed.duration, 100.0);

        // An empty list is what a receiver sends while idle.
        let idle = r#"{"type":"MEDIA_STATUS","status":[],"requestId":0}"#;
        assert!(status_object(&serde_json::from_str::<serde_json::Value>(idle).unwrap()).is_none());
        assert!(parse_media_status(idle).is_none());
    }

    #[test]
    fn media_status_maps_receiver_states_to_the_player_vocabulary() {
        let playing = parse_media_status(
            r#"{"type":"MEDIA_STATUS","status":{"playerState":"PLAYING","currentTime":12.5,"media":{"status":{"duration":8931.0}}}}"#,
        )
        .unwrap();
        assert_eq!(playing.state, "playing");
        assert_eq!(playing.position, 12.5);
        assert_eq!(
            playing.duration, 8931.0,
            "duration is read from the nested media status"
        );

        let idle = parse_media_status(r#"{"type":"MEDIA_STATUS","status":{"playerState":"IDLE"}}"#)
            .unwrap();
        assert_eq!(
            idle.state, "stopped",
            "IDLE means nothing is loaded, not stopped playback"
        );

        assert_eq!(
            parse_media_status(r#"{"type":"MEDIA_STATUS","status":{"playerState":"BUFFERING"}}"#)
                .unwrap()
                .state,
            "buffering"
        );
    }

    #[test]
    fn a_status_without_a_status_object_is_not_invented() {
        assert!(parse_media_status(r#"{"type":"INVALID_REQUEST"}"#).is_none());
        assert!(parse_media_status("not json").is_none());
    }

    #[test]
    fn buffered_stream_type_is_the_value_we_rely_on() {
        assert_eq!(STREAM_TYPE_BUFFERED, "BUFFERED");
        assert_ne!(
            STREAM_TYPE_BUFFERED, "LIVE",
            "LIVE tells the receiver the artifact is unseekable"
        );
    }
}
