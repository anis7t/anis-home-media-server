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
pub const CAST_DIRECT_EXTENSIONS: [&str; 7] =
    [".mp4", ".m4v", ".webm", ".mov", ".mp3", ".m4a", ".aac"];

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
            language: if self.lang.is_empty() {
                "en".into()
            } else {
                self.lang.clone()
            },
            subtype: "SUBTITLES".into(),
            kind: "TEXT".into(),
            track_content_type: "text/vtt".into(),
            name: if self.label.is_empty() {
                format!("Subtitle {}", self.track_id)
            } else {
                self.label.clone()
            },
        }
    }
}

/// The receiver's current session id, needed by SEEK and STOP.
/// The receiver's current session id, needed by SEEK and STOP.
///
/// Goes through [`cast_proto::status_object`] like every other reader of
/// `MEDIA_STATUS`. It originally read `status` as an object, so on a receiver
/// that sends a list it found nothing - and `seek` failed with "no media
/// session yet" on a cast that was demonstrably playing, because the session
/// existed and was simply invisible to the parser.
pub fn media_session_id(reply: &serde_json::Value) -> Option<i64> {
    cast_proto::status_object(reply)
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
        .request(
            NS_RECEIVER,
            DEFAULT_RECEIVER_ID,
            json!({ "type": "GET_STATUS" }),
        )
        .await
        .ok()?;
    let status = cast_proto::status_object(&reply)?;

    let running = status.get("appId").and_then(|v| v.as_str())
        == Some(cast_proto::MEDIA_RECEIVER_APP_ID)
        || status
            .get("applications")
            .and_then(|v| v.as_array())
            .map(|apps| {
                apps.iter().any(|a| {
                    a.get("appId").and_then(|v| v.as_str())
                        == Some(cast_proto::MEDIA_RECEIVER_APP_ID)
                })
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
                    apps.iter().find(|a| {
                        a.get("appId").and_then(|v| v.as_str())
                            == Some(cast_proto::MEDIA_RECEIVER_APP_ID)
                    })
                })
                .and_then(|a| a.get("transportId"))
                .and_then(|v| v.as_str())
        })
        .map(|s| s.to_string())
        .or(Some(MEDIA_RECEIVER_ID.to_string()))
}

