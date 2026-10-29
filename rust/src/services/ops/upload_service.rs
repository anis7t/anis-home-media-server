use crate::error::AppError;
use crate::models::upload::UploadManifest;
use crate::scanner::ScannerEngine;
use std::io::SeekFrom;
use std::path::{Path, PathBuf};
use tokio::io::{AsyncSeekExt, AsyncWriteExt};

/// Matches the Flask-era chunk size: 8 MiB per request.
pub const CHUNK_SIZE: u64 = 8 * 1024 * 1024;

/// Matches the Flask-era total cap: 20 GiB.
pub const MAX_UPLOAD_BYTES: u64 = 20 * 1024 * 1024 * 1024;

/// The formats the upload UI advertises and the backend accepts. The scanner
/// supports more containers, but limiting the write surface to these keeps the
/// acceptance text honest and matches the old UI's `accept` attribute.
pub const ALLOWED_EXTENSIONS: [&str; 6] = ["mp4", "mkv", "webm", "mov", "avi", "m4v"];

/// Upload IDs are capability tokens in the temp directory, so they must be
/// filename-safe and long enough to be unguessable. `generate_random_token()`
/// produces 64 hex characters, which fits.
pub fn validate_upload_id(id: &str) -> Result<(), AppError> {
    if id.len() < 20 || id.len() > 64 {
        return Err(AppError::BadRequest("Invalid upload id".to_string()));
    }
    if !id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return Err(AppError::BadRequest("Invalid upload id".to_string()));
    }
    Ok(())
}

fn extension_of(name: &str) -> String {
    Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
}

/// Take the basename, strip characters that are illegal or dangerous on
/// Windows, reject empty/dot names and unsupported extensions.
pub fn sanitize_filename(raw: &str) -> Result<String, AppError> {
    let base = raw.rsplit(['/', '\\']).next().unwrap_or(raw).trim();
    if base.is_empty() {
        return Err(AppError::BadRequest(
            "No file selected for upload".to_string(),
        ));
    }

    let mut cleaned = String::with_capacity(base.len());
    for c in base.chars() {
        if c == ':' || c == '\0' || c.is_control() {
            continue;
        }
        cleaned.push(c);
    }

    let cleaned = cleaned.trim().trim_end_matches(['.', ' ']).to_string();

    if cleaned.is_empty() || cleaned == "." || cleaned == ".." {
        return Err(AppError::BadRequest("Invalid media filename".to_string()));
    }

    let ext = extension_of(&cleaned);
    if !ALLOWED_EXTENSIONS.contains(&ext.as_str()) {
        return Err(AppError::UnsupportedMediaType(format!(
            "Unsupported format '.{}'. Accepted: {}",
            ext,
            ALLOWED_EXTENSIONS
                .iter()
                .map(|e| format!(".{}", e))
                .collect::<Vec<_>>()
                .join(", ")
        )));
    }

    Ok(cleaned)
}

/// A title override is a display name, not a path. Remove path separators and
/// characters Windows forbids, collapse whitespace, and trim trailing dots.
pub fn sanitize_title(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for c in raw.chars() {
        if matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|')
            || c == '\0'
            || c.is_control()
        {
            out.push(' ');
        } else {
            out.push(c);
        }
    }
    out.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim_end_matches(['.', ' '])
        .to_string()
}

/// Resolve the final file name from the sanitized original and an optional
/// title override. The extension always follows the original.
pub fn build_target_name(original: &str, title: Option<&str>) -> Result<String, AppError> {
    let original = sanitize_filename(original)?;
    let ext = extension_of(&original);
    if ext.is_empty() {
        return Err(AppError::UnsupportedMediaType(
            "Media filename has no extension".to_string(),
        ));
    }

    if let Some(title) = title {
        let title = sanitize_title(title);
        if !title.is_empty() {
            let suffix = format!(".{}", ext);
            if title
                .to_ascii_lowercase()
                .ends_with(&suffix.to_ascii_lowercase())
            {
                return Ok(title);
            }
            return Ok(format!("{}{}", title, suffix));
        }
    }

    Ok(original)
}

/// Return `(json_path, part_path)` for an upload id.
pub fn session_paths(tmp_dir: &Path, id: &str) -> (PathBuf, PathBuf) {
    (
        tmp_dir.join(format!("{}.json", id)),
        tmp_dir.join(format!("{}.part", id)),
    )
}

/// Pick a target path. With `overwrite=false`, append ` (1)`, ` (2)`, ... until
/// the name is free. The caller has already sanitized `filename`.
pub fn unique_target_path(target_dir: &Path, filename: &str, overwrite: bool) -> PathBuf {
    let direct = target_dir.join(filename);
    if overwrite || !direct.exists() {
        return direct;
    }

    let path = Path::new(filename);
    let stem = path
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| filename.to_string());
    let ext = path
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy()))
        .unwrap_or_default();

    let mut counter = 1u32;
    loop {
        let candidate = target_dir.join(format!("{} ({}){}", stem, counter, ext));
        if !candidate.exists() {
            return candidate;
        }
        counter = counter.saturating_add(1);
    }
}

