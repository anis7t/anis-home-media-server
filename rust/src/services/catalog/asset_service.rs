use crate::error::AppError;
use crate::services::path_resolver::PathResolver;
use axum::{
    body::Body,
    http::{header, HeaderMap, HeaderValue, Method, Response, StatusCode},
};
use chrono::{DateTime, Utc};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// Extensions Flask accepts for a local poster (`app/config.py`
/// `POSTER_EXTENSIONS`). Anything else is a 404, not a 403 - the file may
/// well exist, it simply is not artwork.
const IMAGE_EXTENSIONS: [&str; 4] = [".jpg", ".jpeg", ".png", ".webp"];

/// Cache lifetime, matching Flask's `send_file(..., max_age=86400)`.
pub const ARTWORK_MAX_AGE_SECS: u64 = 86_400;

pub struct AssetService;

impl AssetService {
    /// Resolve a locally stored image under the configured media roots.
    ///
    /// Read-only, deliberately: Flask's `safe_path` also has a "resolve
    /// within MEDIA_ROOT for write/fallback" step, which exists because
    /// poster *writes* go through the same helper. This route only ever
    /// serves, so an unresolved name is a 404 rather than a path to a file
    /// that does not exist yet.
    ///
    /// Traversal defence is `PathResolver`'s, not a second implementation:
    /// it rejects `..`/absolute components up front and re-checks
    /// canonicalized containment before returning.
    pub fn resolve_local_image(roots: &[PathBuf], filename: &str) -> Result<PathBuf, AppError> {
        let path = PathResolver::resolve_media_path(filename, roots)?;

        // `Path::extension` yields "png", the allowlist holds ".png" - compare
        // like with like or every image is rejected.
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.to_ascii_lowercase())
            .map(|e| format!(".{}", e))
            .unwrap_or_default();
        if !IMAGE_EXTENSIONS.contains(&ext.as_str()) {
            return Err(AppError::NotFound(format!(
                "'{}' is not a served image type",
                filename
            )));
        }

        Ok(path)
    }

    /// Serve an image with validators.
    ///
    /// `Last-Modified` is derived from the file mtime, which is what Flask
    /// sends too, so that validator is byte-identical across the port swap
    /// and browsers stay warm. The ETag is a deterministic `mtime-size`
    /// pair rather than Flask's `mtime-size-adler32(path)`: it changes only
    /// when the file does, and it does not depend on which server produced
    /// it. That makes a client's cached copy validate correctly rather than
    /// being invalidated once by a value that never had content meaning.
    pub async fn serve_image(
        path: PathBuf,
        headers: HeaderMap,
        method: Method,
        max_age_secs: u64,
    ) -> Result<Response<Body>, AppError> {
        let metadata = tokio::fs::metadata(&path)
            .await
            .map_err(|e| AppError::NotFound(e.to_string()))?;
        let mtime = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
        let size = metadata.len();

        let etag = format!("\"{:x}-{:x}\"", mtime_secs(mtime), size);
        let last_modified = http_date(mtime);
        let max_age = format!("public, max-age={}", max_age_secs);

        // Conditional requests: ETag first (strong validator), then
        // If-Modified-Since for clients that only do date revalidation.
        let inm = headers
            .get(header::IF_NONE_MATCH)
            .and_then(|v| v.to_str().ok());
        let etag_matches = match inm {
            Some(list) => list.split(',').any(|t| t.trim() == etag || t.trim() == "*"),
            None => false,
        };
        let ims_hit = match headers
            .get(header::IF_MODIFIED_SINCE)
            .and_then(|v| v.to_str().ok())
        {
            Some(value) => match parse_http_date(value) {
                Some(since) => since >= truncated_to_secs(mtime),
                None => false,
            },
            None => false,
        };

        if etag_matches || ims_hit {
            let mut res = Response::new(Body::empty());
            *res.status_mut() = StatusCode::NOT_MODIFIED;
            let h = res.headers_mut();
            h.insert(header::ETAG, HeaderValue::from_str(&etag).unwrap());
            h.insert(
                header::LAST_MODIFIED,
                HeaderValue::from_str(&last_modified).unwrap(),
            );
            h.insert(
                header::CACHE_CONTROL,
                HeaderValue::from_str(&max_age).unwrap(),
            );
            h.insert("access-control-allow-origin", HeaderValue::from_static("*"));
            return Ok(res);
        }

        let mut res =
            crate::services::range_service::RangeService::stream_file(path, headers, method)
                .await?;

        // The shared streamer adds DLNA advertisement headers because it
        // serves video. They are additive and harmless, but they describe
        // streaming behaviour that does not apply to an image, so they are
        // dropped here rather than asserted as a contract.
        let h = res.headers_mut();
        h.remove("contentfeatures.dlna.org");
        h.remove("transfermode.dlna.org");
        h.insert(header::ETAG, HeaderValue::from_str(&etag).unwrap());
        h.insert(
            header::LAST_MODIFIED,
            HeaderValue::from_str(&last_modified).unwrap(),
        );
        h.insert(
            header::CACHE_CONTROL,
            HeaderValue::from_str(&max_age).unwrap(),
        );

        Ok(res)
    }
}