/// The `sessionId` of the running media receiver app.
///
/// Sits in the same `applications[]` entry as `transportId`, and is what
/// pychromecast sends with the quit-app message:
///
/// ```python
/// {MESSAGE_TYPE: "STOP"}, inc_session_id=True   # -> data["sessionId"] = status.session_id
/// ```
///
/// `None` when no media receiver is running, when the receiver omits it, or
/// when the status request fails - the three are deliberately indistinguishable,
/// because none of them should stop us sending the quit.
async fn receiver_app_session_id(conn: &mut CastConnection) -> Option<String> {
    let reply = conn
        .request(
            NS_RECEIVER,
            DEFAULT_RECEIVER_ID,
            json!({ "type": "GET_STATUS" }),
        )
        .await
        .ok()?;
    let status = cast_proto::status_object(&reply)?;

    status
        .get("sessionId")
        .and_then(|v| v.as_str())
        .or_else(|| {
            status
                .get("applications")
                .and_then(|v| v.as_array())
                .and_then(|apps| {
                    apps.iter().find(|a| {
                        a.get("appId").and_then(|v| v.as_str())
                            == Some(cast_proto::MEDIA_RECEIVER_APP_ID)
                    })
                })
                .and_then(|a| a.get("sessionId"))
                .and_then(|v| v.as_str())
        })
        .map(|s| s.to_string())
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
        media["tracks"] = json!(subtitles
            .iter()
            .map(|s| s.to_media_track())
            .collect::<Vec<_>>());
        media["textTrackStyle"] =
            serde_json::to_value(TextTrackStyle::default()).map_err(|e| e.to_string())?;
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

    conn.request(NS_MEDIA, &transport_id, load)
        .await
        .map(|_| ())?;

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
/// Stopping playback alone leaves the default media receiver running as an idle
/// blank screen with a cast icon on it, which reads as a hang.
///
/// The message is **`STOP`, not `STOP_APP`, and it carries `sessionId`.**
/// pychromecast, which backs the working Flask path, sends exactly:
///
/// ```python
/// self.send_message({MESSAGE_TYPE: "STOP"}, inc_session_id=True)
/// # socket_client.send_message then does: data["sessionId"] = self.session_id
/// ```
///
/// `STOP_APP` does not exist. The receiver accepts it, answers, reports
/// `ok: true`, and leaves the app running - the television keeps sitting on the
/// blank screen while every layer above reports success. It is the same failure
/// shape as `SET_VOLUME_MUTED`: a message type taken from intuition rather than
/// from a working client, accepted-and-ignored rather than rejected.
///
/// The `sessionId` comes from `applications[].sessionId` in `RECEIVER_STATUS`,
/// the same entry that carries `transportId`. It is included only when we
/// actually have one.
///
/// This **awaits the receiver's reply**. It used to be fire-and-forget, and the
/// caller then closed the socket immediately - so the receiver had no chance to
/// process the message before the transport went away.
pub async fn quit_app(conn: &mut CastConnection) -> Result<(), String> {
    let session_id = receiver_app_session_id(conn).await;
    conn.request(
        NS_RECEIVER,
        DEFAULT_RECEIVER_ID,
        quit_app_payload(session_id.as_deref()),
    )
    .await
    .map(|_| ())
}

/// The exact quit-app message, separated so the wire shape can be pinned.
///
/// Two independent mistakes are guarded here, and both were invisible at
/// runtime because the receiver answers a message it does not understand with
/// success. Asserting on the ack would have passed for both.
fn quit_app_payload(session_id: Option<&str>) -> serde_json::Value {
    let mut payload = json!({ "type": "STOP" });
    if let Some(sid) = session_id {
        payload["sessionId"] = json!(sid);
    }
    payload
}

/// Is the media receiver app still running?
pub async fn media_receiver_still_running(conn: &mut CastConnection) -> bool {
    receiver_app_transport(conn).await.is_some()
}

/// Wait, briefly, for the media app to actually go away.
///
/// Bounded: a receiver that keeps the app alive is a condition to report, not
/// a reason to hang the request.
pub async fn wait_for_app_gone(conn: &mut CastConnection, timeout: Duration) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if !media_receiver_still_running(conn).await {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(400)).await;
    }
}

/// Set the volume.
///
/// Sent on the **receiver** namespace as a platform/master volume, which is
/// what moves a television's speakers and raises its on-screen volume
/// indicator. Verified against this host's own receiver: the React/Flask
/// implementation used this namespace and visibly worked.
///
/// An earlier version moved this to the media namespace with a
/// `mediaSessionId`, reasoning that the session volume was the one the user
/// hears. That was wrong here. The receiver **echoed** the session value back,
/// so a test asserting on the reported value passed while the television's
/// volume never moved - the report described a value the app stored, not the
/// volume being played. A receiver will confirm a value it has not applied to
/// its output, so "the receiver says so" is not evidence that anyone can hear
/// it.
pub async fn set_volume(conn: &mut CastConnection, percent: f64) -> Result<(), String> {
    let level = (percent / 100.0).clamp(0.0, 1.0);
    conn.request(
        NS_RECEIVER,
        DEFAULT_RECEIVER_ID,
        json!({ "type": "SET_VOLUME", "volume": { "level": level } }),
    )
    .await
    .map(|_| ())
}

