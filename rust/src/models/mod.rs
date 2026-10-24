pub mod catalog;
pub mod identity;
pub mod media_pipeline;
pub mod ops;

// Re-exports for seamless root and cross-crate compatibility
pub use catalog::{movie, progress};
pub use identity::{audit, auth};
pub use media_pipeline::{preview, subtitle, transcode};
pub use ops::{job, storage, system, upload};
