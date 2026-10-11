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

    def get_ffmpeg_video_args(self, use_vpp_amf: bool = True) -> List[str]:
        """Return FFmpeg video encoder arguments.

        ``use_vpp_amf=False`` drops the vpp_amf scaling stage and lets the
        D3D11VA decoder feed the encoder directly. That is only valid when the
        source needs neither a resize nor a depth change: h264_amf cannot
        accept 10-bit on drivers older than 23.30, and a source taller than the
        1080p profile would be emitted at full height. Select it with
        :func:`select_amf_strategy` rather than by hand.
        """
        if self.backend == "amf":
            vf = "vpp_amf=h='min(1080,ih)':w=-2:format=nv12" if use_vpp_amf else "null"
            return [
                "-vf", vf,
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
            encoding="utf-8",
            errors="replace",
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


# --------------------------------------------------------------------------- #
# Per-source pipeline + worker sizing
# --------------------------------------------------------------------------- #
#
# Measured on this host (2x ffmpeg 9.0.1, RX 560X discrete + Vega 8 integrated,
# 8-core CPU) with verified frame counts rather than wall clock alone:
#
#   source class              vpp_amf   no vpp_amf
#   4K HEVC Main10            1.62x     n/a (must downscale + convert depth)
#   1080p HEVC Main10         4.01x     n/a (10-bit cannot be encoded directly)
#   1080p HEVC Main 8-bit     6.06x     7.19x
#   1080p H.264 Main 8-bit    6.03x     7.06x
#
# vpp_amf is not a pure scaler: for a 10-bit source it is the only thing that
# converts depth to 8-bit, because h264_amf rejects 10-bit on drivers older
# than 23.30. But for an 8-bit source no taller than the 1080p profile it does
# no resize and no conversion at all - it is a full GPU round-trip for nothing,
# and dropping it is worth roughly 19%.
#
# Worker count is per class because the constraint differs: the vpp_amf path
# leaves the CPU partly idle and scales to 3-4 workers, while the faster direct
# path already saturates the encoder with 2.

#: Output height cap of the HLS profile (see the -vf expression above).
HLS_MAX_HEIGHT = 1080


def adaptive_strategy_enabled() -> bool:
    """True when per-source pipeline/worker selection is switched on.

    Defaults OFF so the deployed pipeline is byte-for-byte what it was until
    the segment-layout validation for the direct path has been completed.
    """
    return os.environ.get("MEDIA_SERVER_TRANSCODE_STRATEGY", "legacy").lower() in {"adaptive", "1", "true", "yes"}


def _is_ten_bit(pix_fmt: Optional[str]) -> bool:
    """True for 10-bit pixel formats, which h264_amf cannot accept directly."""
    p = (pix_fmt or "").lower()
    # yuv420p10le, p010le, yuv422p10le, ... - the '10' suffix is the marker.
    return "10" in p


def select_amf_strategy(video_stream: Optional[dict]) -> "tuple[bool, int]":
    """Return ``(use_vpp_amf, worker_count)`` for one source's video stream.

    ``use_vpp_amf`` is required - never merely beneficial - whenever the source
    is 10-bit or taller than the 1080p profile. Getting that wrong is not a
    silent quality regression: the encoder fails to open and the job errors.
    """
    stream = video_stream or {}
    try:
        height = int(stream.get("height") or 0)
    except (TypeError, ValueError):
        height = 0
    ten_bit = _is_ten_bit(stream.get("pix_fmt"))

    # Fail safe: an unprobed source keeps vpp_amf. Guessing "no resize needed"
    # from missing data is the one mistake that would silently emit a 10-bit
    # or oversized stream, so unknown always means the historical pipeline.
    unknown = height <= 0
    needs_vpp = unknown or ten_bit or height > HLS_MAX_HEIGHT

    if unknown:
        count = int(os.environ.get("MEDIA_SERVER_TRANSCODE_WORKERS_MAIN10", "3"))
    elif needs_vpp:
        count = int(os.environ.get("MEDIA_SERVER_TRANSCODE_WORKERS_MAIN10", "3"))
    else:
        count = int(os.environ.get("MEDIA_SERVER_TRANSCODE_WORKERS_8BIT", "2"))
    return needs_vpp, max(1, count)


def expand_workers(workers: List[GPUWorkerConfig], count: int) -> List[GPUWorkerConfig]:
    """Expand one worker per GPU into ``count`` workers, weighted to the discrete GPU.

    Measured throughput is higher with the integrated GPU carrying a single
    chunk and the discrete GPU carrying the rest, so the remainder goes to the
    first discrete adapter.

    Every duplicate gets a distinct ``name``: the chunk scheduler retires a GPU
    for the remainder of a job by name, so shared names would take down all the
    duplicates of that adapter at once and defeat the fallback path.
    """
    if not workers:
        return workers
    if count <= 1:
        return list(workers[:1])

    # Integrated adapters get one slot each; the discrete GPU absorbs the rest.
    discrete = [w for w in workers if w.is_discrete]
    integrated = [w for w in workers if not w.is_discrete]

    plan: List[GPUWorkerConfig] = []
    if discrete:
        remaining = count
        for w in integrated:
            if remaining <= 0:
                break
            plan.append(w)
            remaining -= 1
        primary = discrete[0]
        plan.extend([primary] * remaining)
        # Anything past the requested count still gets a fair share of the
        # remaining integrated adapters rather than being dropped.
        for w in integrated[len(plan):]:
            plan.append(w)
    else:
        plan = [workers[0]] * count

    out: List[GPUWorkerConfig] = []
    seen: dict = {}
    for w in plan:
        n = seen.get(w.name, 0) + 1
        seen[w.name] = n
        out.append(GPUWorkerConfig(
            adapter_id=w.adapter_id,
            name=w.name if n == 1 else f"{w.name}#{n}",
            backend=w.backend,
            is_discrete=w.is_discrete,
        ))
    return out