/// Mute the receiver's output.
///
/// The message type is **`SET_VOLUME` with a `muted` field** — there is no
/// `SET_VOLUME_MUTED`. pychromecast, which is what the working Flask path used:
///
/// ```python
/// self.send_message({MESSAGE_TYPE: "SET_VOLUME", "volume": {"muted": muted}})
/// ```
///
/// Sending `{"type": "SET_VOLUME_MUTED", ...}` is accepted with `ok: true`
/// and does nothing at all, because the receiver does not recognise the type.
/// That is not a guess: it is what the message looked like when mute silently
/// failed on this television while volume worked on the same connection.
pub async fn set_muted(conn: &mut CastConnection, muted: bool) -> Result<(), String> {
    conn.request(
        NS_RECEIVER,
        DEFAULT_RECEIVER_ID,
        json!({ "type": "SET_VOLUME", "volume": { "muted": muted } }),
    )
    .await
    .map(|_| ())
}

/// Select or clear a subtitle track. `track_id` 0 means "no subtitles".
pub async fn select_subtitle(conn: &mut CastConnection, track_id: i64) -> Result<(), String> {
    let session = wait_for_session(conn).await;
    let active = if track_id > 0 {
        vec![track_id]
    } else {
        Vec::new()
    };
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
        .request(
            NS_RECEIVER,
            DEFAULT_RECEIVER_ID,
            json!({ "type": "GET_STATUS" }),
        )
        .await
        .unwrap_or(serde_json::Value::Null);
    (media, receiver)
}

/// Turn the receiver's answers into the shape the players already consume.
pub fn status_payload(
    media: &serde_json::Value,
    receiver: &serde_json::Value,
) -> serde_json::Value {
    // `status` is an object per the docs but a list on some receivers, and it is
    // an EMPTY list while nothing is loaded.
    let status_obj = cast_proto::status_object(media);
    let player_state = status_obj
        .and_then(|s| s.get("playerState"))
        .and_then(|v| v.as_str());

    // No player state at all means nothing is loaded. The receiver reports
    // BUFFERING explicitly while it opens a stream, so inferring "buffering"
    // from "the app is running" is unnecessary - and actively wrong: it left a
    // finished cast showing "buffering" forever, because an app that is
    // running with nothing playing is stopped, not starting.
    let state = match player_state {
        Some(raw) => match raw.to_uppercase().as_str() {
            "PLAYING" => "playing".to_string(),
            "PAUSED" => "paused".to_string(),
            "BUFFERING" => "buffering".to_string(),
            "IDLE" => "stopped".to_string(),
            "" => "stopped".to_string(),
            other => other.to_string(),
        },
        None => "stopped".to_string(),
    };

    // Whether the media receiver app is still up. Media status cannot see this: a
    // quit app reports an empty status, and one left running also reports an
    // empty status - the difference is only in the receiver's application list.
    // Without it, "stopped but the television is showing a blank receiver
    // screen" is indistinguishable from a clean stop.
    let receiver_app_running = cast_proto::status_object(receiver)
        .map(|s| {
            s.get("appId").is_some()
                || s.get("applications")
                    .and_then(|v| v.as_array())
                    .map(|a| !a.is_empty())
                    .unwrap_or(false)
        })
        .unwrap_or(false);

    // The platform volume: `status.volume.level` and `status.volume.muted` in
    // `RECEIVER_STATUS`, the same values the working Flask path reports from
    // `cast.status.volume_level`. This is a real field holding a real level.
    //
    // An earlier version read `status.volume` as a scalar, missed the nested
    // `volume.level` on every call, and returned the 100.0 fallback — which
    // looked exactly like "the protocol does not expose the speaker volume"
    // while the television's speakers moved. The media status does also carry a
    // per-session volume, and that one is a value the app stores rather than the
    // volume being played, so the receiver's copy is the one reported.
    let volume = cast_proto::parse_receiver_status(&receiver.to_string());

    let parsed = cast_proto::parse_media_status(&media.to_string());

    json!({
        "state": state,
        "position": parsed.as_ref().map(|p| p.position).unwrap_or(0.0),
        "duration": parsed.as_ref().map(|p| p.duration).unwrap_or(0.0),
        // Defaults to 100: a receiver in standby reports no volume at all, and
        // inventing 0 would tell the user their television is muted.
        "volume": volume.percent_volume(),
        "muted": volume.volume_muted.unwrap_or(false),
        "receiver_app_running": receiver_app_running,
    })
}

