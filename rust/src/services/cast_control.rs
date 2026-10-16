//! Cast LOAD and transport commands.
//!
//! Two details here are each the fix for a bug that was diagnosed against the
//! real receiver, and both are easy to regress:
//!
//! * **`streamType: BUFFERED`.** pychromecast defaults to `LIVE`, and a
//!   receiver told the stream is live treats the artifact as *unseekable*.
//!   That was "the TV ignores seeks" - both our own commands and a scrub from
//!   the phone.
//! * **`currentTime` inside the LOAD message.** A receiver has no media
//!   session for seconds after a load, and a `Seek` sent into that gap is
//!   rejected - observed as "Failed to execute seek 180.0" on the DU7000,
//!   which is how a resume cast silently started from the beginning.
//!
//! The media namespace is addressed to the *media* receiver, not `receiver-0`.
//! Sending a PLAY there is silently ignored.

use crate::services::cast_proto::{
    self, CastMessage, MediaTrack, TextTrackStyle, DEFAULT_RECEIVER_ID, NS_MEDIA, NS_RECEIVER,
};
use crate::services::cast_transport::CastConnection;
use serde::Serialize;
use serde_json::json;

pub const MEDIA_RECEIVER_ID: &str = cast_proto::MEDIA_RECEIVER_TRANSPORT_FALLBACK;

/// Containers a Cast receiver can play straight from the file.
pub const CAST_DIRECT_EXTENSIONS: [&str; 7] = [".mp4", ".m4v", ".webm", ".mov", ".mp3", ".m4a", ".aac"];

pub fn needs_hls(path: &std::path::Path) -> bool {
    // `Path::extension` yields "mp4", not ".mp4" - the table is dotted, so the
    // dot has to be restored before comparing or every container looks exotic
    // and every cast demands an HLS cache.
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| format!(".{}", e.to_lowercase()))
        .unwrap_or_default();
    !CAST_DIRECT_EXTENSIONS.contains(&ext.as_str())
}

/// A subtitle track offered to the receiver.
#[derive(Debug, Clone, Serialize)]
pub struct SubtitleTrack {
    pub track_id: i64,
    pub label: String,
    pub lang: String,
    /// Must be a fully-qualified URL: a receiver fetches this itself and
    /// cannot resolve a relative path.
    pub src: String,
}

impl SubtitleTrack {
    fn to_media_track(&self) -> MediaTrack {
        MediaTrack {
            track_id: self.track_id,
            track_content_id: self.src.clone(),
            language: if self.lang.is_empty() { "en".into() } else { self.lang.clone() },
            subtype: "SUBTITLES".into(),
            kind: "TEXT".into(),
            track_content_type: "text/vtt".into(),
            name: if self.label.is_empty() { format!("Subtitle {}", self.track_id) } else { self.label.clone() },
        }
    }
}

/// The receiver's current session id, needed by SEEK and STOP.
pub fn media_session_id(reply: &serde_json::Value) -> Option<i64> {
    reply
        .get("status")
        .and_then(|s| s.get("mediaSessionId"))
        .and_then(|v| v.as_i64())
}

pub async fn connect_and_handshake(host: &str) -> Result<CastConnection, String> {
    let mut conn = CastConnection::connect(host).await?;
    conn.connect_channel().await?;
    Ok(conn)
}

