use media_server_api::scanner::FilenameParser;
use std::path::Path;

#[test]
fn test_parse_standard_scene_release() {
    let path = Path::new("2001.A.Space.Odyssey.1968.1080p.BluRay.x264-[YTS.AM].mp4");
    let (title, year) = FilenameParser::parse_filename(path);
    assert_eq!(title, "2001 A Space Odyssey");
    assert_eq!(year, Some(1968));
}

#[test]
fn test_parse_modern_hevc_release() {
    let path = Path::new("Alien 3 1992 Assembly Cut 1080p BluRay HEVC x265 5.1 BONE.mkv");
    let (title, year) = FilenameParser::parse_filename(path);
    assert_eq!(title, "Alien 3");
    assert_eq!(year, Some(1992));
}

#[test]
fn test_parse_web_dl_tags() {
    let path = Path::new("28.Years.Later.2025.Proper.1080p.WEB-DL.DDP5.1.x265-NeoNoir.mkv");
    let (title, year) = FilenameParser::parse_filename(path);
    assert_eq!(title, "28 Years Later");
    assert_eq!(year, Some(2025));
}

#[test]
fn test_parse_movie_without_year() {
    let path = Path::new("Spiderman Brand New Day.mkv");
    let (title, year) = FilenameParser::parse_filename(path);
    assert_eq!(title, "Spiderman Brand New Day");
    assert_eq!(year, None);
}

#[test]
fn test_parse_copy_prefix_and_duplicate_count() {
    let path = Path::new("Copy of Copy of The Departed 2006 (2).mp4");
    let (title, year) = FilenameParser::parse_filename(path);
    assert_eq!(title, "The Departed");
    assert_eq!(year, Some(2006));
}

#[test]
fn test_parse_leading_brackets() {
    let path = Path::new("[TorrentGalaxy] Interstellar 2014 2160p UHD.mkv");
    let (title, year) = FilenameParser::parse_filename(path);
    assert_eq!(title, "Interstellar");
    assert_eq!(year, Some(2014));
}

#[test]
fn test_parse_cjk_brackets() {
    let path = Path::new("【SubGroup】 Spirited Away 2001 BluRay 1080p.mkv");
    let (title, year) = FilenameParser::parse_filename(path);
    assert_eq!(title, "Spirited Away");
    assert_eq!(year, Some(2001));
}

#[test]
fn test_parse_dots_and_underscores() {
    let path = Path::new("Blade_Runner_2049_2017_HDRip_x264.mkv");
    let (title, year) = FilenameParser::parse_filename(path);
    assert_eq!(title, "Blade Runner 2049");
    assert_eq!(year, Some(2017));
}

#[test]
fn test_anonymous_stem_detection() {
    assert!(FilenameParser::is_anonymous_name("vid_20241018_120000"));
    assert!(FilenameParser::is_anonymous_name("video_001"));
    assert!(FilenameParser::is_anonymous_name("upload_98765"));
    assert!(FilenameParser::is_anonymous_name("part1"));
    assert!(FilenameParser::is_anonymous_name("123456789"));
    assert!(FilenameParser::is_anonymous_name("6a9cd0a9-32b2-88ce-19d1-94fa"));
    assert!(FilenameParser::is_anonymous_name(""));
    assert!(FilenameParser::is_anonymous_name("   "));

    assert!(!FilenameParser::is_anonymous_name("Inception"));
    assert!(!FilenameParser::is_anonymous_name("The Matrix"));
    assert!(!FilenameParser::is_anonymous_name("2001 A Space Odyssey"));
}
