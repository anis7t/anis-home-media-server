use crate::error::AppError;
use std::path::{Component, Path, PathBuf};

pub struct PathResolver;

impl PathResolver {
    /// Resolve a sanitized relative video path across configured media roots.
    pub fn resolve_media_path(filename: &str, roots: &[PathBuf]) -> Result<PathBuf, AppError> {
        if filename.contains('\0') {
            return Err(AppError::NotFound("Invalid filename".to_string()));
        }

        let clean = filename.trim_start_matches(|c| c == '/' || c == '\\');
        if clean.is_empty() {
            return Err(AppError::BadRequest("Filename cannot be empty".to_string()));
        }

        let rel_path = Path::new(clean);

        // Disallow any traversal or absolute components
        for comp in rel_path.components() {
            match comp {
                Component::ParentDir | Component::Prefix(_) | Component::RootDir => {
                    return Err(AppError::Forbidden("Directory traversal or absolute path denied".to_string()));
                }
                _ => {}
            }
        }

        // Try candidate paths across media roots
        for root in roots {
            let candidate = root.join(rel_path);
            if candidate.is_file() {
                if let (Ok(canon_cand), Ok(canon_root)) = (candidate.canonicalize(), root.canonicalize()) {
                    if canon_cand.starts_with(&canon_root) {
                        return Ok(canon_cand);
                    }
                }
            }
        }

        Err(AppError::NotFound(format!("Media file '{}' not found", filename)))
    }
}
