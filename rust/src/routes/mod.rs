pub mod casting;
pub mod catalog;
pub mod identity;
pub mod media_pipeline;
pub mod ops;

// Re-exports for seamless root and cross-crate compatibility
pub use casting::cast;
pub use catalog::{assets, movies, progress, scan};
pub use identity::{admin, auth, devices, qr_auth};
pub use media_pipeline::{hls, media, media_info, preview, subtitles, transcode};
pub use ops::{app_dist, health, jobs, spa, storage, system, upload};
