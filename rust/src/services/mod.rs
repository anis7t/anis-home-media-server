pub mod casting;
pub mod catalog;
pub mod identity;
pub mod media_pipeline;
pub mod ops;

// Re-exports for seamless root and cross-crate compatibility
pub use casting::{
    cast_control, cast_discovery, cast_origin, cast_proto, cast_registry, cast_transport,
    dlna_service,
};
pub use catalog::{
    asset_service, movie_service, path_resolver, progress_service, scan_service, scanner,
    tmdb_artwork,
};
pub use identity::{audit_service, auth_service, device_service};
pub use media_pipeline::{
    chunk_transcode, gpu_service, hls_service, preview_service, probe_service, range_service,
    subtitle_service, transcode_sweeper, transcode_worker,
};
pub use ops::{job_service, storage_service, system_service, upload_service};
