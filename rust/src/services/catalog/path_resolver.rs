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
                    return Err(AppError::Forbidden(
                        "Directory traversal or absolute path denied".to_string(),
                    ));
                }
                _ => {}
            }
        }

        // 1. Try direct candidate paths across media roots
        for root in roots {
            let candidate = root.join(rel_path);
            if candidate.is_file() {
                if let (Ok(canon_cand), Ok(canon_root)) =
                    (candidate.canonicalize(), root.canonicalize())
                {
                    if canon_cand.starts_with(&canon_root) {
                        return Ok(canon_cand);
                    }
                }
            }
        }

        // 2. Fallback: Search media roots recursively if referenced by filename
        if let Some(target_os_name) = rel_path.file_name() {
            if let Some(target_name) = target_os_name.to_str() {
                for root in roots {
                    if let Ok(canon_root) = root.canonicalize() {
                        if let Some(found) = Self::find_in_dir(&canon_root, target_name, 0) {
                            return Ok(found);
                        }
                    }
                }
            }
        }

        Err(AppError::NotFound(format!(
            "Media file '{}' not found",
            filename
        )))
    }

    fn find_in_dir(dir: &Path, target: &str, depth: usize) -> Option<PathBuf> {
        if depth > 4 {
            return None;
        }
        if let Ok(entries) = std::fs::read_dir(dir) {
            let mut subdirs = Vec::new();
            for entry in entries.flatten() {
                if let Ok(ft) = entry.file_type() {
                    if ft.is_file() {
                        if entry.file_name() == target {
                            if let Ok(canon) = entry.path().canonicalize() {
                                return Some(canon);
                            }
                        }
                    } else if ft.is_dir() {
                        let name = entry.file_name();
                        let s = name.to_string_lossy();
                        if !s.starts_with('.') && s != "node_modules" {
                            subdirs.push(entry.path());
                        }
                    }
                }
            }
            for sub in subdirs {
                if let Some(found) = Self::find_in_dir(&sub, target, depth + 1) {
                    return Some(found);
                }
            }
        }
        None
    }
}
