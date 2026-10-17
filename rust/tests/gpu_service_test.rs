//! Tests for GpuService (pixel format detection, AMF strategy selection, and worker expansion).

use media_server_api::services::gpu_service::{
    GpuBackend, GPUWorkerConfig, GpuService,
};
use media_server_api::services::probe_service::ProbeStream;

#[test]
fn test_is_ten_bit_detection() {
    assert!(GpuService::is_ten_bit(Some("yuv420p10le")));
    assert!(GpuService::is_ten_bit(Some("p010le")));
    assert!(GpuService::is_ten_bit(Some("yuv422p10be")));
    assert!(GpuService::is_ten_bit(Some("yuv444p10le")));

    assert!(!GpuService::is_ten_bit(Some("yuv420p")));
    assert!(!GpuService::is_ten_bit(Some("nv12")));
    assert!(!GpuService::is_ten_bit(Some("yuvj420p")));
    assert!(!GpuService::is_ten_bit(None));
}

#[test]
fn test_select_amf_strategy_requirements() {
    // 1. Standard 1080p 8-bit stream -> vpp_amf is NOT needed
    let stream_1080p = ProbeStream {
        codec_type: Some("video".into()),
        codec_name: Some("h264".into()),
        width: Some(1920),
        height: Some(1080),
        pix_fmt: Some("yuv420p".into()),
        ..Default::default()
    };
    let (needs_vpp, count) = GpuService::select_amf_strategy(Some(&stream_1080p));
    assert!(!needs_vpp, "1080p 8-bit does not require vpp_amf");
    assert_eq!(count, 2, "8-bit standard defaults to 2 workers");

    // 2. 1080p 10-bit stream -> vpp_amf IS required for depth conversion
    let stream_10bit = ProbeStream {
        codec_type: Some("video".into()),
        codec_name: Some("hevc".into()),
        width: Some(1920),
        height: Some(1080),
        pix_fmt: Some("yuv420p10le".into()),
        ..Default::default()
    };
    let (needs_vpp_10bit, count_10bit) = GpuService::select_amf_strategy(Some(&stream_10bit));
    assert!(needs_vpp_10bit, "10-bit input requires vpp_amf");
    assert_eq!(count_10bit, 3, "10-bit defaults to 3 workers");

    // 3. 4K stream (height 2160 > 1080) -> vpp_amf IS required for downscaling
    let stream_4k = ProbeStream {
        codec_type: Some("video".into()),
        codec_name: Some("h264".into()),
        width: Some(3840),
        height: Some(2160),
        pix_fmt: Some("yuv420p".into()),
        ..Default::default()
    };
    let (needs_vpp_4k, count_4k) = GpuService::select_amf_strategy(Some(&stream_4k));
    assert!(needs_vpp_4k, "4K input requires vpp_amf downscale");
    assert_eq!(count_4k, 3, "4K defaults to 3 workers");

    // 4. Missing/unknown stream -> fails safe to vpp_amf = true
    let (needs_vpp_unknown, _) = GpuService::select_amf_strategy(None);
    assert!(needs_vpp_unknown, "unknown stream must fail safe to vpp_amf");
}

#[test]
fn test_expand_workers_discrete_and_integrated_allocation() {
    let discrete = GPUWorkerConfig {
        adapter_id: 1,
        name: "Radeon RX 560X".into(),
        backend: GpuBackend::Amf,
        is_discrete: true,
    };
    let integrated = GPUWorkerConfig {
        adapter_id: 0,
        name: "Radeon Vega 8".into(),
        backend: GpuBackend::Amf,
        is_discrete: false,
    };

    let base = vec![discrete.clone(), integrated.clone()];

    // Expand to 2 workers -> 1 integrated + 1 discrete
    let expanded_2 = GpuService::expand_workers(&base, 2);
    assert_eq!(expanded_2.len(), 2);
    assert_eq!(expanded_2[0].name, "Radeon Vega 8");
    assert_eq!(expanded_2[1].name, "Radeon RX 560X");

    // Expand to 3 workers -> 1 integrated + 2 discrete (with distinct names)
    let expanded_3 = GpuService::expand_workers(&base, 3);
    assert_eq!(expanded_3.len(), 3);
    assert_eq!(expanded_3[0].name, "Radeon Vega 8");
    assert_eq!(expanded_3[1].name, "Radeon RX 560X");
    assert_eq!(expanded_3[2].name, "Radeon RX 560X#2");
    assert_eq!(expanded_3[2].adapter_id, 1);
}

#[test]
fn test_ffmpeg_arguments_generation() {
    let amf_worker = GPUWorkerConfig {
        adapter_id: 1,
        name: "Radeon RX 560X".into(),
        backend: GpuBackend::Amf,
        is_discrete: true,
    };

    let init_args = amf_worker.get_ffmpeg_init_args();
    assert!(init_args.contains(&"d3d11va=dx11:1".to_string()));
    assert!(init_args.contains(&"amf=amf@dx11".to_string()));

    let video_args_vpp = amf_worker.get_ffmpeg_video_args(true);
    assert!(video_args_vpp.iter().any(|a| a.contains("vpp_amf")));
    assert!(video_args_vpp.contains(&"h264_amf".to_string()));

    let video_args_no_vpp = amf_worker.get_ffmpeg_video_args(false);
    assert!(video_args_no_vpp.contains(&"null".to_string()));
    assert!(video_args_no_vpp.contains(&"h264_amf".to_string()));
}
