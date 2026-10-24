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

        // 1. Prefer fully completed playlist with #EXT-X-ENDLIST (checking root and quality tiers)
        for d in &existing_dirs {
            if Self::is_hls_complete(d) {
                return d.clone();
            }
        }

        // 2. Prefer directory with most progress (segments / chunks across root and tiers)
        let mut best_dir = None;
        let mut max_progress = -1i64;

        for d in &existing_dirs {
            let prog = Self::calculate_dir_progress(d);
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

    /// Check if an HLS directory has reached 100% transcode completion (#EXT-X-ENDLIST).
    /// Inspects root playlist.m3u8, master.m3u8, and all known quality subdirectories.
    pub fn is_hls_complete(dir: &Path) -> bool {
        // 1. Root playlist or master
        for name in &["playlist.m3u8", "master.m3u8"] {
            let p = dir.join(name);
            if p.is_file() {
                if let Ok(content) = std::fs::read_to_string(&p) {
                    if content.contains("#EXT-X-ENDLIST") {
                        return true;
                    }
                }
            }
        }

        // 2. Tiered quality subdirectories
        for (label, _, _, _, _) in Self::STANDARD_QUALITIES {
            let p = dir.join(label).join("playlist.m3u8");
            if p.is_file() {
                if let Ok(content) = std::fs::read_to_string(&p) {
                    if content.contains("#EXT-X-ENDLIST") {
                        return true;
                    }
                }
            }
        }

        false
    }

    /// Calculate aggregate progress score (segments + chunks * 15) across root and quality subdirectories.
    pub fn calculate_dir_progress(dir: &Path) -> i64 {
        let mut score = Self::count_progress_in_single_dir(dir);

        // Also aggregate progress from tiered subdirectories
        for (label, _, _, _, _) in Self::STANDARD_QUALITIES {
            let q_dir = dir.join(label);
            if q_dir.is_dir() {
                score += Self::count_progress_in_single_dir(&q_dir);
            }
        }

        score
    }

    fn count_progress_in_single_dir(dir: &Path) -> i64 {
        let mut seg_count = 0i64;
        let mut chunk_count = 0i64;
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if name.ends_with(".ts") || name.ends_with(".m4s") {
                    seg_count += 1;
                } else if name.starts_with("chunk_") && name.ends_with(".m3u8") {
                    chunk_count += 1;
                }
            }
        }
        seg_count + (chunk_count * 15)
    }

    /// Standard quality tiers with resolution, bitrate, and codecs matching Apple HLS authoring specs.
    pub const STANDARD_QUALITIES: &'static [(&'static str, u32, u32, u64, &'static str)] = &[
        ("2160p", 3840, 2160, 14000000, "hvc1.1.6.L153.B0,mp4a.40.2"),
        ("1440p", 2560, 1440, 8000000, "avc1.640032,mp4a.40.2"),
        ("1080p", 1920, 1080, 4500000, "avc1.640028,mp4a.40.2"),
        ("720p", 1280, 720, 2200000, "avc1.64001f,mp4a.40.2"),
        ("480p", 854, 480, 1200000, "avc1.64001f,mp4a.40.2"),
        ("360p", 640, 360, 800000, "avc1.64001e,mp4a.40.2"),
    ];

    /// Dynamically assemble an RFC 8216 multi-variant master playlist advertising all active quality tiers.
    pub fn build_master_playlist(base_hls_dir: &Path) -> Option<String> {
        let mut streams = Vec::new();

        // 1. Collect published tiered streams
        for (label, w, h, bandwidth, codecs) in Self::STANDARD_QUALITIES {
            let q_pl = base_hls_dir.join(label).join("playlist.m3u8");
            if q_pl.is_file() {
                if let Ok(content) = std::fs::read_to_string(&q_pl) {
                    if content.contains("segment_") {
                        streams.push(format!(
                            "#EXT-X-STREAM-INF:BANDWIDTH={},RESOLUTION={}x{},CODECS=\"{}\"\n{}/playlist.m3u8",
                            bandwidth, w, h, codecs, label
                        ));
                    }
                }
            }
        }

        // 2. If no quality subdirectories exist, check for legacy root playlist
        if streams.is_empty() {
            let root_pl = base_hls_dir.join("playlist.m3u8");
            if root_pl.is_file() {
                if let Ok(content) = std::fs::read_to_string(&root_pl) {
                    if content.contains("segment_") {
                        if content.contains("#EXT-X-STREAM-INF") {
                            return Some(content);
                        }
                        streams.push(
                            "#EXT-X-STREAM-INF:BANDWIDTH=4500000,RESOLUTION=1920x1080,CODECS=\"avc1.640028,mp4a.40.2\"\nplaylist.m3u8".to_string()
                        );
                    }
                }
            }
        }

        if streams.is_empty() {
            return None;
        }

        let mut out = String::from("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n\n");
        out.push_str(&streams.join("\n\n"));
        out.push('\n');
        Some(out)
    }

    /// Write or synchronize `master.m3u8` to disk inside `base_hls_dir`.
    pub fn update_master_playlist_file(base_hls_dir: &Path) -> Option<PathBuf> {
        if let Some(master_content) = Self::build_master_playlist(base_hls_dir) {
            let master_path = base_hls_dir.join("master.m3u8");
            if let Ok(()) = std::fs::write(&master_path, master_content) {
                return Some(master_path);
            }
        }
        None
    }

    /// Check if base HLS directory contains multiple active quality tiers.
    pub fn has_multiple_qualities(base_hls_dir: &Path) -> bool {
        let mut count = 0;
        for (label, _, _, _, _) in Self::STANDARD_QUALITIES {
            let q_pl = base_hls_dir.join(label).join("playlist.m3u8");
            if q_pl.is_file() {
                count += 1;
                if count >= 2 {
                    return true;
                }
            }
        }
        false
    }

    /// Resolve the authoritative HLS cache directory for a given video path and optional quality tier.
    pub fn find_hls_quality_dir(
        path: &Path,
        roots: &[PathBuf],
        cache_dir: &Path,
        quality: Option<&str>,
    ) -> PathBuf {
        let base_dir = Self::find_hls_dir(path, roots, cache_dir);
        match quality {
            Some(q) if !q.is_empty() && q != "default" => {
                let q_lower = q.to_ascii_lowercase();
                let norm = match q_lower.as_str() {
                    "4k" | "2160p" | "2160" => "2160p",
                    "2k" | "1440p" | "1440" => "1440p",
                    "1080p" | "1080" | "fhd" => "1080p",
                    "720p" | "720" | "hd" => "720p",
                    "480p" | "480" | "sd" => "480p",
                    "360p" | "360" => "360p",
                    _ => q_lower.as_str(),
                };
                let q_dir = base_dir.join(norm);
                if norm == "1080p" && !q_dir.join("playlist.m3u8").is_file() && base_dir.join("playlist.m3u8").is_file() {
                    base_dir
                } else {
                    q_dir
                }
            }
            _ => {
                if !base_dir.join("playlist.m3u8").is_file() && base_dir.join("1080p").join("playlist.m3u8").is_file() {
                    base_dir.join("1080p")
                } else {
                    base_dir
                }
            }
        }
    }

    /// Check if segment filename matches allowed HLS pattern: init.mp4, init_chunk_\d+.mp4 or segment_\d{6}\.(ts|m4s)
    pub fn is_valid_segment_name(segment: &str) -> bool {
        if segment == "init.mp4" {
            return true;
        }
        if let Some(rest) = segment.strip_prefix("init_chunk_") {
            if let Some(num) = rest.strip_suffix(".mp4") {
                if !num.is_empty() && num.chars().all(|c| c.is_ascii_digit()) {
                    return true;
                }
            }
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
