use crate::error::AppError;
use crate::models::subtitle::SubtitleTrack;
use std::collections::HashSet;
use std::fs;
use std::path::{Component, Path, PathBuf};

pub struct SubtitleService;

impl SubtitleService {
    /// Convert an SRT-formatted subtitle string to standard WebVTT format,
    /// with optional time offset shifting (in seconds).
    pub fn srt_to_vtt(text: &str, offset_sec: f64) -> String {
        let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
        let mut out = Vec::new();
        out.push("WEBVTT\n".to_string());

        for line in normalized.lines() {
            let trimmed = line.trim();
            // Skip SRT cue index numbers (lines consisting only of digits)
            if trimmed.chars().all(|c| c.is_ascii_digit()) && !trimmed.is_empty() {
                if out.last().map(|l| l.is_empty() || l.starts_with("WEBVTT")).unwrap_or(true) {
                    continue;
                }
            }

            if line.contains("-->") {
                if let Some((start_raw, end_and_rest)) = line.split_once("-->") {
                    let start_ts = start_raw.trim();
                    let trimmed_end = end_and_rest.trim();
                    let (end_ts, rest) = match trimmed_end.split_once(' ') {
                        Some((e, r)) => (e.trim(), format!(" {}", r)),
                        None => (trimmed_end, String::new()),
                    };

                    let s = if offset_sec != 0.0 {
                        Self::shift_timestamp(start_ts, offset_sec)
                    } else {
                        start_ts.replace(',', ".")
                    };

                    let e = if offset_sec != 0.0 {
                        Self::shift_timestamp(end_ts, offset_sec)
                    } else {
                        end_ts.replace(',', ".")
                    };

                    out.push(format!("{} --> {}{}", s, e, rest));
                } else {
                    out.push(line.to_string());
                }
            } else {
                out.push(line.to_string());
            }
        }

        out.join("\n")
    }

    /// Shift a timestamp string (HH:MM:SS.mmm or MM:SS.mmm) by offset_sec.
    pub fn shift_timestamp(ts: &str, offset_sec: f64) -> String {
        let clean = ts.trim().replace(',', ".");
        let parts: Vec<&str> = clean.split(':').collect();
        let (h, m, s) = match parts.len() {
            3 => (
                parts[0].parse::<f64>().unwrap_or(0.0),
                parts[1].parse::<f64>().unwrap_or(0.0),
                parts[2].parse::<f64>().unwrap_or(0.0),
            ),
            2 => (
                0.0,
                parts[0].parse::<f64>().unwrap_or(0.0),
                parts[1].parse::<f64>().unwrap_or(0.0),
            ),
            _ => return ts.to_string(),
        };

        let total_s = (h * 3600.0 + m * 60.0 + s + offset_sec).max(0.0);
        let nh = (total_s / 3600.0).floor() as u64;
        let nm = ((total_s % 3600.0) / 60.0).floor() as u64;
        let ns = total_s % 60.0;
        format!("{:02}:{:02}:{:06.3}", nh, nm, ns)
    }

