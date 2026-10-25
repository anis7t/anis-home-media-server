//! Consolidated Integration Test Suite for Anis' Home Media Server.
//!
//! Organizes all 34 integration test modules into five domain namespaces
//! while compiling into a single fast binary to avoid multi-target linking overhead on Windows.

mod casting;
mod catalog;
mod identity;
mod media_pipeline;
mod ops;