/// Frame helper kept for symmetry with the proto module's public surface.
pub fn load_message(url: &str, title: &str, content_type: &str) -> CastMessage {
    CastMessage::text(
        "sender-preview",
        MEDIA_RECEIVER_ID,
        NS_MEDIA,
        &json!({ "type": "LOAD", "url": url, "title": title, "contentType": content_type })
            .to_string(),
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
    fn receiver_volume_survives_either_status_shape() {
        use crate::services::cast_proto::parse_receiver_status;
        let object = r#"{"type":"RECEIVER_STATUS","status":{"volume":0.25,"muted":true}}"#;
        let listed = r#"{"type":"RECEIVER_STATUS","status":[{"volume":0.25,"muted":true}]}"#;
        assert_eq!(parse_receiver_status(object).volume_level, Some(0.25));
        assert_eq!(parse_receiver_status(listed).volume_level, Some(0.25));
        assert_eq!(parse_receiver_status(listed).volume_muted, Some(true));
    }

    #[test]
    fn a_session_id_is_found_in_either_status_shape() {
        // The second shape is the bug this whole refactor exists to prevent:
        // `media_session_id` read `status` as an object, so on this receiver it
        // found nothing and `seek` refused a cast that was plainly playing.
        let object =
            serde_json::json!({ "status": { "mediaSessionId": 3, "playerState": "PLAYING" } });
        let listed =
            serde_json::json!({ "status": [{ "mediaSessionId": 3, "playerState": "PLAYING" }] });
        assert_eq!(media_session_id(&object), Some(3));
        assert_eq!(media_session_id(&listed), Some(3));
        assert_eq!(media_session_id(&serde_json::json!({ "status": [] })), None);
    }

    #[test]
    fn an_ended_cast_reports_stopped_not_buffering() {
        // An app that is running with nothing playing is stopped. Inferring
        // "buffering" from "the app is running" left a finished cast showing
        // buffering forever - and made the verification harness report a
        // still-playing television that was in fact idle.
        let idle = serde_json::json!({ "type": "MEDIA_STATUS", "status": [] });
        let receiver = serde_json::json!({
            "type": "RECEIVER_STATUS",
            "status": { "appId": "CC1AD845", "isActiveInput": true }
        });
        let payload = status_payload(&idle, &receiver);
        assert_eq!(payload["state"], "stopped");
        assert_eq!(payload["position"], 0.0);

        // A receiver that says BUFFERING explicitly is still honoured.
        let buffering = serde_json::json!({ "status": [{ "playerState": "BUFFERING" }] });
        assert_eq!(status_payload(&buffering, &receiver)["state"], "buffering");
    }

    #[test]
    fn an_ended_cast_reports_stopped_and_not_running() {
        // The blank-screen bug: the media app can still be running with nothing
        // playing. Media status alone cannot see it - only the receiver's
        // application list can.
        let idle = serde_json::json!({ "type": "MEDIA_STATUS", "status": [] });
        let app_still_up = serde_json::json!({
            "type": "RECEIVER_STATUS",
            "status": { "appId": "CC1AD845", "applications": [{ "appId": "CC1AD845" }] }
        });
        let payload = status_payload(&idle, &app_still_up);
        assert_eq!(payload["state"], "stopped");
        assert_eq!(
            payload["receiver_app_running"], true,
            "a stopped cast whose app is still up must be visible, or the \
             television looks idle while showing a blank receiver screen"
        );

        let app_gone = serde_json::json!({
            "type": "RECEIVER_STATUS",
            "status": { "isActiveInput": false, "applications": [] }
        });
        assert_eq!(
            status_payload(&idle, &app_gone)["receiver_app_running"],
            false
        );
    }

    #[test]
    fn the_platform_volume_is_reported_because_that_is_the_audible_one() {
        // The receiver (platform) volume wins over the media session's own.
        // Fixtures use the REAL nested payload shape: `volume.level` and
        // `volume.muted` under `status.volume`.
        let media = serde_json::json!({
            "status": [{ "playerState": "PLAYING", "volume": { "level": 0.4, "muted": true } }]
        });
        let receiver = serde_json::json!({
            "type": "RECEIVER_STATUS",
            "status": {
                "applications": [{ "appId": "CC1AD845", "sessionId": "s-1", "transportId": "t-1" }],
                "volume": { "level": 0.3, "muted": false, "controlType": "attenuation" },
                "isActiveInput": true
            }
        });
        let payload = status_payload(&media, &receiver);
        assert_eq!(
            payload["volume"], 30.0,
            "the reported volume is the audible one"
        );
        assert_eq!(payload["muted"], false);
    }

    /// The regression that made `status.volume` look permanently 100.
    ///
    /// Every live run reported 100.0 while the speakers moved, and that was
    /// written off as "the protocol does not expose the speaker volume". It
    /// does: the parser was reading `status.volume` as a scalar, missing the
    /// nested `volume.level`, and returning the 100.0 fallback every time. The
    /// unit test passed because its fixture had the same wrong shape.
    #[test]
    fn a_real_receiver_status_reports_its_actual_volume() {
        let media = serde_json::json!({ "status": [{ "playerState": "PLAYING" }] });
        let receiver = serde_json::json!({
            "type": "RECEIVER_STATUS",
            "status": { "volume": { "level": 0.2, "muted": true }, "isActiveInput": true }
        });
        let payload = status_payload(&media, &receiver);
        assert_eq!(
            payload["volume"], 20.0,
            "the receiver's real volume, not the 100 fallback"
        );
        assert_eq!(payload["muted"], true, "the receiver's real mute state");
    }

    /// Mute on this receiver is observable after all — the field reads `true`
    /// once it is read from the right path.
    #[test]
    fn mute_state_is_reported_from_the_receiver() {
        let media = serde_json::json!({ "status": [{ "playerState": "PLAYING" }] });
        let unmuted = serde_json::json!({
            "type": "RECEIVER_STATUS",
            "status": { "volume": { "level": 0.5, "muted": false }, "isActiveInput": true }
        });
        let muted = serde_json::json!({
            "type": "RECEIVER_STATUS",
            "status": { "volume": { "level": 0.5, "muted": true }, "isActiveInput": true }
        });
        assert_eq!(status_payload(&media, &unmuted)["muted"], false);
        assert_eq!(status_payload(&media, &muted)["muted"], true);
    }

    /// How long does the television actually take to clear the receiver screen?
    ///
    /// The API reports `app_running=false` promptly, yet the screen can still be
    /// showing. "Gone from the receiver's application list" and "cleared from the
    /// television" may be different events, and guessing between them wastes a
    /// restart each time.
    ///
    /// This deliberately does **not** send the connection `CLOSE` that the API
    /// sends on teardown, so the two can be compared. Gated like the other live
    /// checks.
    #[tokio::test]
    async fn live_teardown_timeline() {
        if std::env::var("MEDIA_SERVER_CAST_LIVE_TESTS").is_err() {
            eprintln!("SKIPPED live_teardown_timeline");
            return;
        }
        let host = match std::env::var("MEDIA_SERVER_CAST_LIVE_HOST") {
            Ok(h) if !h.is_empty() => h,
            _ => {
                eprintln!("SKIPPED live_teardown_timeline (MEDIA_SERVER_CAST_LIVE_HOST not set)");
                return;
            }
        };
        let url = std::env::var("MEDIA_SERVER_CAST_LIVE_URL").unwrap_or_default();
        if url.is_empty() {
            eprintln!("SKIPPED live_teardown_timeline (MEDIA_SERVER_CAST_LIVE_URL not set)");
            return;
        }

        let mut conn = connect_and_handshake(&host).await.expect("handshake");
        let transport = ensure_media_receiver_session(&mut conn)
            .await
            .expect("session");
        conn.set_app_transport(transport);
        load(
            &mut conn,
            &url,
            "teardown",
            "video/mp4",
            Some(600.0),
            &[],
            None,
        )
        .await
        .expect("load");
        tokio::time::sleep(Duration::from_secs(8)).await;
        eprintln!(
            "TL playing; app running = {}",
            media_receiver_still_running(&mut conn).await
        );

        let t0 = std::time::Instant::now();
        let _ = stop_media(&mut conn).await;
        eprintln!("TL +{:.1}s  STOP media sent", t0.elapsed().as_secs_f64());
        let _ = quit_app(&mut conn).await;
        eprintln!(
            "TL +{:.1}s  STOP (+sessionId) sent (no CLOSE sent)",
            t0.elapsed().as_secs_f64()
        );

        // Poll every second for 25s and print when the app leaves the receiver.
        for i in 1..=25 {
            tokio::time::sleep(Duration::from_secs(1)).await;
            let still = media_receiver_still_running(&mut conn).await;
            eprintln!(
                "TL +{:.1}s  app_running={}",
                t0.elapsed().as_secs_f64(),
                still
            );
            if !still && i > 1 {
                break;
            }
        }
        conn.close().await;
    }

    /// The quit-app message is `STOP` carrying `sessionId`, matching
    /// pychromecast. `STOP_APP` is not a real message type: the receiver
    /// accepts it, answers, and leaves the app running on its blank screen.
    #[test]
    fn quit_app_sends_stop_with_the_session_id() {
        assert_eq!(
            quit_app_payload(Some("sess-abc")),
            serde_json::json!({ "type": "STOP", "sessionId": "sess-abc" })
        );
    }

    /// With no session id the message is still `STOP`. It is never downgraded
    /// to a type the receiver will silently ignore.
    #[test]
    fn quit_app_without_a_session_id_is_still_stop() {
        assert_eq!(
            quit_app_payload(None),
            serde_json::json!({ "type": "STOP" })
        );
    }

    /// Guards the specific regression: the invented message type.
    #[test]
    fn quit_app_is_never_the_nonexistent_stop_app() {
        let payload = quit_app_payload(Some("s"));
        assert_ne!(payload["type"], serde_json::json!("STOP_APP"));
    }

    /// Mute rides the same `SET_VOLUME` message as volume, distinguished only
    /// by the field. `SET_VOLUME_MUTED` is accepted and ignored, which reads as
    /// "this receiver has no mute".
    #[test]
    fn mute_is_a_field_on_set_volume() {
        // Pinned via the same shape the sender builds.
        let muted = serde_json::json!({ "type": "SET_VOLUME", "volume": { "muted": true } });
        assert_eq!(muted["type"], serde_json::json!("SET_VOLUME"));
        assert_eq!(muted["volume"]["muted"], serde_json::json!(true));
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
        assert!(
            media.track_content_id.starts_with("http://"),
            "a receiver cannot resolve a relative path"
        );
    }

    #[test]
    fn a_blank_label_gets_a_generated_name() {
        let t = SubtitleTrack {
            track_id: 3,
            label: String::new(),
            lang: String::new(),
            src: "http://h/x.vtt".into(),
        };
        let media = t.to_media_track();
        assert_eq!(media.name, "Subtitle 3");
        assert_eq!(
            media.language, "en",
            "a blank language must not be sent as empty"
        );
    }

    #[test]
    fn a_standby_receiver_reports_full_volume_not_zero() {
        let media = serde_json::json!({});
        let receiver = serde_json::json!({
            "type": "RECEIVER_STATUS",
            "status": { "isActiveInput": false, "isStandby": true }
        });
        let payload = status_payload(&media, &receiver);
        assert_eq!(
            payload["volume"], 100.0,
            "no volume field must not read as muted"
        );
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
            "status": { "volume": { "level": 0.3, "muted": false, "controlType": "attenuation" }, "isActiveInput": true }
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
        assert_eq!(
            MEDIA_RECEIVER_ID,
            "urn:x-cast:com.google.cast.media-receiver"
        );
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
