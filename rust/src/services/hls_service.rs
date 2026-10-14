use hex;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

pub struct HlsService;

impl HlsService {
    /// Strip Windows verbatim path prefix (\\?\) for hash determinism matching Python
    pub fn strip_verbatim(path_str: &str) -> &str {
        if let Some(stripped) = path_str.strip_prefix(r"\\?\") {
            stripped
        } else {
            path_str
        }
    }

    /// Return valid candidate HLS cache directory names matching Python's get_hls_candidates
    pub fn get_hls_candidates(path: &Path, roots: &[PathBuf]) -> HashSet<String> {
        let mut candidates = HashSet::new();
        let path_lossy = path.to_string_lossy();
        let path_str = Self::strip_verbatim(&path_lossy);

        let (size, mtime_ns) = match std::fs::metadata(path) {
            Ok(m) => {
                let size = m.len();
                let mtime_ns = m
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_nanos())
                    .unwrap_or(0);
                (Some(size), Some(mtime_ns))
            }
            Err(_) => (None, None),
        };

        if let (Some(s), Some(mt)) = (size, mtime_ns) {
            let primary_key = format!("hls:{}:{}:{}", path_str, s, mt);
            let mut hasher = Sha256::new();
            hasher.update(primary_key.as_bytes());
            candidates.insert(hex::encode(hasher.finalize()));
        }

        // Relative path across roots
        let mut rel: Option<PathBuf> = None;
        let mut sorted_roots = roots.to_vec();
        sorted_roots.sort_by_key(|r| std::cmp::Reverse(r.to_string_lossy().len()));

        for r in &sorted_roots {
            if let Ok(stripped) = path.strip_prefix(r) {
                rel = Some(stripped.to_path_buf());
                break;
            }
        }

        let rel_clean = rel.as_ref().and_then(|r| {
            let clean_parts: Vec<_> = r.components().filter(|c| c.as_os_str() != ".archive").collect();
            if clean_parts.is_empty() {
                None
            } else {
                let mut p = PathBuf::new();
                for c in clean_parts {
                    p.push(c);
                }
                Some(p)
            }
        });

        let file_name = path
            .file_name()
            .map(|f| f.to_string_lossy().to_string())
            .unwrap_or_default();

        if let (Some(s), Some(mt)) = (size, mtime_ns) {
            for root in roots {
                let root_file = root.join(&file_name);
                let k1 = format!("hls:{}:{}:{}", Self::strip_verbatim(&root_file.to_string_lossy()), s, mt);
                let mut h1 = Sha256::new();
                h1.update(k1.as_bytes());
                candidates.insert(hex::encode(h1.finalize()));

                if let Some(ref r) = rel {
                    let root_rel = root.join(r);
                    let k2 = format!("hls:{}:{}:{}", Self::strip_verbatim(&root_rel.to_string_lossy()), s, mt);
                    let mut h2 = Sha256::new();
                    h2.update(k2.as_bytes());
                    candidates.insert(hex::encode(h2.finalize()));
                }

                if let Some(ref rc) = rel_clean {
                    let root_rc = root.join(rc);
                    let k3 = format!("hls:{}:{}:{}", Self::strip_verbatim(&root_rc.to_string_lossy()), s, mt);
                    let mut h3 = Sha256::new();
                    h3.update(k3.as_bytes());
                    candidates.insert(hex::encode(h3.finalize()));

                    let root_arch = root.join(".archive").join(rc);
                    let k4 = format!("hls:{}:{}:{}", Self::strip_verbatim(&root_arch.to_string_lossy()), s, mt);
                    let mut h4 = Sha256::new();
                    h4.update(k4.as_bytes());
                    candidates.insert(hex::encode(h4.finalize()));
                }
            }
        }

        let fallback_size = size.unwrap_or(0);
        let fb_key = format!("hls:{}:{}", file_name, fallback_size);
        let mut fb_hasher = Sha256::new();
        fb_hasher.update(fb_key.as_bytes());
        candidates.insert(hex::encode(fb_hasher.finalize()));

