"""Hardware GPU detection and multi-adapter management service."""
import logging
import os
import re
import shutil
import subprocess
from dataclasses import dataclass
from typing import List, Optional

logger = logging.getLogger(__name__)

_CACHED_GPUS: Optional[List["GPUWorkerConfig"]] = None


@dataclass
class GPUWorkerConfig:
    """Represents a capable hardware encoder device slot."""
    adapter_id: int
    name: str
    backend: str  # 'amf', 'vaapi', or 'cpu'
    is_discrete: bool

    def get_ffmpeg_init_args(self) -> List[str]:
        """Return FFmpeg input / device initialization arguments."""
        if self.backend == "amf":
            return [
                "-init_hw_device", f"d3d11va=dx11:{self.adapter_id}",
                "-init_hw_device", "amf=amf@dx11",
                "-filter_hw_device", "amf",
                "-hwaccel", "d3d11va",
                "-hwaccel_device", str(self.adapter_id),
            ]
        elif self.backend == "vaapi":
            dev = os.environ.get("MEDIA_SERVER_VAAPI_DEVICE", "/dev/dri/renderD128")
            return ["-vaapi_device", dev, "-hwaccel", "vaapi", "-hwaccel_device", dev]
        return []

    def get_ffmpeg_video_args(self) -> List[str]:
        """Return FFmpeg video encoder arguments."""
        if self.backend == "amf":
            return [
                "-vf", "scale=-2:'min(1080,ih)':flags=bicubic,format=nv12",
                "-c:v", "h264_amf",
                "-quality", "speed",
                "-rc", "cqp",
                "-qp_i", "22",
                "-qp_p", "24",
            ]
        elif self.backend == "vaapi":
            return [
                "-vf", "format=nv12,hwupload,scale_vaapi=w=1920:h=-2",
                "-c:v", "h264_vaapi",
                "-qp", "24",
                "-pix_fmt", "nv12",
            ]
        preset = os.environ.get("MEDIA_SERVER_TRANSCODE_PRESET", "superfast")
        crf = os.environ.get("MEDIA_SERVER_TRANSCODE_CRF", "23")
        return [
            "-vf", "scale=-2:1080,format=yuv420p",
            "-c:v", "libx264",
            "-preset", preset,
            "-crf", crf,
            "-pix_fmt", "yuv420p",
        ]


def _probe_d3d11_adapter(adapter_idx: int) -> Optional[GPUWorkerConfig]:
    """Test whether a specific D3D11 adapter supports AMF h264 encoding."""
    ffmpeg = shutil.which("ffmpeg") or "ffmpeg"
    cmd = [
        ffmpeg, "-hide_banner",
        "-init_hw_device", f"d3d11va=dx11:{adapter_idx}",
        "-f", "lavfi", "-i", "color=s=256x256:d=0.08",
        "-c:v", "h264_amf",
        "-f", "null", "-"
    ]
    try:
        res = subprocess.run(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=8,
            check=False,
        )
        if res.returncode == 0:
            m = re.search(r"Using device [0-9a-fA-F:]+ \((.*)\)\.?", res.stderr)
            name = m.group(1).strip() if m else f"D3D11 Adapter {adapter_idx}"
            # Discrete GPU identification heuristic
            is_discrete = any(d in name.lower() for d in ["rx ", "rtx", "geforce", "radeon rx", "dedicated"])
            return GPUWorkerConfig(
                adapter_id=adapter_idx,
                name=name,
                backend="amf",
                is_discrete=is_discrete,
            )
    except Exception as e:
        logger.debug(f"Failed to probe D3D11 adapter {adapter_idx}: {e}")
    return None


def detect_available_gpus(force_refresh: bool = False) -> List[GPUWorkerConfig]:
    """Enumerate hardware encoding adapters available on the host."""
    global _CACHED_GPUS
    if _CACHED_GPUS is not None and not force_refresh:
        return _CACHED_GPUS

    gpus: List[GPUWorkerConfig] = []

    if os.name == "nt":
        # Windows: Check adapters 1 (Discrete) and 0 (Integrated)
        for idx in [1, 0]:
            cfg = _probe_d3d11_adapter(idx)
            if cfg:
                gpus.append(cfg)

    # Sort so discrete GPU is first (highest throughput priority), integrated second
    gpus.sort(key=lambda g: (not g.is_discrete, g.adapter_id != 1))
    _CACHED_GPUS = gpus
    logger.info(f"Detected {len(gpus)} hardware GPU encoder(s): {[g.name for g in gpus]}")
    return gpus


def is_dual_gpu_enabled() -> bool:
    """Check if dual-GPU chunked transcoding is enabled and supported."""
    enabled_by_env = os.environ.get("MEDIA_SERVER_ENABLE_DUAL_GPU", "1").lower() in {"1", "true", "yes"}
    if not enabled_by_env:
        return False
    gpus = detect_available_gpus()
    return len(gpus) >= 2


def get_gpu_workers() -> List[GPUWorkerConfig]:
    """Return the ordered list of GPU workers for chunk assignment."""
    gpus = detect_available_gpus()
    if not gpus:
        # CPU Fallback
        return [GPUWorkerConfig(adapter_id=0, name="CPU Encoder", backend="cpu", is_discrete=False)]
    return gpus
