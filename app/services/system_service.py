"""System status and hardware telemetry service."""
import os
import subprocess
import sys
import threading
import time
from pathlib import Path
import psutil

from app.config import MEDIA_ROOT, CACHE_DIR
from app.utils.formatting import format_bytes_display


class SystemTelemetryTracker:
    """Tracks running deltas for disk I/O, network traffic, and GPU engine utilization."""

    def __init__(self):
        self._last_time = time.time()
        self._last_disk_io = psutil.disk_io_counters()
        self._last_net_io = psutil.net_io_counters()
        self._win_gpu_data = None
        self._gpu_lock = threading.Lock()
        # Initialize CPU percent baseline
        psutil.cpu_percent(interval=None)
        if os.name == "nt" and "pytest" not in sys.modules:
            self._start_gpu_sampler()

    def _start_gpu_sampler(self):
        def _sampler():
            while True:
                time.sleep(2.5)
                try:
                    from app import config
                    has_active = any(
                        p is not None and getattr(p, "poll", lambda: 0)() is None
                        for p in config.HLS_PROCESSES.values()
                    ) or bool(config.ACTIVE_DIRECT_TRANSCODES)

                    if not has_active:
                        with self._gpu_lock:
                            self._win_gpu_data = None
                        continue

                    ps_cmd = (
                        "Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine "
                        "-Filter \"Name LIKE '%Video%'\" | "
                        "Group-Object { if ($_.Name -match 'luid_(0x[0-9a-fA-F]+_0x[0-9a-fA-F]+)') { $matches[1] } } | "
                        "ForEach-Object { [PSCustomObject]@{ LUID = $_.Name; MaxUtil = ($_.Group | Measure-Object -Property UtilizationPercentage -Maximum).Maximum } } | "
                        "ConvertTo-Json"
                    )
                    res = subprocess.run(
                        ["powershell", "-NoProfile", "-Command", ps_cmd],
                        capture_output=True,
                        text=True,
                        timeout=4,
                        check=False,
                    )
                    if res.returncode == 0 and res.stdout.strip():
                        import json
                        raw = json.loads(res.stdout)
                        items = [raw] if isinstance(raw, dict) else raw
                        disp_parts = []
                        max_pct = 0
                        for item in items:
                            luid = str(item.get("LUID", "")).upper()
                            u = item.get("MaxUtil", 0)
                            u = int(u) if u is not None else 0
                            if u > max_pct:
                                max_pct = u
                            if "DD3F" in luid:
                                disp_parts.append(f"RX 560X: {u}%")
                            elif "EA61" in luid:
                                disp_parts.append(f"Vega 8: {u}%")
                            elif u > 0:
                                disp_parts.append(f"GPU: {u}%")

                        with self._gpu_lock:
                            self._win_gpu_data = {
                                "active": True,
                                "percent": max(max_pct, 1),
                                "display": " · ".join(disp_parts) if disp_parts else f"{max_pct}% Busy",
                            }
                    else:
                        with self._gpu_lock:
                            self._win_gpu_data = None
                except Exception:
                    pass

        t = threading.Thread(target=_sampler, name="win-gpu-sampler", daemon=True)
        t.start()

    def get_windows_gpu_data(self):
        with self._gpu_lock:
            return self._win_gpu_data

    def get_rates(self):
        now = time.time()
        dt = max(now - self._last_time, 0.1)

        d_io = psutil.disk_io_counters()
        n_io = psutil.net_io_counters()

        disk_read_rate = 0.0
        disk_write_rate = 0.0
        if d_io and self._last_disk_io:
            disk_read_rate = max(0.0, (d_io.read_bytes - self._last_disk_io.read_bytes) / dt)
            disk_write_rate = max(0.0, (d_io.write_bytes - self._last_disk_io.write_bytes) / dt)

        net_rx_rate = 0.0
        net_tx_rate = 0.0
        if n_io and self._last_net_io:
            net_rx_rate = max(0.0, (n_io.bytes_recv - self._last_net_io.bytes_recv) / dt)
            net_tx_rate = max(0.0, (n_io.bytes_sent - self._last_net_io.bytes_sent) / dt)

        self._last_time = now
        self._last_disk_io = d_io
        self._last_net_io = n_io

        return {
            "disk_read_rate": disk_read_rate,
            "disk_write_rate": disk_write_rate,
            "net_rx_rate": net_rx_rate,
            "net_tx_rate": net_tx_rate,
        }


