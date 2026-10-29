//! Tests for GpuService (pixel format detection, AMF strategy selection, and worker expansion).

use media_server_api::services::gpu_service::{GPUWorkerConfig, GpuBackend, GpuService};
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
    let (needs_vpp, count) = GpuService::select_amf_strategy(Some(&stream_1080p), None);
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
    let (needs_vpp_10bit, count_10bit) = GpuService::select_amf_strategy(Some(&stream_10bit), None);
    assert!(needs_vpp_10bit, "10-bit input requires vpp_amf");
    assert_eq!(count_10bit, 2, "10-bit defaults to 2 workers");

    // 3. 4K stream (height 2160 > 1080) -> vpp_amf IS required for downscaling
    let stream_4k = ProbeStream {
        codec_type: Some("video".into()),
        codec_name: Some("h264".into()),
        width: Some(3840),
        height: Some(2160),
        pix_fmt: Some("yuv420p".into()),
        ..Default::default()
    };
    let (needs_vpp_4k, count_4k) = GpuService::select_amf_strategy(Some(&stream_4k), None);
    assert!(needs_vpp_4k, "4K input requires vpp_amf downscale");
    assert_eq!(count_4k, 2, "4K defaults to 2 workers");

    // 4. Missing/unknown stream -> fails safe to vpp_amf = true
    let (needs_vpp_unknown, _) = GpuService::select_amf_strategy(None, None);
    assert!(
        needs_vpp_unknown,
        "unknown stream must fail safe to vpp_amf"
    );

    // 5. 1080p source scaled to 720p target -> vpp_amf IS required for scaling
    let (needs_vpp_720, count_720) =
        GpuService::select_amf_strategy(Some(&stream_1080p), Some(720));
    assert!(
        needs_vpp_720,
        "1080p source scaled to 720p requires vpp_amf"
    );
    assert_eq!(count_720, 2, "downscaling defaults to 2 workers");
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
fn test_is_ten_bit_detection_extended() {
    // 10-bit, 12-bit, 16-bit formats
    assert!(GpuService::is_ten_bit(Some("yuv420p10le")));
    assert!(GpuService::is_ten_bit(Some("p010le")));
    assert!(GpuService::is_ten_bit(Some("p010be")));
    assert!(GpuService::is_ten_bit(Some("yuv422p10be")));
    assert!(GpuService::is_ten_bit(Some("yuv444p10le")));
    assert!(GpuService::is_ten_bit(Some("yuv420p12le")));
    assert!(GpuService::is_ten_bit(Some("yuv422p12be")));
    assert!(GpuService::is_ten_bit(Some("p016le")));
    assert!(GpuService::is_ten_bit(Some("yuv420p16le")));

    // 8-bit formats must NOT trigger
    assert!(!GpuService::is_ten_bit(Some("yuv420p")));
    assert!(
        !GpuService::is_ten_bit(Some("nv12")),
        "nv12 is 8-bit and must not be flagged"
    );
    assert!(!GpuService::is_ten_bit(Some("nv21")));
    assert!(!GpuService::is_ten_bit(Some("yuvj420p")));
    assert!(!GpuService::is_ten_bit(Some("yuv422p")));
    assert!(!GpuService::is_ten_bit(Some("yuv444p")));
    assert!(!GpuService::is_ten_bit(Some("rgb24")));
    assert!(!GpuService::is_ten_bit(Some("bgr0")));
    assert!(!GpuService::is_ten_bit(None));
    assert!(!GpuService::is_ten_bit(Some("")));
}