/// Ensure the default media receiver is actually running, and wait for it.
///
/// The media namespace has no session to address until the app exists, and a
/// LOAD sent while the app is still launching is declined - the receiver
/// answers with a `CLOSE` on the connection namespace instead. Measured: the
/// `LAUNCH_STATUS` ack and the `RECEIVER_STATUS` reply both arrive seconds
/// after the request, so "the launch was accepted" is not "the app is up".
/// Launch the default media receiver if needed and return its `transportId`.
///
/// The transport id is **not** optional bookkeeping. Each running application
/// gets its own virtual connection, and a media-namespace message sent without
/// one is refused: the receiver answers `LOAD` with a `CLOSE` on the
/// connection namespace. Connecting only to `receiver-0` is not enough - every
/// working client (VLC, pychromecast, go2tv) issues a second `CONNECT`
/// addressed to the launched application's `transportId` before it sends
/// `LOAD`.
pub async fn ensure_media_receiver_session(conn: &mut CastConnection) -> Result<String, String> {
    if let Some(transport) = receiver_app_transport(conn).await {
        return connect_app(conn, &transport).await.map(|_| transport);
    }

    let _ = conn
        .request(
            NS_RECEIVER,
            DEFAULT_RECEIVER_ID,
            json!({ "type": "LAUNCH", "appId": cast_proto::MEDIA_RECEIVER_APP_ID }),
        )
        .await;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        if let Some(transport) = receiver_app_transport(conn).await {
            return connect_app(conn, &transport).await.map(|_| transport);
        }
        if tokio::time::Instant::now() >= deadline {
            return Err("the Cast receiver did not start its media app".to_string());
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

/// Open a virtual connection to a launched application.
async fn connect_app(conn: &mut CastConnection, transport_id: &str) -> Result<(), String> {
    conn.send_raw(
        crate::services::cast_proto::NS_CONNECTION,
        transport_id,
        json!({ "type": "CONNECT", "origin": {} }),
    )
    .await
}

/// The `transportId` of the running default media receiver, if it is up.
///
/// Reported as `status.applications[].transportId` on this receiver and as
/// `status.transportId` on others; the running app id appears as
/// `status.appId` on some and under `applications[]` on others. Both layouts
/// are checked, because reading only one reports a working app as absent.
async fn receiver_app_transport(conn: &mut CastConnection) -> Option<String> {
    let reply = conn
        .request(NS_RECEIVER, DEFAULT_RECEIVER_ID, json!({ "type": "GET_STATUS" }))
        .await
        .ok()?;
    let status = reply.get("status")?;

    let running = status.get("appId").and_then(|v| v.as_str()) == Some(cast_proto::MEDIA_RECEIVER_APP_ID)
        || status
            .get("applications")
            .and_then(|v| v.as_array())
            .map(|apps| {
                apps.iter()
                    .any(|a| a.get("appId").and_then(|v| v.as_str()) == Some(cast_proto::MEDIA_RECEIVER_APP_ID))
            })
            .unwrap_or(false);
    if !running {
        return None;
    }

    status
        .get("transportId")
        .and_then(|v| v.as_str())
        .or_else(|| {
            status
                .get("applications")
                .and_then(|v| v.as_array())
                .and_then(|apps| {
                    apps.iter()
                        .find(|a| a.get("appId").and_then(|v| v.as_str()) == Some(cast_proto::MEDIA_RECEIVER_APP_ID))
                })
                .and_then(|a| a.get("transportId"))
                .and_then(|v| v.as_str())
        })
        .map(|s| s.to_string())
        .or(Some(MEDIA_RECEIVER_ID.to_string()))
}


/// Hand a URL to the receiver.
///
/// Detached rather than awaited: a load takes seconds while the receiver opens
/// the stream, and the route must answer immediately. Failures reach the
/// client through `status`'s `last_error` instead of leaving it stuck on
/// "starting".
pub async fn load(
    conn: &mut CastConnection,
    url: &str,
    title: &str,
    content_type: &str,
    position: Option<f64>,
    subtitles: &[SubtitleTrack],
    active_subtitle_id: Option<i64>,
) -> Result<(), String> {
    let transport_id = ensure_media_receiver_session(conn).await?;
    conn.set_app_transport(transport_id.clone());

    let mut media = json!({
        "contentId": url,
        // Not LIVE: a live stream is unseekable to the receiver.
        "streamType": cast_proto::STREAM_TYPE_BUFFERED,
        "contentType": content_type,
        "metadata": { "metadataType": 0, "title": title },
    });

    if !subtitles.is_empty() {
        media["tracks"] = json!(subtitles.iter().map(|s| s.to_media_track()).collect::<Vec<_>>());
        media["textTrackStyle"] = serde_json::to_value(TextTrackStyle::default())
            .map_err(|e| e.to_string())?;
    }

    // `currentTime` is a **top-level** member of LOAD, a sibling of `media`:
    //
    //   | media       | MediaInformation | ...
    //   | autoplay    | boolean | optional
    //   | currentTime | double  | optional  Seconds since beginning of content.
    //
    // Nesting it inside `media` - where it looks more natural - is silently
    // ignored, and the cast starts from the beginning. That is the whole of
    // "resume playback always starts over", and it survives a green test suite
    // because nothing errors: the receiver accepts the LOAD and plays.
    let mut load = json!({ "type": "LOAD", "media": media, "autoplay": true });
    if let Some(pos) = position.filter(|p| *p > 0.0) {
        load["currentTime"] = json!(pos);
    }

    conn.request(NS_MEDIA, &transport_id, load).await.map(|_| ())?;

    if let Some(track_id) = active_subtitle_id.filter(|t| *t > 0) {
        // The receiver may still be opening the session; this is best-effort.
        let _ = select_subtitle(conn, track_id).await;
    }
    Ok(())
}

async fn media_command(
    conn: &mut CastConnection,
    message: serde_json::Value,
) -> Result<serde_json::Value, String> {
    // Addressed at the app's real transport id, which is a per-session UUID.
    let transport = conn.app_transport().to_string();
    conn.request(NS_MEDIA, &transport, message).await
}

/// Wait, bounded, for a media session to exist.
///
/// Commands sent into the gap between LOAD and the session being active are
/// rejected. The wait is bounded so a device that never starts still answers.
pub async fn wait_for_session(conn: &mut CastConnection) -> Option<i64> {
    let deadline = tokio::time::Instant::now() + cast_proto::SESSION_WAIT;
    loop {
        if let Ok(reply) = media_command(conn, json!({ "type": "GET_STATUS" })).await {
            if let Some(id) = media_session_id(&reply) {
                return Some(id);
            }
        }
        if tokio::time::Instant::now() >= deadline {
            return None;
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
}

pub async fn play(conn: &mut CastConnection) -> Result<(), String> {
    let session = wait_for_session(conn).await;
    let mut msg = json!({ "type": "PLAY" });
    if let Some(id) = session {
        msg["mediaSessionId"] = json!(id);
    }
    media_command(conn, msg).await.map(|_| ())
}

pub async fn pause(conn: &mut CastConnection) -> Result<(), String> {
    let session = wait_for_session(conn).await;
    let mut msg = json!({ "type": "PAUSE" });
    if let Some(id) = session {
        msg["mediaSessionId"] = json!(id);
    }
    media_command(conn, msg).await.map(|_| ())
}

pub async fn seek(conn: &mut CastConnection, seconds: f64) -> Result<(), String> {
    let session = wait_for_session(conn).await.ok_or_else(|| {
        "the receiver has no media session yet - start playback first".to_string()
    })?;
    media_command(
        conn,
        json!({
            "type": "SEEK",
            "mediaSessionId": session,
            "currentTime": seconds.max(0.0),
            "resumeState": "PLAYBACK_START",
        }),
    )
    .await
    .map(|_| ())
}

pub async fn stop_media(conn: &mut CastConnection) -> Result<(), String> {
    let session = wait_for_session(conn).await;
    let mut msg = json!({ "type": "STOP" });
    if let Some(id) = session {
        msg["mediaSessionId"] = json!(id);
    }
    media_command(conn, msg).await.map(|_| ())
}

/// Leave the receiver on its home screen.
///
/// Stopping playback alone leaves the default media receiver running as an
/// idle blank screen on the television, which reads as a hang.
pub async fn quit_app(conn: &mut CastConnection) -> Result<(), String> {
    conn.send(NS_RECEIVER, DEFAULT_RECEIVER_ID, json!({ "type": "STOP_APP" }))
        .await
}

pub async fn set_volume(conn: &mut CastConnection, percent: f64) -> Result<(), String> {
    let level = (percent / 100.0).clamp(0.0, 1.0);
    conn.send(
        NS_RECEIVER,
        DEFAULT_RECEIVER_ID,
        json!({ "type": "SET_VOLUME", "volume": { "level": level } }),
    )
    .await
}

pub async fn set_muted(conn: &mut CastConnection, muted: bool) -> Result<(), String> {
    conn.send(
        NS_RECEIVER,
        DEFAULT_RECEIVER_ID,
        json!({ "type": "SET_VOLUME_MUTED", "volume": { "muted": muted } }),
    )
    .await
}

/// Select or clear a subtitle track. `track_id` 0 means "no subtitles".
pub async fn select_subtitle(conn: &mut CastConnection, track_id: i64) -> Result<(), String> {
    let session = wait_for_session(conn).await;
    let active = if track_id > 0 { vec![track_id] } else { Vec::new() };
    let mut msg = json!({
        "type": "EDIT_TRACKS_INFO",
        "activeTrackIds": active,
    });
    if let Some(id) = session {
        msg["mediaSessionId"] = json!(id);
    }
    media_command(conn, msg).await.map(|_| ())
}

/// Ask the receiver, rather than trusting a cached push.
///
/// A receiver sends `MEDIA_STATUS` on transitions only - measured minutes
/// apart while playing - so a cached read freezes the cast bar and can make a
/// position from minutes ago look like a command that never landed.
pub async fn status(conn: &mut CastConnection) -> (serde_json::Value, serde_json::Value) {
    let media = media_command(conn, json!({ "type": "GET_STATUS" }))
        .await
        .unwrap_or(serde_json::Value::Null);
    let receiver = conn
        .request(NS_RECEIVER, DEFAULT_RECEIVER_ID, json!({ "type": "GET_STATUS" }))
        .await
        .unwrap_or(serde_json::Value::Null);
    (media, receiver)
}

/// Turn the receiver's answers into the shape the players already consume.
pub fn status_payload(media: &serde_json::Value, receiver: &serde_json::Value) -> serde_json::Value {
    let volume = cast_proto::parse_receiver_status(&receiver.to_string());

    // `status` is an object per the docs but a list on some receivers.
    let player_state = cast_proto::media_status_object(media)
        .and_then(|s| s.get("playerState"))
        .and_then(|v| v.as_str());

    let mut state = player_state
        .map(|raw| {
            match raw.to_uppercase().as_str() {
                "PLAYING" => "playing".to_string(),
                "PAUSED" => "paused".to_string(),
                "BUFFERING" => "buffering".to_string(),
                "IDLE" => "stopped".to_string(),
                "" => "unknown".to_string(),
                other => other.to_string(),
            }
        })
        .unwrap_or_else(|| "unknown".to_string());

    // A receiver that is starting has no playerState yet, but it does have the
    // media receiver app running. Reporting "unknown" there leaves the phone
    // looking broken while the cast is in fact opening.
    if state == "unknown" {
        let app_running = receiver
            .get("status")
            .map(|s| {
                s.get("appId").is_some()
                    || s.get("applications")
                        .and_then(|v| v.as_array())
                        .map(|a| !a.is_empty())
                        .unwrap_or(false)
            })
            .unwrap_or(false);
        if app_running {
            state = "buffering".to_string();
        }
    }

    let parsed = cast_proto::parse_media_status(&media.to_string());

    json!({
        "state": state,
        "position": parsed.as_ref().map(|p| p.position).unwrap_or(0.0),
        "duration": parsed.as_ref().map(|p| p.duration).unwrap_or(0.0),
        // Defaults to 100: a receiver in standby reports no volume at all, and
        // inventing 0 would tell the user their television is muted.
        "volume": volume.percent_volume(),
        "muted": volume.volume_muted.unwrap_or(false),
    })
}

/// Frame helper kept for symmetry with the proto module's public surface.
pub fn load_message(url: &str, title: &str, content_type: &str) -> CastMessage {
    CastMessage::text(
        "sender-preview",
        MEDIA_RECEIVER_ID,
        NS_MEDIA,
        &json!({ "type": "LOAD", "url": url, "title": title, "contentType": content_type }).to_string(),
    )
}

use std::time::Duration;

#[cfg(test)]
mod tests {
    use super::*;

    /// What does a receiver actually answer to a LOAD?
    ///
    /// Gated the same way as the handshake test. This exists because
    /// correlating a reply by `requestId` is correct but unforgiving: a
    /// receiver that answers with a different id, or on a different namespace,
    /// then looks exactly like one that never answered. Draining every frame
    /// shows the real behaviour instead of guessing at it.
    #[tokio::test]
    async fn live_load_diagnostic() {
        if std::env::var("MEDIA_SERVER_CAST_LIVE_TESTS").is_err() {
            eprintln!("SKIPPED live_load_diagnostic");
            return;
        }
        let host = match std::env::var("MEDIA_SERVER_CAST_LIVE_HOST") {
            Ok(h) if !h.is_empty() => h,
            _ => {
                eprintln!("SKIPPED live_load_diagnostic (MEDIA_SERVER_CAST_LIVE_HOST not set)");
                return;
            }
        };
        let url = std::env::var("MEDIA_SERVER_CAST_LIVE_URL").unwrap_or_default();
        if url.is_empty() {
            eprintln!("SKIPPED live_load_diagnostic (MEDIA_SERVER_CAST_LIVE_URL not set)");
            return;
        }

        let mut conn = connect_and_handshake(&host).await.expect("handshake");
        let after_connect = conn.drain(Duration::from_millis(800)).await;
        eprintln!("DIAG after CONNECT: {}", describe(&after_connect));

        let transport = ensure_media_receiver_session(&mut conn)
            .await
            .expect("media receiver session");
        eprintln!("DIAG media receiver transportId={}", transport);

        conn.send_raw(
            crate::services::cast_proto::NS_MEDIA,
            &transport,
            json!({
                "type": "LOAD",
                "requestId": 77,
                "autoplay": true,
                "media": {
                    "contentId": url,
                    "streamType": "BUFFERED",
                    "contentType": "video/mp4",
                    "metadata": { "metadataType": 0, "title": "diag" }
                }
            }),
        )
        .await
        .expect("send LOAD");

        for msg in conn.drain(Duration::from_secs(8)).await {
            eprintln!(
                "DIAG frame ns={} type={:?} requestId={:?} payload={}",
                msg.namespace,
                msg.message_type(),
                msg.request_id(),
                msg.text_payload().unwrap_or("<binary>")
            );
        }
        conn.close().await;
    }

    fn describe(frames: &[crate::services::cast_proto::CastMessage]) -> String {
        if frames.is_empty() {
            return "<none>".into();
        }
        frames
            .iter()
            .map(|m| format!("{}/{:?}", m.namespace, m.message_type()))
            .collect::<Vec<_>>()
            .join(", ")
    }

    #[test]
    fn a_resume_position_is_a_sibling_of_media_not_a_member() {
        // Per the LOAD message spec, `currentTime` sits beside `media`.
        // Nested inside it, the receiver accepts the LOAD, plays happily from
        // zero and reports no error - so this is the exact shape that makes
        // "resume playback" silently restart.
        let load = json!({
            "type": "LOAD",
            "autoplay": true,
            "currentTime": 600.0,
            "media": { "contentId": "http://h/m.mp4" }
        });
        assert_eq!(load["currentTime"], 600.0);
        assert!(load["media"].get("currentTime").is_none());

        let nested = json!({
            "type": "LOAD",
            "media": { "contentId": "http://h/m.mp4", "currentTime": 600.0 }
        });
        assert!(
            nested.get("currentTime").is_none(),
            "a nested currentTime is the shape the receiver ignores"
        );
    }

    #[test]
    fn direct_containers_do_not_need_transcoding() {
        for name in ["a.mp4", "a.M4V", "a.webm", "a.MOV", "a.mp3"] {
            assert!(!needs_hls(std::path::Path::new(name)), "{}", name);
        }
    }

    #[test]
    fn matroska_needs_an_hls_cache_to_cast() {
        assert!(needs_hls(std::path::Path::new("a.mkv")));
        assert!(needs_hls(std::path::Path::new("a.avi")));
        assert!(needs_hls(std::path::Path::new("noext")));
    }

    #[test]
    fn subtitle_tracks_become_text_vtt_tracks() {
        let t = SubtitleTrack {
            track_id: 2,
            label: "English".into(),
            lang: "en".into(),
            src: "http://192.168.1.16:8001/subtitles/x.vtt".into(),
        };
        let media = t.to_media_track();
        assert_eq!(media.track_id, 2);
        assert_eq!(media.subtype, "SUBTITLES");
        assert_eq!(media.kind, "TEXT");
        assert_eq!(media.track_content_type, "text/vtt");
        assert!(media.track_content_id.starts_with("http://"), "a receiver cannot resolve a relative path");
    }

    #[test]
    fn a_blank_label_gets_a_generated_name() {
        let t = SubtitleTrack { track_id: 3, label: String::new(), lang: String::new(), src: "http://h/x.vtt".into() };
        let media = t.to_media_track();
        assert_eq!(media.name, "Subtitle 3");
        assert_eq!(media.language, "en", "a blank language must not be sent as empty");
    }

    #[test]
    fn a_standby_receiver_reports_full_volume_not_zero() {
        let media = serde_json::json!({});
        let receiver = serde_json::json!({
            "type": "RECEIVER_STATUS",
            "status": { "isActiveInput": false, "isStandby": true }
        });
        let payload = status_payload(&media, &receiver);
        assert_eq!(payload["volume"], 100.0, "no volume field must not read as muted");
        assert_eq!(payload["muted"], false);
    }

    #[test]
    fn playing_status_is_reported_from_the_receiver() {
        let media = serde_json::json!({
            "type": "MEDIA_STATUS",
            "status": {
                "playerState": "PLAYING",
                "mediaSessionId": 1,
                "currentTime": 42.5,
                "media": { "status": { "duration": 8931.0 } }
            }
        });
        let receiver = serde_json::json!({
            "type": "RECEIVER_STATUS",
            "status": { "volume": 0.3, "muted": false, "isActiveInput": true }
        });
        let payload = status_payload(&media, &receiver);
        assert_eq!(payload["state"], "playing");
        assert_eq!(payload["position"], 42.5);
        assert_eq!(payload["duration"], 8931.0);
        assert_eq!(payload["volume"], 30.0);
    }

    #[test]
    fn idle_maps_to_stopped_not_unknown() {
        let media = serde_json::json!({ "status": { "playerState": "IDLE" } });
        let receiver = serde_json::json!({ "status": { "isActiveInput": true } });
        assert_eq!(status_payload(&media, &receiver)["state"], "stopped");
    }

    #[test]
    fn media_commands_address_the_media_receiver_not_receiver_zero() {
        assert_eq!(MEDIA_RECEIVER_ID, "urn:x-cast:com.google.cast.media-receiver");
        assert_ne!(
            MEDIA_RECEIVER_ID, DEFAULT_RECEIVER_ID,
            "a PLAY addressed to receiver-0 is silently ignored"
        );
    }

    #[test]
    fn a_session_id_is_read_from_a_status_reply() {
        let reply = serde_json::json!({ "status": { "mediaSessionId": 7 } });
        assert_eq!(media_session_id(&reply), Some(7));
        assert_eq!(media_session_id(&serde_json::json!({ "status": {} })), None);
    }
}