        candidates
    }

    /// Resolve the authoritative HLS cache directory for a given video path
    pub fn find_hls_dir(path: &Path, roots: &[PathBuf], cache_dir: &Path) -> PathBuf {
        let cache_base = cache_dir.join("hls");
        let (size, mtime_ns) = match std::fs::metadata(path) {
            Ok(m) => {
                let size = m.len();
                let mtime_ns = m
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_nanos())
                    .unwrap_or(0);
                (Some(size), Some(mtime_ns))
            }
            Err(_) => (None, None),
        };

        let primary_key = if let (Some(s), Some(mt)) = (size, mtime_ns) {
            let k = format!("hls:{}:{}:{}", Self::strip_verbatim(&path.to_string_lossy()), s, mt);
            let mut hasher = Sha256::new();
            hasher.update(k.as_bytes());
            hex::encode(hasher.finalize())
        } else {
            let fn_str = path.file_name().map(|f| f.to_string_lossy().to_string()).unwrap_or_default();
            let k = format!("hls:{}:0", fn_str);
            let mut hasher = Sha256::new();
            hasher.update(k.as_bytes());
            hex::encode(hasher.finalize())
        };

        let primary_dir = cache_base.join(&primary_key);
        let candidates = Self::get_hls_candidates(path, roots);

        let mut existing_dirs: Vec<PathBuf> = candidates
            .into_iter()
            .map(|cand| cache_base.join(cand))
            .filter(|d| d.is_dir())
            .collect();

        if existing_dirs.is_empty() {
            return primary_dir;
        }

        // 1. Prefer fully completed playlist with #EXT-X-ENDLIST
        for d in &existing_dirs {
            let pl = d.join("playlist.m3u8");
            if pl.is_file() {
                if let Ok(content) = std::fs::read_to_string(&pl) {
                    if content.contains("#EXT-X-ENDLIST") {
                        return d.clone();
                    }
                }
            }
        }

        // 2. Prefer directory with most progress (segments / chunks)
        let mut best_dir = None;
        let mut max_progress = -1i64;

        for d in &existing_dirs {
            let mut seg_count = 0i64;
            let mut chunk_count = 0i64;
            if let Ok(entries) = std::fs::read_dir(d) {
                for entry in entries.flatten() {
                    let name = entry.file_name().to_string_lossy().to_string();
                    if name.ends_with(".ts") || name.ends_with(".m4s") {
                        seg_count += 1;
                    } else if name.starts_with("chunk_") && name.ends_with(".m3u8") {
                        chunk_count += 1;
                    }
                }
            }
            let prog = seg_count + (chunk_count * 15);
            if prog > max_progress {
                max_progress = prog;
                best_dir = Some(d.clone());
            }
        }

        if let Some(bd) = best_dir {
            if max_progress > 0 {
                return bd;
            }
        }

        if existing_dirs.contains(&primary_dir) {
            return primary_dir;
        }

        existing_dirs.remove(0)
    }

    /// Check if segment filename matches allowed HLS pattern: init.mp4 or segment_\d{6}\.(ts|m4s)
    pub fn is_valid_segment_name(segment: &str) -> bool {
        if segment == "init.mp4" {
            return true;
        }
        if let Some(rest) = segment.strip_prefix("segment_") {
            if let Some((num, ext)) = rest.split_once('.') {
                if (ext == "ts" || ext == "m4s") && num.len() == 6 && num.chars().all(|c| c.is_ascii_digit()) {
                    return true;
                }
            }
        }
        false
    }

    /// Adjust `#EXT-X-TARGETDURATION` declaration to ceiling of longest #EXTINF label
    pub fn honest_target_duration(text: &str) -> String {
        let mut longest = 0.0f64;
        for line in text.lines() {
            if let Some(rest) = line.strip_prefix("#EXTINF:") {
                let num_str = rest.trim_end_matches(',').split(',').next().unwrap_or("0");
                if let Ok(dur) = num_str.trim().parse::<f64>() {
                    if dur > longest {
                        longest = dur;
                    }
                }
            }
        }

        if longest <= 0.0 {
            return text.to_string();
        }

        let target = longest.ceil() as u64;
        let mut replaced = false;
        let mut output = Vec::new();

        for line in text.lines() {
            if let Some(rest) = line.strip_prefix("#EXT-X-TARGETDURATION:") {
                if let Ok(declared) = rest.trim().parse::<u64>() {
                    if declared < target {
                        output.push(format!("#EXT-X-TARGETDURATION:{}", target));
                        replaced = true;
                        continue;
                    }
                }
                output.push(line.to_string());
                replaced = true;
            } else {
                output.push(line.to_string());
            }
        }

        if !replaced {
            let mut new_output = Vec::new();
            for line in output {
                new_output.push(line.clone());
                if line.starts_with("#EXTM3U") {
                    new_output.push(format!("#EXT-X-TARGETDURATION:{}", target));
                }
            }
            return new_output.join("\n") + "\n";
        }

        output.join("\n") + "\n"
    }

    /// Deterministic cache file path for transcoded MP4 matching Python transcode_cache_path
    pub fn get_transcode_cache_path(path: &Path, mode: &str, cache_dir: &Path) -> PathBuf {
        let path_lossy = path.to_string_lossy();
        let path_str = Self::strip_verbatim(&path_lossy);
        let (size, mtime_ns) = match std::fs::metadata(path) {
            Ok(m) => {
                let size = m.len();
                let mtime_ns = m
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_nanos())
                    .unwrap_or(0);
                (size, mtime_ns)
            }
            Err(_) => (0, 0),
        };

        let stamp = format!("{}:{}:{}", path_str, size, mtime_ns);
        let key_str = if mode == "direct" {
            stamp
        } else {
            format!("{}:{}", mode, stamp)
        };

        let mut hasher = Sha256::new();
        hasher.update(key_str.as_bytes());
        let hash = hex::encode(hasher.finalize());

        cache_dir.join("transcodes").join(format!("{}.mp4", hash))
    }
}