_tracker = SystemTelemetryTracker()


def _format_rate(bytes_per_sec):
    """Format bytes per second into human readable throughput rate string."""
    if not bytes_per_sec or bytes_per_sec <= 0:
        return "0 KB/s"
    b = float(bytes_per_sec)
    if b < 1024 * 1024:
        return f"{b / 1024:.1f} KB/s"
    elif b < 1024 * 1024 * 1024:
        return f"{b / (1024 * 1024):.1f} MB/s"
    return f"{b / (1024 * 1024 * 1024):.2f} GB/s"


def _get_gpu_telemetry():
    """Extract GPU utilization and VRAM statistics from Windows D3D11/AMF, AMD sysfs, or Nvidia CLI."""
    # 0. Probe Windows GPUs via D3D11 and hardware performance counters
    if os.name == "nt":
        try:
            from app.services.gpu_service import detect_available_gpus
            from app import config
            gpus = detect_available_gpus()

            is_transcoding = any(
                p is not None and getattr(p, "poll", lambda: 0)() is None
                for p in config.HLS_PROCESSES.values()
            ) or bool(config.ACTIVE_DIRECT_TRANSCODES)

            gpu_names = [g.name.replace("Series", "").replace("AMD", "").replace("Graphics", "").strip() for g in gpus] if gpus else ["GPU"]

            win_data = _tracker.get_windows_gpu_data() if hasattr(_tracker, "get_windows_gpu_data") else None
            if win_data and win_data.get("active"):
                return {
                    "available": True,
                    "percent": win_data["percent"],
                    "vram_used": None,
                    "vram_total": None,
                    "card": "d3d11",
                    "label": "Graphics Engine",
                    "display": win_data["display"],
                }
            elif is_transcoding:
                return {
                    "available": True,
                    "percent": 85,
                    "vram_used": None,
                    "vram_total": None,
                    "card": "d3d11",
                    "label": "Graphics Engine",
                    "display": " · ".join(f"{n}: Active" for n in gpu_names),
                }
            else:
                return {
                    "available": False,
                    "percent": 0,
                    "vram_used": None,
                    "vram_total": None,
                    "card": "d3d11",
                    "label": "Graphics Engine",
                    "display": f"Standby · {' & '.join(gpu_names)}" if gpu_names else "Standby",
                }
        except Exception:
            pass

    # 1. Probe AMD sysfs devices (/sys/class/drm/card*/device)
    try:
        drm_path = Path("/sys/class/drm")
        if drm_path.exists():
            for card_dir in sorted(drm_path.glob("card[0-9]")):
                busy_file = card_dir / "device" / "gpu_busy_percent"
                if busy_file.exists():
                    try:
                        busy_val = int(busy_file.read_text().strip())
                        vram_used = None
                        vram_total = None
                        u_f = card_dir / "device" / "mem_info_vram_used"
                        t_f = card_dir / "device" / "mem_info_vram_total"
                        if u_f.exists() and t_f.exists():
                            vram_used = int(u_f.read_text().strip())
                            vram_total = int(t_f.read_text().strip())

                        display_parts = [f"{busy_val}% Busy"]
                        if vram_used is not None and vram_total is not None and vram_total > 0:
                            used_str = f"{vram_used / (1024**3):.1f}"
                            total_str = f"{vram_total / (1024**3):.1f} GB"
                            display_parts.append(f"{used_str} / {total_str} VRAM")

                        return {
                            "available": True,
                            "percent": busy_val,
                            "vram_used": vram_used,
                            "vram_total": vram_total,
                            "card": card_dir.name,
                            "label": "Graphics Engine",
                            "display": " · ".join(display_parts),
                        }
                    except Exception:
                        continue
    except Exception:
        pass

    # 2. Probe Nvidia via nvidia-smi if present
    try:
        res = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=utilization.gpu,memory.used,memory.total",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=1,
        )
        if res.returncode == 0 and res.stdout.strip():
            parts = [p.strip() for p in res.stdout.strip().split(",")]
            if len(parts) >= 3:
                gpu_pct = int(parts[0])
                mem_used_mb = float(parts[1])
                mem_total_mb = float(parts[2])
                return {
                    "available": True,
                    "percent": gpu_pct,
                    "vram_used": int(mem_used_mb * 1024 * 1024),
                    "vram_total": int(mem_total_mb * 1024 * 1024),
                    "card": "nvidia0",
                    "label": "Graphics Engine",
                    "display": f"{gpu_pct}% Busy · {mem_used_mb/1024:.1f} / {mem_total_mb/1024:.1f} GB VRAM",
                }
    except Exception:
        pass

    # Fallback / integrated
    return {
        "available": False,
        "percent": 0,
        "vram_used": None,
        "vram_total": None,
        "card": "drm",
        "label": "Graphics Engine",
        "display": "Standby · Integrated DRM",
    }


