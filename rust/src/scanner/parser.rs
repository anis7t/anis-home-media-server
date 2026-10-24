use regex::Regex;
use std::path::Path;
use std::sync::OnceLock;

static RE_PREFIX_COPY: OnceLock<Regex> = OnceLock::new();
static RE_TRAILING_DUP: OnceLock<Regex> = OnceLock::new();
static RE_LEADING_BRACKETS: OnceLock<Regex> = OnceLock::new();
static RE_DOTS_UNDERSCORES: OnceLock<Regex> = OnceLock::new();
static RE_YEAR: OnceLock<Regex> = OnceLock::new();
static RE_WHITESPACE: OnceLock<Regex> = OnceLock::new();
static RE_RELEASE_TAGS: OnceLock<Vec<Regex>> = OnceLock::new();
static RE_ALL_DIGITS: OnceLock<Regex> = OnceLock::new();
static RE_HEX_UUID: OnceLock<Regex> = OnceLock::new();
static RE_HAS_DIGIT: OnceLock<Regex> = OnceLock::new();

pub struct FilenameParser;

impl FilenameParser {
    /// Parse a video file path into a sanitized movie title and optional release year.
    ///
    /// Replicates Python `scanner.py::parse_filename` behavior:
    /// 1. Strips download/copy prefixes (`Copy of ...`), duplicate counters `(1)`, leading bracket tags.
    /// 2. Replaces dots and underscores with spaces.
    /// 3. Extracts release year (`19\d{2}|20\d{2}`) and truncates the title at the year's position.
    /// 4. Strips scene release tags (`1080p`, `2160p`, `4K`, `BluRay`, `WEB-DL`, `HEVC`, etc.).
    /// 5. Normalizes whitespace and trims edge punctuation.
    pub fn parse_filename(path: &Path) -> (String, Option<i32>) {
        let stem = path
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();

        let re_copy = RE_PREFIX_COPY.get_or_init(|| Regex::new(r"(?i)^(?:Copy\s+of\s+)+").unwrap());
        let re_dup = RE_TRAILING_DUP.get_or_init(|| Regex::new(r"\s*\(\d+\)$").unwrap());
        let re_brackets = RE_LEADING_BRACKETS.get_or_init(|| Regex::new(r"^[【\[].*?[】\]]\s*").unwrap());
        let re_dots = RE_DOTS_UNDERSCORES.get_or_init(|| Regex::new(r"[._]+").unwrap());
        let re_year = RE_YEAR.get_or_init(|| Regex::new(r"\b(19\d{2}|20\d{2})\b").unwrap());
        let re_ws = RE_WHITESPACE.get_or_init(|| Regex::new(r"\s+").unwrap());
        let release_tags = RE_RELEASE_TAGS.get_or_init(|| {
            vec![
                Regex::new(r"(?i)\b1080p\b").unwrap(),
                Regex::new(r"(?i)\b2160p\b").unwrap(),
                Regex::new(r"(?i)\b4K\b").unwrap(),
                Regex::new(r"(?i)\b720p\b").unwrap(),
                Regex::new(r"(?i)\b480p\b").unwrap(),
                Regex::new(r"(?i)\bBluRay\b").unwrap(),
                Regex::new(r"(?i)\bBRRip\b").unwrap(),
                Regex::new(r"(?i)\bWEB[- ]?DL\b").unwrap(),
                Regex::new(r"(?i)\bWEBRip\b").unwrap(),
                Regex::new(r"(?i)\bHDRip\b").unwrap(),
                Regex::new(r"(?i)\bDVDRip\b").unwrap(),
                Regex::new(r"(?i)\bHDTV\b").unwrap(),
                Regex::new(r"(?i)\bx264\b").unwrap(),
                Regex::new(r"(?i)\bx265\b").unwrap(),
                Regex::new(r"(?i)\bHEVC\b").unwrap(),
                Regex::new(r"(?i)\bAVC\b").unwrap(),
                Regex::new(r"(?i)\bYIFY\b").unwrap(),
                Regex::new(r"(?i)\bRARBG\b").unwrap(),
            ]
        });

        // 1. Remove prefixes & duplicate counters
        let name = re_copy.replace_all(&stem, "");
        let name = re_dup.replace_all(&name, "");
        let name = re_brackets.replace_all(&name, "");

        // 2. Replace dots and underscores with spaces
        let mut name = re_dots.replace_all(&name, " ").to_string();

        // 3. Find 4-digit release year
        let mut year = None;
        let matches: Vec<(usize, usize)> = re_year
            .find_iter(&name)
            .map(|m| (m.start(), m.end()))
            .collect();

        // Prefer the last match that leaves a non-empty title prefix (start > 0)
        if let Some(&(start, end)) = matches.iter().rev().find(|(start, _)| *start > 0) {
            if let Ok(y) = name[start..end].parse::<i32>() {
                year = Some(y);
                name.truncate(start);
            }
        } else if let Some(&(start, end)) = matches.first() {
            // Only match starts at index 0 (e.g. "1917 ...")
            let matched_year_str = name[start..end].to_string();
            let remainder = &name[end..];
            let mut rem_clean = remainder.to_string();
            for tag_re in release_tags {
                rem_clean = tag_re.replace_all(&rem_clean, "").to_string();
            }
            let rem_trimmed = rem_clean.trim_matches(|c: char| {
                c == ' ' || c == '-' || c == '.' || c == '_' || c == '\'' || c == '"' || c == '(' || c == ')' || c == '[' || c == ']'
            });
            if rem_trimmed.is_empty() {
                // The title IS the year, e.g. "1917"
                year = matched_year_str.parse::<i32>().ok();
                name = matched_year_str;
            }
        }

        // 4. Remove common scene release tags
        for tag_re in release_tags {
            name = tag_re.replace_all(&name, "").to_string();
        }

        // 5. Clean whitespace & edge punctuation (including unclosed brackets/parentheses)
        let clean = re_ws.replace_all(&name, " ").to_string();
        let trimmed = clean
            .trim_matches(|c: char| {
                c == ' ' || c == '-' || c == '.' || c == '_' || c == '\'' || c == '"' || c == '(' || c == ')' || c == '[' || c == ']'
            })
            .to_string();

        (trimmed, year)
    }

    /// Identify anonymous, temporary, camera, or raw upload stems that should not query TMDb.
    ///
    /// Replicates Python `scanner.py::is_anonymous_name`.
    pub fn is_anonymous_name(name_or_stem: &str) -> bool {
        let trimmed = name_or_stem.trim_matches(|c: char| {
            c == ' ' || c == '-' || c == '.' || c == '_' || c == '\'' || c == '"'
        });
        if trimmed.is_empty() {
            return true;
        }

        let re_digits = RE_ALL_DIGITS.get_or_init(|| Regex::new(r"^\d+$").unwrap());
        let re_hex = RE_HEX_UUID.get_or_init(|| Regex::new(r"^[0-9a-fA-F-]{8,}$").unwrap());
        let re_has_digit = RE_HAS_DIGIT.get_or_init(|| Regex::new(r"\d").unwrap());

        if re_digits.is_match(trimmed) || re_hex.is_match(trimmed) {
            return true;
        }

        let prefixes = [
            "vid_", "video_", "mov_", "movie_", "dsc_", "img_", "untitled", "unknown", "file",
            "upload", "stream", "part",
        ];
        let lower = trimmed.to_lowercase();
        for p in prefixes {
            if lower.starts_with(p) && (lower.len() == p.len() || re_has_digit.is_match(&lower)) {
                return true;
            }
        }

        false
    }
}