#[test]
fn test_select_amf_strategy_all_qualities() {
    let stream_4k_8bit = ProbeStream {
        codec_type: Some("video".into()),
        codec_name: Some("h264".into()),
        width: Some(3840),
        height: Some(2160),
        pix_fmt: Some("yuv420p".into()),
        ..Default::default()
    };

    // 4K downscaling across all quality tiers
    for (target_h, expected_workers) in [(1440, 2), (1080, 2), (720, 2), (480, 2), (360, 2)] {
        let (needs_vpp, count) =
            GpuService::select_amf_strategy(Some(&stream_4k_8bit), Some(target_h));
        assert!(needs_vpp, "4K downscale to {}p requires vpp_amf", target_h);
        assert_eq!(
            count, expected_workers,
            "4K downscale to {}p should allocate {} workers",
            target_h, expected_workers
        );
    }

    // 4K target on 4K 8-bit source -> no scaling needed, 1 dedicated worker to avoid bus contention
    let (needs_vpp_4k, count_4k) =
        GpuService::select_amf_strategy(Some(&stream_4k_8bit), Some(2160));
    assert!(
        !needs_vpp_4k,
        "4K source at 4K target does not require scaling"
    );
    assert_eq!(
        count_4k, 1,
        "4K target allocates 1 dedicated worker to avoid bus contention"
    );

    // 1080p source -> 720p downscaling
    let stream_1080p_8bit = ProbeStream {
        codec_type: Some("video".into()),
        codec_name: Some("h264".into()),
        width: Some(1920),
        height: Some(1080),
        pix_fmt: Some("yuv420p".into()),
        ..Default::default()
    };
    let (needs_vpp_720, count_720) =
        GpuService::select_amf_strategy(Some(&stream_1080p_8bit), Some(720));
    assert!(needs_vpp_720, "1080p to 720p requires vpp_amf");
    assert_eq!(count_720, 2, "downscale requires 2 workers");

    // 720p source -> 720p target (same resolution, 8-bit) -> no vpp, 2 workers
    let stream_720p_8bit = ProbeStream {
        codec_type: Some("video".into()),
        codec_name: Some("h264".into()),
        width: Some(1280),
        height: Some(720),
        pix_fmt: Some("yuv420p".into()),
        ..Default::default()
    };
    let (needs_vpp_same, count_same) =
        GpuService::select_amf_strategy(Some(&stream_720p_8bit), Some(720));
    assert!(!needs_vpp_same, "720p to 720p does not require vpp_amf");
    assert_eq!(count_same, 2, "720p native uses 2 workers");
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

    // Verify all quality tiers produce correct vpp_amf expressions
    let tiers: &[u32] = &[2160, 1440, 1080, 720, 480, 360];
    for &h in tiers {
        let args = amf_worker.get_ffmpeg_video_args(true, Some(h));
        let expected_filter = format!("vpp_amf=h='min({},ih)':w=-2:format=nv12", h);
        assert!(
            args.iter().any(|a| a == &expected_filter),
            "AMF video args for {}p must contain '{}'",
            h,
            expected_filter
        );
        if h >= 2160 {
            assert!(args.contains(&"hevc_amf".to_string()));
            assert!(args.contains(&"hvc1".to_string()));
        } else {
            assert!(args.contains(&"h264_amf".to_string()));
        }
        assert!(args.contains(&"cqp".to_string()));
        assert!(args.contains(&"22".to_string()));
        assert!(args.contains(&"24".to_string()));
    }

    // No VPP: null filter
    let video_args_no_vpp = amf_worker.get_ffmpeg_video_args(false, None);
    assert!(video_args_no_vpp.contains(&"null".to_string()));
    assert!(video_args_no_vpp.contains(&"h264_amf".to_string()));

    // CPU worker dynamic scaling across all tiers
    let cpu_worker = GPUWorkerConfig {
        adapter_id: 0,
        name: "CPU Encoder".into(),
        backend: GpuBackend::Cpu,
        is_discrete: false,
    };
    for &h in tiers {
        let cpu_args = cpu_worker.get_ffmpeg_video_args(true, Some(h));
        let expected_cpu_filter = format!("scale=-2:'min(ih,{})',format=yuv420p", h);
        assert!(
            cpu_args.iter().any(|a| a == &expected_cpu_filter),
            "CPU video args for {}p must contain '{}'",
            h,
            expected_cpu_filter
        );
        if h >= 2160 {
            assert!(cpu_args.contains(&"libx265".to_string()));
            assert!(cpu_args.contains(&"hvc1".to_string()));
        } else {
            assert!(cpu_args.contains(&"libx264".to_string()));
        }
    }

    // VAAPI worker scaling across tiers
    let vaapi_worker = GPUWorkerConfig {
        adapter_id: 0,
        name: "VAAPI Encoder".into(),
        backend: GpuBackend::Vaapi,
        is_discrete: false,
    };
    for &h in tiers {
        let vaapi_args = vaapi_worker.get_ffmpeg_video_args(true, Some(h));
        let expected_vaapi_filter = format!("format=nv12,hwupload,scale_vaapi=w=-2:h={}", h);
        assert!(
            vaapi_args.iter().any(|a| a == &expected_vaapi_filter),
            "VAAPI video args for {}p must contain '{}'",
            h,
            expected_vaapi_filter
        );
        if h >= 2160 {
            assert!(vaapi_args.contains(&"hevc_vaapi".to_string()));
            assert!(vaapi_args.contains(&"hvc1".to_string()));
        } else {
            assert!(vaapi_args.contains(&"h264_vaapi".to_string()));
        }
    }
}

