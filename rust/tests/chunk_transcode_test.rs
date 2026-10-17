use media_server_api::services::chunk_transcode::{
    ChunkTranscodeService, SEGMENTS_PER_CHUNK_STRIDE,
};
use std::fs;
use std::sync::atomic::{AtomicUsize, Ordering};

static TEST_COUNTER: AtomicUsize = AtomicUsize::new(0);

#[test]
fn test_plan_chunks_empty_or_zero() {
    assert!(ChunkTranscodeService::plan_chunks(0.0, 60.0).is_empty());
    assert!(ChunkTranscodeService::plan_chunks(-10.0, 60.0).is_empty());
}

#[test]
fn test_plan_chunks_stride_and_boundary_invariants() {
    let duration = 185.0; // 3 full 60s chunks + one 5s chunk
    let chunks = ChunkTranscodeService::plan_chunks(duration, 60.0);

    assert_eq!(chunks.len(), 4);

    // Verify chunk 0
    assert_eq!(chunks[0].chunk_id, 0);
    assert_eq!(chunks[0].start_time, 0.0);
    assert_eq!(chunks[0].duration, 60.0);
    assert_eq!(chunks[0].start_seg, 0);
    assert_eq!(chunks[0].expected_segs, 15); // 60 / 4

    // Verify chunk 1
    assert_eq!(chunks[1].chunk_id, 1);
    assert_eq!(chunks[1].start_time, 60.0);
    assert_eq!(chunks[1].duration, 60.0);
    assert_eq!(chunks[1].start_seg, 32); // 1 * 32
    assert_eq!(chunks[1].expected_segs, 15);

    // Verify chunk 2
    assert_eq!(chunks[2].chunk_id, 2);
    assert_eq!(chunks[2].start_time, 120.0);
    assert_eq!(chunks[2].duration, 60.0);
    assert_eq!(chunks[2].start_seg, 64); // 2 * 32
    assert_eq!(chunks[2].expected_segs, 15);

    // Verify chunk 3
    assert_eq!(chunks[3].chunk_id, 3);
    assert_eq!(chunks[3].start_time, 180.0);
    assert_eq!(chunks[3].duration, 5.0);
    assert_eq!(chunks[3].start_seg, 96); // 3 * 32
    assert_eq!(chunks[3].expected_segs, 1); // round(5 / 4)

    // Stride monotonicity
    for i in 0..chunks.len() {
        assert_eq!(chunks[i].start_seg, i * SEGMENTS_PER_CHUNK_STRIDE);
    }
}

#[test]
fn test_plan_chunks_drops_zero_frame_float_residue() {
    // 600.0000000000002 should NOT emit an 11th chunk of 2e-13s
    let duration = 600.0000000000002;
    let chunks = ChunkTranscodeService::plan_chunks(duration, 60.0);
    assert_eq!(chunks.len(), 10);
    assert_eq!(chunks[9].start_time, 540.0);
    assert_eq!(chunks[9].duration, 60.0);
}

#[test]
fn test_update_master_playlist_discontinuities_and_healing() {
    let count = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
    let hls_dir = std::env::temp_dir().join(format!("rust_chunk_test_{}_{}", std::process::id(), count));
    let _ = fs::remove_dir_all(&hls_dir);
    fs::create_dir_all(&hls_dir).unwrap();
    let playlist_path = hls_dir.join("playlist.m3u8");

    // Create dummy segment files on disk
    // Chunk 0: segment_000000.ts, segment_000001.ts
    // Chunk 1: segment_000032.ts, segment_000033.ts
    fs::write(hls_dir.join("segment_000000.ts"), b"data0").unwrap();
    fs::write(hls_dir.join("segment_000001.ts"), b"data1").unwrap();
    fs::write(hls_dir.join("segment_000032.ts"), b"data32").unwrap();
    fs::write(hls_dir.join("segment_000033.ts"), b"data33").unwrap();

    // Create chunk playlist with custom durations
    let chunk0_pl = "#EXTM3U\n#EXTINF:4.123456,\nsegment_000000.ts\n#EXTINF:3.876544,\nsegment_000001.ts\n";
    fs::write(hls_dir.join("chunk_0.m3u8"), chunk0_pl).unwrap();

    let chunk1_pl = "#EXTM3U\n#EXTINF:4.000000,\nsegment_000032.ts\n#EXTINF:4.000000,\nsegment_000033.ts\n";
    fs::write(hls_dir.join("chunk_1.m3u8"), chunk1_pl).unwrap();

    // 1. Partial update (in progress)
    let encoded_sec = ChunkTranscodeService::update_master_playlist(
        &hls_dir,
        &playlist_path,
        120.0,
        false,
    )
    .unwrap();

    assert!(encoded_sec > 15.0);
    let content = fs::read_to_string(&playlist_path).unwrap();
    assert!(content.contains("#EXT-X-PLAYLIST-TYPE:EVENT"));
    assert!(content.contains("#EXT-X-START:TIME-OFFSET=0"));
    assert!(content.contains("#EXT-X-INDEPENDENT-SEGMENTS"));
    assert!(!content.contains("#EXT-X-ENDLIST"));

    // Verify #EXT-X-DISCONTINUITY is placed right before chunk 1's start segment (segment_000032.ts)
    let disc_pos = content.find("#EXT-X-DISCONTINUITY").expect("must contain discontinuity");
    let seg32_pos = content.find("segment_000032.ts").expect("must contain segment_000032.ts");
    assert!(disc_pos < seg32_pos);

    // 2. Complete update (finished)
    let final_sec = ChunkTranscodeService::update_master_playlist(
        &hls_dir,
        &playlist_path,
        120.0,
        true,
    )
    .unwrap();

    assert_eq!(final_sec, encoded_sec);
    let final_content = fs::read_to_string(&playlist_path).unwrap();
    assert!(!final_content.contains("#EXT-X-PLAYLIST-TYPE:EVENT"));
    assert!(final_content.contains("#EXT-X-ENDLIST"));

    // Verify .seg_layout marker was stamped
    let marker_path = hls_dir.join(".seg_layout");
    assert!(marker_path.is_file());
    assert_eq!(fs::read_to_string(marker_path).unwrap(), "stride32");

    let _ = fs::remove_dir_all(&hls_dir);
}