/// Write the manifest atomically (`<id>.json.tmp` then rename).
pub async fn write_manifest(
    tmp_dir: &Path,
    id: &str,
    manifest: &UploadManifest,
) -> Result<(), AppError> {
    let (json_path, _) = session_paths(tmp_dir, id);
    let tmp_path = json_path.with_extension("json.tmp");
    let bytes = serde_json::to_vec_pretty(manifest)
        .map_err(|e| AppError::Internal(format!("Failed to serialize upload manifest: {}", e)))?;

    tokio::fs::write(&tmp_path, &bytes)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to write upload manifest: {}", e)))?;
    // The target should not exist at init. Removing first makes the rename
    // safe on Windows if a stale file is somehow present.
    let _ = tokio::fs::remove_file(&json_path).await;
    tokio::fs::rename(&tmp_path, &json_path)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to commit upload manifest: {}", e)))?;
    Ok(())
}

pub async fn read_manifest(tmp_dir: &Path, id: &str) -> Result<UploadManifest, AppError> {
    let (json_path, _) = session_paths(tmp_dir, id);
    let bytes = match tokio::fs::read(&json_path).await {
        Ok(bytes) => bytes,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            return Err(AppError::NotFound("Upload session not found".to_string()));
        }
        Err(err) => {
            return Err(AppError::Internal(format!(
                "Failed to read upload manifest: {}",
                err
            )));
        }
    };

    serde_json::from_slice(&bytes)
        .map_err(|e| AppError::Internal(format!("Invalid upload manifest: {}", e)))
}

/// Create the empty `.part` file and write the manifest. Fails if the part
/// already exists (an id collision, which is not expected for 64 hex chars).
pub async fn create_session(
    tmp_dir: &Path,
    id: &str,
    manifest: &UploadManifest,
) -> Result<(), AppError> {
    tokio::fs::create_dir_all(tmp_dir)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to create upload temp dir: {}", e)))?;

    let (_, part_path) = session_paths(tmp_dir, id);
    let file = tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&part_path)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to create upload part file: {}", e)))?;
    file.sync_all()
        .await
        .map_err(|e| AppError::Internal(format!("Failed to sync upload part file: {}", e)))?;

    if let Err(err) = write_manifest(tmp_dir, id, manifest).await {
        let _ = tokio::fs::remove_file(&part_path).await;
        return Err(err);
    }

    Ok(())
}

/// Append bytes at `offset`. The caller checks the offset first; this check is
/// a race guard.
pub async fn append_chunk(part_path: &Path, offset: u64, bytes: &[u8]) -> Result<u64, AppError> {
    let mut file = tokio::fs::OpenOptions::new()
        .write(true)
        .open(part_path)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to open upload part file: {}", e)))?;

    let current = file
        .metadata()
        .await
        .map_err(|e| AppError::Internal(format!("Failed to stat upload part file: {}", e)))?
        .len();

    if current != offset {
        return Err(AppError::BadRequest(format!(
            "Upload offset mismatch: expected {}, got {}",
            current, offset
        )));
    }

    file.seek(SeekFrom::Start(offset))
        .await
        .map_err(|e| AppError::Internal(format!("Failed to seek upload part file: {}", e)))?;
    file.write_all(bytes)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to write upload chunk: {}", e)))?;
    file.sync_all()
        .await
        .map_err(|e| AppError::Internal(format!("Failed to sync upload chunk: {}", e)))?;

    Ok(offset + bytes.len() as u64)
}

/// Remove a session's part and manifest. Idempotent.
pub async fn abandon_session(tmp_dir: &Path, id: &str) -> Result<(), AppError> {
    let (json_path, part_path) = session_paths(tmp_dir, id);
    let _ = tokio::fs::remove_file(&json_path).await;
    let _ = tokio::fs::remove_file(&part_path).await;
    Ok(())
}

/// Delete sessions older than `max_age_secs`. A malformed manifest is left
/// alone rather than guessed at.
pub async fn cleanup_stale(tmp_dir: &Path, max_age_secs: i64) {
    let now = chrono::Utc::now().timestamp();
    let mut entries = match tokio::fs::read_dir(tmp_dir).await {
        Ok(entries) => entries,
        Err(_) => return,
    };

    while let Ok(Some(entry)) = entries.next_entry().await {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Some(id) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        if validate_upload_id(id).is_err() {
            continue;
        }
        let Ok(manifest) = read_manifest(tmp_dir, id).await else {
            continue;
        };
        if now.saturating_sub(manifest.created_at) > max_age_secs {
            let _ = abandon_session(tmp_dir, id).await;
            tracing::info!("Removed stale upload session {}", id);
        }
    }
}