#[test]
fn test_real_hardware_amf_scaling_and_nv12() {
    if !cfg!(windows) {
        return;
    }

    let gpus = GpuService::detect_available_gpus(false);
    let amf_gpu = gpus.iter().find(|g| g.backend == GpuBackend::Amf);
    let worker = match amf_gpu {
        Some(w) => w,
        None => {
            eprintln!("Skipping hardware AMF scaling test: no AMF GPU detected");
            return;
        }
    };

    let temp_dir = std::env::temp_dir().join(format!("amf_scale_test_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&temp_dir);
    std::fs::create_dir_all(&temp_dir).unwrap();

    // 1. Render a 1.0s 1080p 10-bit test pattern downscaled to 720p via vpp_amf
    let mut cmd = std::process::Command::new("ffmpeg");
    cmd.current_dir(&temp_dir);
    cmd.arg("-hide_banner").arg("-y");

    for arg in worker.get_ffmpeg_init_args() {
        cmd.arg(arg);
    }

    cmd.args([
        "-f",
        "lavfi",
        "-i",
        "testsrc2=s=1920x1080:d=1.0,format=yuv420p10le",
        "-f",
        "lavfi",
        "-i",
        "anullsrc=r=44100:cl=stereo",
        "-t",
        "1.0",
    ]);

    for arg in worker.get_ffmpeg_video_args(true, Some(720)) {
        cmd.arg(arg);
    }

    cmd.args([
        "-c:a",
        "aac",
        "-f",
        "hls",
        "-hls_time",
        "1.0",
        "-hls_segment_type",
        "fmp4",
        "-hls_fmp4_init_filename",
        "init_chunk_0.mp4",
        "-hls_segment_filename",
        "segment_%06d.m4s",
        "chunk_0.m3u8",
    ]);

    let output = cmd.output().expect("ffmpeg must spawn");
    assert!(
        output.status.success(),
        "Hardware AMF scaling FFmpeg failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    // 2. Validate output files exist
    let init_file = temp_dir.join("init_chunk_0.mp4");
    let seg_file = temp_dir.join("segment_000000.m4s");
    assert!(init_file.is_file(), "init_chunk_0.mp4 must exist");
    assert!(seg_file.is_file(), "segment_000000.m4s must exist");

    // 3. Probe with ffprobe to verify exact dimensions and NV12 color depth
    let mut probe_cmd = std::process::Command::new("ffprobe");
    probe_cmd.args([
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height,pix_fmt,codec_name",
        "-of",
        "csv=p=0",
        seg_file.to_str().unwrap(),
    ]);

    let probe_out = probe_cmd.output().expect("ffprobe must run");
    if probe_out.status.success() {
        let probe_text = String::from_utf8_lossy(&probe_out.stdout);
        let fields: Vec<&str> = probe_text.trim().split(',').collect();
        // format: codec_name,width,height,pix_fmt
        if fields.len() >= 4 {
            assert_eq!(fields[0], "h264", "Codec must be h264");
            let height: u32 = fields[2].parse().unwrap_or(0);
            assert_eq!(height, 720, "Output height must be 720p");
            let width: u32 = fields[1].parse().unwrap_or(0);
            assert!(
                width > 0 && width % 2 == 0,
                "Width must be even (divisible by 2)"
            );
            assert_eq!(
                fields[3], "nv12",
                "Color depth must be converted to 8-bit nv12"
            );
        }
    }

    let _ = std::fs::remove_dir_all(&temp_dir);
}