    /// Detect ISO 639-1 language code from subtitle text content.
    pub fn detect_subtitle_language(text: &str) -> String {
        let lines: Vec<&str> = text
            .lines()
            .map(|l| l.trim())
            .filter(|l| {
                !l.is_empty()
                    && !l.chars().all(|c| c.is_ascii_digit())
                    && !l.contains("-->")
                    && !l.starts_with("WEBVTT")
            })
            .take(100)
            .collect();

        if lines.is_empty() {
            return "und".to_string();
        }

        let sample = lines.join(" ").to_lowercase();

        // 1. Non-Latin Unicode script checks
        for ch in sample.chars() {
            match ch {
                '\u{0900}'..='\u{097F}' => return "hi".to_string(), // Devanagari / Hindi
                '\u{0400}'..='\u{04FF}' => return "ru".to_string(), // Cyrillic / Russian
                '\u{4E00}'..='\u{9FFF}' => return "zh".to_string(), // Hanzi / Chinese
                '\u{3040}'..='\u{30FF}' => return "ja".to_string(), // Hiragana / Katakana
                '\u{AC00}'..='\u{D7AF}' => return "ko".to_string(), // Hangul / Korean
                '\u{0600}'..='\u{06FF}' => return "ar".to_string(), // Arabic
                '\u{0980}'..='\u{09FF}' => return "bn".to_string(), // Bengali
                _ => {}
            }
        }

        // 2. Vocabulary stop-word frequency analysis
        let words: HashSet<&str> = sample
            .split(|c: char| !c.is_alphabetic())
            .filter(|w| w.len() >= 2)
            .collect();

        if words.is_empty() {
            return "und".to_string();
        }

        let en_words: HashSet<&str> = [
            "the", "and", "to", "of", "in", "is", "it", "you", "that", "he", "was", "for", "on",
            "are", "with", "as", "his", "they", "at", "have", "this", "from", "or", "had", "by",
            "not", "but", "what", "some", "we", "can", "out", "other", "were", "all", "there",
            "when", "up", "your", "how", "said", "an", "each", "she",
        ]
        .iter()
        .copied()
        .collect();

        let es_words: HashSet<&str> = [
            "que", "de", "no", "la", "el", "es", "en", "lo", "un", "por", "me", "una", "te", "los",
            "se", "con", "para", "mi", "está", "si", "bien", "pero", "yo", "eso", "las", "más",
        ]
        .iter()
        .copied()
        .collect();

        let fr_words: HashSet<&str> = [
            "de", "je", "est", "pas", "que", "le", "la", "tu", "un", "il", "et", "ce", "en", "on",
            "une", "les", "pour", "des", "dans", "moi", "qui", "nous", "elle", "mais", "du",
        ]
        .iter()
        .copied()
        .collect();

        let de_words: HashSet<&str> = [
            "das", "ist", "du", "nicht", "die", "es", "und", "sie", "der", "was", "wir", "zu",
            "ein", "ich", "in", "dem", "mit", "den", "so", "eine", "auf", "mich", "dass",
        ]
        .iter()
        .copied()
        .collect();

        let it_words: HashSet<&str> = [
            "che", "non", "di", "la", "il", "un", "sono", "per", "una", "in", "mi", "ho", "ma",
            "ha", "si", "lo", "ti", "le", "cosa", "con", "ci", "io", "questo", "bene",
        ]
        .iter()
        .copied()
        .collect();

        let pt_words: HashSet<&str> = [
            "que", "não", "de", "um", "para", "uma", "com", "ele", "em", "os", "no", "se", "na",
            "por", "mais", "as", "dos", "como", "mas", "foi", "ao", "das",
        ]
        .iter()
        .copied()
        .collect();

        let scores = [
            ("en", words.intersection(&en_words).count()),
            ("es", words.intersection(&es_words).count()),
            ("fr", words.intersection(&fr_words).count()),
            ("de", words.intersection(&de_words).count()),
            ("it", words.intersection(&it_words).count()),
            ("pt", words.intersection(&pt_words).count()),
        ];

        let mut best_lang = "und";
        let mut best_score = 0;
        for (lang, score) in scores {
            if score > best_score {
                best_score = score;
                best_lang = lang;
            }
        }

        if best_score >= 3 {
            return best_lang.to_string();
        }
        if words.intersection(&en_words).count() >= 1 {
            return "en".to_string();
        }

        "und".to_string()
    }

    /// Derive normalized short movie name (e.g. "gladiator", "the_odyssey").
    pub fn get_short_movie_name(path: &Path) -> String {
        let stem = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("video");

        let clean: String = stem
            .chars()
            .map(|c| if c.is_alphanumeric() { c.to_ascii_lowercase() } else { '_' })
            .collect();

        let trimmed = clean.trim_matches('_');
        if trimmed.is_empty() {
            "video".to_string()
        } else {
            trimmed.to_string()
        }
    }

    /// Resolve a sidecar subtitle file next to the video or across mirror storage roots.
    pub fn resolve_sidecar_file(
        video_path: &Path,
        name: &str,
        roots: &[PathBuf],
    ) -> Result<PathBuf, AppError> {
        let ext = Path::new(name)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_lowercase();

        if ext != "srt" && ext != "vtt" {
            return Err(AppError::BadRequest(
                "Only .srt and .vtt subtitles are supported".to_string(),
            ));
        }

        // Traversal rejection for subtitle name
        for comp in Path::new(name).components() {
            match comp {
                Component::ParentDir | Component::Prefix(_) | Component::RootDir => {
                    return Err(AppError::Forbidden("Invalid subtitle name".to_string()));
                }
                _ => {}
            }
        }

        let parent_dir = video_path.parent().ok_or_else(|| {
            AppError::NotFound("Video directory not found".to_string())
        })?;

        // 1. Direct sibling in video's directory
        let direct_candidate = parent_dir.join(name);
        if direct_candidate.is_file() {
            return Self::verify_containment(&direct_candidate, roots);
        }

        // 2. Cross-root mirror discovery (e.g. archived media)
        for root in roots {
            if let Ok(rel) = parent_dir.strip_prefix(root) {
                let clean_parts: Vec<_> = rel
                    .components()
                    .filter(|c| c.as_os_str() != ".archive")
                    .collect();
                let mut clean_rel = PathBuf::new();
                for p in clean_parts {
                    clean_rel.push(p.as_os_str());
                }

                for other_root in roots {
                    let cand = other_root.join(&clean_rel).join(name);
                    if cand.is_file() {
                        return Self::verify_containment(&cand, roots);
                    }
                }
            }
        }

        // 3. Fallback to root directly
        for root in roots {
            let cand = root.join(name);
            if cand.is_file() {
                return Self::verify_containment(&cand, roots);
            }
        }

        Err(AppError::NotFound(format!("Subtitle '{}' not found", name)))
    }