def get_system_telemetry():
    """Gather complete live system hardware telemetry."""
    # CPU
    cpu_pct = psutil.cpu_percent(interval=None)
    cpu_cores = psutil.cpu_count(logical=True) or 1

    # RAM
    vmem = psutil.virtual_memory()
    mem_used_str = f"{vmem.used / (1024**3):.1f} GB"
    mem_total_str = f"{vmem.total / (1024**3):.1f} GB"

    # Storage Space (MEDIA_ROOT or root filesystem fallback)
    try:
        storage_path = str(MEDIA_ROOT) if MEDIA_ROOT.exists() else "/"
        du = psutil.disk_usage(storage_path)
    except Exception:
        du = psutil.disk_usage("/")

    storage_used_str = f"{du.used / (1024**3):.1f} GB"
    storage_free_str = f"{du.free / (1024**3):.1f} GB"
    storage_total_str = f"{du.total / (1024**3):.1f} GB"

    # Rates
    rates = _tracker.get_rates()
    disk_read_str = _format_rate(rates["disk_read_rate"])
    disk_write_str = _format_rate(rates["disk_write_rate"])
    net_rx_str = _format_rate(rates["net_rx_rate"])
    net_tx_str = _format_rate(rates["net_tx_rate"])

    # GPU
    gpu_data = _get_gpu_telemetry()

    return {
        "cpu": {
            "percent": round(cpu_pct, 1),
            "cores": cpu_cores,
            "label": "Core Compute",
            "display": f"{round(cpu_pct, 1)}% · {cpu_cores} Cores",
            "sub": f"{cpu_cores} active CPU threads",
        },
        "gpu": gpu_data,
        "memory": {
            "percent": round(vmem.percent, 1),
            "used": vmem.used,
            "total": vmem.total,
            "free": vmem.available,
            "label": "Memory Bank",
            "display": f"{round(vmem.percent, 1)}% · {mem_used_str} / {mem_total_str}",
            "sub": f"{mem_used_str} used of {mem_total_str}",
        },
        "disk_io": {
            "read_rate": round(rates["disk_read_rate"], 1),
            "write_rate": round(rates["disk_write_rate"], 1),
            "read_str": disk_read_str,
            "write_str": disk_write_str,
            "label": "I/O Velocity",
            "display": f"▼ {disk_read_str} R · ▲ {disk_write_str} W",
            "sub": f"Read: {disk_read_str} · Write: {disk_write_str}",
        },
        "storage": {
            "percent": round(du.percent, 1),
            "used": du.used,
            "free": du.free,
            "total": du.total,
            "used_str": storage_used_str,
            "free_str": storage_free_str,
            "total_str": storage_total_str,
            "label": "Storage Pool",
            "display": f"{round(du.percent, 1)}% · {storage_used_str} / {storage_total_str}",
            "sub": f"{storage_free_str} remaining free",
        },
        "network": {
            "rx_rate": round(rates["net_rx_rate"], 1),
            "tx_rate": round(rates["net_tx_rate"], 1),
            "rx_str": net_rx_str,
            "tx_str": net_tx_str,
            "label": "Network Stream",
            "display": f"▼ {net_rx_str} In · ▲ {net_tx_str} Out",
            "sub": f"In: {net_rx_str} · Out: {net_tx_str}",
        },
    }