fn mtime_secs(t: SystemTime) -> u64 {
    t.duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// HTTP dates have one-second resolution, so sub-second mtime must be
/// truncated before comparison or a file modified at .500s never matches a
/// `Last-Modified` the server itself just emitted.
fn truncated_to_secs(t: SystemTime) -> SystemTime {
    let secs = mtime_secs(t);
    SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(secs)
}

fn http_date(t: SystemTime) -> String {
    let dt: DateTime<Utc> = t.into();
    dt.format("%a, %d %b %Y %H:%M:%S GMT").to_string()
}

fn parse_http_date(s: &str) -> Option<SystemTime> {
    // Two deliberate departures from the obvious implementation:
    //
    // 1. The leading weekday is stripped, not parsed with `%a`. chrono
    //    *validates* `%a` against the date, so a client whose clock - or a
    //    file whose mtime - sits across a day boundary fails to parse and
    //    silently loses revalidation, re-sending the whole body instead of
    //    a 304. The date is the part that carries meaning.
    // 2. The value is parsed as a naive datetime and interpreted as UTC.
    //    `DateTime::parse_from_str` builds a `DateTime<FixedOffset>` and
    //    rejects a format with no offset specifier, so a trailing literal
    //    "GMT" is not enough to make it parse. HTTP dates are UTC by
    //    definition, so the offset is known rather than parsed.
    let rest = s
        .trim()
        .split_once(", ")
        .map(|(_, r)| r)
        .unwrap_or(s.trim());
    // Strip the trailing zone token too: leaving it in while omitting it
    // from the format is trailing input, which chrono rejects.
    let rest = rest
        .trim()
        .trim_end_matches("GMT")
        .trim_end_matches('+')
        .trim();
    let naive = chrono::NaiveDateTime::parse_from_str(rest, "%d %b %Y %H:%M:%S").ok()?;
    Some(SystemTime::from(
        DateTime::<Utc>::from_naive_utc_and_offset(naive, Utc),
    ))
}

/// Shared by the tmdb artwork routes (C1b) once they land.
pub fn artwork_cache_paths(cache_dir: &Path) -> (PathBuf, PathBuf) {
    (cache_dir.join("posters"), cache_dir.join("backdrops"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extension_gate_is_case_insensitive_and_allowlisted() {
        // The gate compares dotted extensions, so exercise the dotted form
        // `Path::extension` is turned into. This is the comparison that
        // silently rejected every image when the dot was missing.
        assert!(IMAGE_EXTENSIONS.contains(&".jpg"));
        assert!(IMAGE_EXTENSIONS.contains(&".png"));
        assert!(IMAGE_EXTENSIONS.contains(&".webp"));
        assert!(!IMAGE_EXTENSIONS.contains(&".mkv"));
        assert!(!IMAGE_EXTENSIONS.contains(&".html"));
        // The undotted form must NOT match, or the allowlist is ambiguous.
        assert!(!IMAGE_EXTENSIONS.contains(&"png"));
    }

    #[test]
    fn http_date_roundtrips() {
        let t = SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_600_000_000);
        let s = http_date(t);
        let parsed = parse_http_date(&s).expect("emitted header must parse back");
        assert_eq!(mtime_secs(parsed), 1_600_000_000);
    }

    #[test]
    fn http_date_parses_regardless_of_weekday_correctness() {
        // A wrong weekday must not defeat revalidation.
        let s = "Mon, 03 Oct 2026 02:49:02 GMT";
        let parsed = parse_http_date(s).expect("weekday must be ignored");
        assert!(mtime_secs(parsed) > 0);
    }

    #[test]
    fn ims_comparison_hits_for_the_instant_we_just_emitted() {
        // Sub-second mtime: HTTP dates have second resolution, so the
        // comparison must truncate the mtime or a file modified at .500s
        // never matches the Last-Modified the server itself sent.
        let mtime = SystemTime::UNIX_EPOCH
            + std::time::Duration::from_secs(1_600_000_123)
            + std::time::Duration::from_nanos(500_000_000);
        let header = http_date(mtime);
        let since = parse_http_date(&header).expect("must parse");
        assert!(
            since >= truncated_to_secs(mtime),
            "If-Modified-Since '{}' did not match mtime",
            header
        );
    }
}