    fn verify_containment(path: &Path, roots: &[PathBuf]) -> Result<PathBuf, AppError> {
        if let Ok(canon_path) = path.canonicalize() {
            for root in roots {
                if let Ok(canon_root) = root.canonicalize() {
                    if canon_path.starts_with(&canon_root) {
                        return Ok(canon_path);
                    }
                }
            }
        }
        Err(AppError::Forbidden("Subtitle outside authorized media roots".to_string()))
    }

    /// Discover available local sidecar subtitle tracks for a movie.
    pub fn list_tracks(
        video_path: &Path,
        rel_filename: &str,
        roots: &[PathBuf],
    ) -> Vec<SubtitleTrack> {
        let mut results = Vec::new();
        let mut seen_names = HashSet::new();

        let video_stem = video_path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_lowercase();
        let short_name = Self::get_short_movie_name(video_path);

        let parent_dir = match video_path.parent() {
            Some(p) => p,
            None => return results,
        };

        // Collect search directories: parent_dir + mirror directories across roots
        let mut search_dirs = vec![parent_dir.to_path_buf()];
        for root in roots {
            if let Ok(rel) = parent_dir.strip_prefix(root) {
                let clean_parts: Vec<_> = rel
                    .components()
                    .filter(|c| c.as_os_str() != ".archive")
                    .collect();
                let mut clean_rel = PathBuf::new();
                for p in clean_parts {
                    clean_rel.push(p.as_os_str());
                }
                for other_root in roots {
                    let cand_dir = other_root.join(&clean_rel);
                    if cand_dir.is_dir() && !search_dirs.contains(&cand_dir) {
                        search_dirs.push(cand_dir);
                    }
                }
            }
        }

        for dir in search_dirs {
            let entries = match fs::read_dir(dir) {
                Ok(e) => e,
                Err(_) => continue,
            };

            for entry in entries.flatten() {
                let sub_path = entry.path();
                if !sub_path.is_file() {
                    continue;
                }

                let ext = sub_path
                    .extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or("")
                    .to_lowercase();

                if ext != "srt" && ext != "vtt" {
                    continue;
                }

                let sub_name = match sub_path.file_name().and_then(|n| n.to_str()) {
                    Some(n) => n.to_string(),
                    None => continue,
                };

                if seen_names.contains(&sub_name) {
                    continue;
                }

                let sub_stem = sub_path
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("")
                    .to_lowercase();

                let is_match = sub_stem == video_stem
                    || sub_stem.starts_with(&(video_stem.clone() + "."))
                    || sub_stem.starts_with(&(short_name.clone() + "_"));

                if is_match {
                    seen_names.insert(sub_name.clone());

                    // Read content for language detection
                    let text = fs::read_to_string(&sub_path).unwrap_or_default();
                    let lang = Self::detect_subtitle_language(&text);

                    let label = match lang.as_str() {
                        "en" => "English",
                        "hi" => "Hindi",
                        "es" => "Spanish",
                        "fr" => "French",
                        "de" => "German",
                        "it" => "Italian",
                        "pt" => "Portuguese",
                        "ru" => "Russian",
                        "ja" => "Japanese",
                        "zh" => "Chinese",
                        "ko" => "Korean",
                        "ar" => "Arabic",
                        "bn" => "Bengali",
                        _ => "Subtitles",
                    };

                    results.push(SubtitleTrack {
                        id: format!("dir:{}", sub_name),
                        name: sub_name.clone(),
                        src: format!("/subtitles/{}/{}", rel_filename, sub_name),
                        lang,
                        label: format!("{} (Local)", label),
                        default: false,
                    });
                }
            }
        }

        // Mark the first English track as default
        for t in &mut results {
            if t.lang == "en" {
                t.default = true;
                break;
            }
        }

        results
    }
}