/// Verify the part is exactly the declared size, choose the final name, move
/// the data, remove the manifest, and return the final path.
pub async fn finalize_session(
    tmp_dir: &Path,
    target_dir: &Path,
    id: &str,
) -> Result<PathBuf, AppError> {
    let manifest = read_manifest(tmp_dir, id).await?;
    let (json_path, part_path) = session_paths(tmp_dir, id);

    let actual = tokio::fs::metadata(&part_path)
        .await
        .map_err(|e| AppError::BadRequest(format!("Upload part is missing: {}", e)))?
        .len();
    if actual != manifest.size {
        return Err(AppError::BadRequest(format!(
            "Upload is incomplete: expected {} bytes, have {}",
            manifest.size, actual
        )));
    }

    let target_name = build_target_name(&manifest.filename, manifest.title.as_deref())?;
    tokio::fs::create_dir_all(target_dir)
        .await
        .map_err(|e| AppError::Internal(format!("Failed to create upload target dir: {}", e)))?;

    let target = unique_target_path(target_dir, &target_name, manifest.overwrite);
    if manifest.overwrite && target.exists() {
        let _ = tokio::fs::remove_file(&target).await;
    }

    if let Err(rename_err) = tokio::fs::rename(&part_path, &target).await {
        // Cross-volume fallback (the configured temp and target can be on
        // different drives). Copy then remove the source.
        tokio::fs::copy(&part_path, &target)
            .await
            .map_err(|copy_err| {
                AppError::Internal(format!(
                    "Failed to move upload into place (rename: {}; copy: {})",
                    rename_err, copy_err
                ))
            })?;
        let _ = tokio::fs::remove_file(&part_path).await;
    }

    let _ = tokio::fs::remove_file(&json_path).await;
    Ok(target)
}

/// Title and year from a filename, matching the scanner/test fallback
/// convention. The title override, when present, is applied by the caller.
pub fn parse_title_year(filename: &str) -> (String, Option<i32>) {
    let stem = Path::new(filename)
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| filename.to_string());

    let title = stem
        .replace(['_', '.'], " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");

    let year = title.split_whitespace().find_map(|word| {
        let digits: String = word.chars().filter(|c| c.is_ascii_digit()).collect();
        if digits.len() == 4 {
            digits.parse::<i32>().ok()
        } else {
            None
        }
    });

    (title, year)
}

/// Relative catalog key, matching the native scanner's separator convention.
pub fn relative_filename(path: &Path, media_root: &Path) -> String {
    ScannerEngine::compute_relative_path(path, &[media_root.to_path_buf()])
}

/// The response field is advisory. Web-native containers can direct play; the
/// rest are likely to need the normal transcode path. The upload itself never
/// blocks on an encoder.
pub fn needs_transcode(filename: &str) -> bool {
    matches!(extension_of(filename).as_str(), "mkv" | "avi" | "mov")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn sanitize_strips_path_components_and_rejects_unsupported_types() {
        assert_eq!(sanitize_filename("../evil.mp4").unwrap(), "evil.mp4");
        assert_eq!(
            sanitize_filename("C:\\\\temp\\\\Movie.mkv").unwrap(),
            "Movie.mkv"
        );
        assert!(sanitize_filename("movie.exe").is_err());
        assert!(sanitize_filename("..").is_err());
        assert!(sanitize_filename("").is_err());
    }

    #[test]
    fn title_override_keeps_exactly_one_extension() {
        assert_eq!(
            build_target_name("original.mp4", Some("Custom Title")).unwrap(),
            "Custom Title.mp4"
        );
        assert_eq!(
            build_target_name("original.mp4", Some("Custom Title.mp4")).unwrap(),
            "Custom Title.mp4"
        );
        assert_eq!(
            build_target_name("original.mp4", None).unwrap(),
            "original.mp4"
        );
    }

    #[test]
    fn unique_names_increment_without_overwriting() {
        let dir =
            std::env::temp_dir().join(format!("ms_upload_unit_unique_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("Movie.mp4"), b"existing").unwrap();

        let next = unique_target_path(&dir, "Movie.mp4", false);
        assert_eq!(
            next.file_name().and_then(|s| s.to_str()),
            Some("Movie (1).mp4")
        );

        let overwrite = unique_target_path(&dir, "Movie.mp4", true);
        assert_eq!(
            overwrite.file_name().and_then(|s| s.to_str()),
            Some("Movie.mp4")
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn title_and_year_are_parsed_from_the_filename() {
        let (title, year) = parse_title_year("The.Matrix.1999.1080p.mp4");
        assert_eq!(title, "The Matrix 1999 1080p");
        assert_eq!(year, Some(1999));
    }
}
