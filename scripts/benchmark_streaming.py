#!/usr/bin/env python3
"""Production Concurrency & Streaming Benchmark Suite for Media Server.

Evaluates Waitress WSGI thread pool capacity, local vs Cloudflare remote latency,
direct RFC 7233 byte-range throughput, HLS segment delivery, and mixed streaming/API load.

Usage:
    python scripts/benchmark_streaming.py [--target {local,remote,both}] [--levels 1,2,4,8,12,16,24] [--duration 10]
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import statistics
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import psutil

# Add project root to sys.path
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from app import config
from app.services import media_service, transcode_service
from app.utils.filesystem import get_rel_path

# Benchmark targets
LOCAL_ORIGIN = "http://127.0.0.1:8000"
REMOTE_TUNNEL = "https://media.anisparvez.in"

# Benchmark client User-Agent (avoids Cloudflare WAF bot block on default python-urllib)
BENCHMARK_USER_AGENT = "MediaServerClient/1.0 (Windows NT 10.0; Win64; x64) BenchmarkEngine/2026.10"

# Chunk configuration for simulated players
CHUNK_SIZE_BYTES = 2 * 1024 * 1024  # 2 MB per Range request
CHUNKS_PER_STREAM = 4                # 4 chunks = 8 MB per client session
INTER_CHUNK_DELAY = 0.2              # 200ms simulated buffer playback delay


@dataclass
class HardwareTelemetry:
    samples: int = 0
    cpu_percent_avg: float = 0.0
    cpu_percent_max: float = 0.0
    mem_used_mb_avg: float = 0.0
    mem_percent_avg: float = 0.0
    waitress_mem_mb: float = 0.0
    waitress_threads: int = 0
    disk_read_mbps: float = 0.0
    disk_write_mbps: float = 0.0
    net_sent_mbps: float = 0.0
    net_recv_mbps: float = 0.0


class HardwareSampler:
    """Samples Windows host telemetry during benchmark phases."""

    def __init__(self, target_pid: int | None = None):
        self.snapshots: list[dict] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._target_pid = target_pid
        # Baseline CPU initialization
        psutil.cpu_percent(interval=None)

    def start(self):
        self._stop.clear()
        self.snapshots.clear()
        self._thread = threading.Thread(target=self._run, name="hw-sampler", daemon=True)
        self._thread.start()

    def stop(self) -> HardwareTelemetry:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=3.0)

        if not self.snapshots:
            return HardwareTelemetry()

        cpu_vals = [s["cpu"] for s in self.snapshots]
        mem_vals = [s["mem_mb"] for s in self.snapshots]
        mem_pcts = [s["mem_pct"] for s in self.snapshots]
        w_mem = [s["waitress_mem"] for s in self.snapshots if s["waitress_mem"] > 0]
        w_thr = [s["waitress_thr"] for s in self.snapshots if s["waitress_thr"] > 0]
        disk_r = [s["disk_r"] for s in self.snapshots]
        disk_w = [s["disk_w"] for s in self.snapshots]
        net_s = [s["net_s"] for s in self.snapshots]
        net_r = [s["net_r"] for s in self.snapshots]

        return HardwareTelemetry(
            samples=len(self.snapshots),
            cpu_percent_avg=round(statistics.mean(cpu_vals), 1),
            cpu_percent_max=round(max(cpu_vals), 1),
            mem_used_mb_avg=round(statistics.mean(mem_vals), 1),
            mem_percent_avg=round(statistics.mean(mem_pcts), 1),
            waitress_mem_mb=round(statistics.mean(w_mem), 1) if w_mem else 0.0,
            waitress_threads=int(statistics.mean(w_thr)) if w_thr else 0,
            disk_read_mbps=round(statistics.mean(disk_r), 2),
            disk_write_mbps=round(statistics.mean(disk_w), 2),
            net_sent_mbps=round(statistics.mean(net_s), 2),
            net_recv_mbps=round(statistics.mean(net_r), 2),
        )

    def _run(self):
        last_time = time.monotonic()
        last_disk = psutil.disk_io_counters()
        last_net = psutil.net_io_counters()

        while not self._stop.wait(1.0):
            now = time.monotonic()
            dt = max(now - last_time, 0.1)

            cpu = psutil.cpu_percent(interval=None)
            vm = psutil.virtual_memory()

            # Waitress process metrics
            w_mem_mb = 0.0
            w_thr_cnt = 0
            if self._target_pid:
                try:
                    p = psutil.Process(self._target_pid)
                    w_mem_mb = p.memory_info().rss / 1024 / 1024
                    w_thr_cnt = p.num_threads()
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    pass

            # Disk and Network rates
            d_io = psutil.disk_io_counters()
            n_io = psutil.net_io_counters()

            dr_rate = ((d_io.read_bytes - last_disk.read_bytes) / dt) / 1024 / 1024 if d_io and last_disk else 0.0
            dw_rate = ((d_io.write_bytes - last_disk.write_bytes) / dt) / 1024 / 1024 if d_io and last_disk else 0.0
            ns_rate = (((n_io.bytes_sent - last_net.bytes_sent) * 8) / dt) / 1_000_000 if n_io and last_net else 0.0
            nr_rate = (((n_io.bytes_recv - last_net.bytes_recv) * 8) / dt) / 1_000_000 if n_io and last_net else 0.0

            last_disk = d_io
            last_net = n_io
            last_time = now

            self.snapshots.append({
                "cpu": cpu,
                "mem_mb": vm.used / 1024 / 1024,
                "mem_pct": vm.percent,
                "waitress_mem": w_mem_mb,
                "waitress_thr": w_thr_cnt,
                "disk_r": max(dr_rate, 0.0),
                "disk_w": max(dw_rate, 0.0),
                "net_s": max(ns_rate, 0.0),
                "net_r": max(nr_rate, 0.0),
            })


@dataclass
class StreamSessionResult:
    session_id: int
    success: bool = False
    ttfb_s: float = 0.0
    total_bytes: int = 0
    total_time_s: float = 0.0
    throughput_mbps: float = 0.0
    status_codes: list[int] = field(default_factory=list)
    chunks_ok: int = 0
    chunks_failed: int = 0
    error: str = ""


@dataclass
class ConcurrencyLevelReport:
    target: str
    workload: str
    concurrency: int
    total_sessions: int
    success_sessions: int
    failed_sessions: int
    success_rate_percent: float
    ttfb_min_ms: float
    ttfb_p50_ms: float
    ttfb_p95_ms: float
    ttfb_max_ms: float
    avg_stream_throughput_mbps: float
    min_stream_throughput_mbps: float
    aggregate_bandwidth_mbps: float
    total_bytes_transferred: int
    duration_s: float
    telemetry: HardwareTelemetry
    status_distribution: dict[int, int]
    error_summary: list[str]


def _find_test_media() -> tuple[str, str, str | None, str | None]:
    """Find a direct MP4 and an HLS stream in the active library."""
    direct_mp4 = ""
    direct_size = 0
    hls_media_path = None
    hls_dir_name = None

    for p in media_service.video_paths():
        rel = get_rel_path(p).replace("\\", "/")
        if p.suffix.lower() == ".mp4" and not direct_mp4:
            direct_mp4 = rel
            direct_size = p.stat().st_size

        # Check if this video has a valid HLS cache directory with playlist.m3u8
        h_dir = transcode_service.hls_cache_dir(p)
        if (h_dir / "playlist.m3u8").exists() and not hls_media_path:
            hls_media_path = rel
            hls_dir_name = h_dir.name

    return direct_mp4, str(direct_size), hls_media_path, hls_dir_name


def _simulate_direct_stream(
    session_id: int,
    base_url: str,
    media_rel_path: str,
    file_size: int,
) -> StreamSessionResult:
    """Simulate a video player reading sequential 2MB byte ranges."""
    res = StreamSessionResult(session_id=session_id)
    encoded = urllib.parse.quote(media_rel_path)
    url = f"{base_url}/media/{encoded}"

    # Stagger starting positions across the file
    start_offset = (session_id * 35 * 1024 * 1024) % max(file_size // 2, 1024 * 1024)
    step = min(file_size // (CHUNKS_PER_STREAM + 2), 50 * 1024 * 1024)

    t_start = time.monotonic()
    ttfb_captured = False

    for i in range(CHUNKS_PER_STREAM):
        chunk_start = start_offset + (i * step)
        chunk_end = min(chunk_start + CHUNK_SIZE_BYTES - 1, file_size - 1)
        if chunk_end <= chunk_start:
            chunk_start = 0
            chunk_end = min(CHUNK_SIZE_BYTES - 1, file_size - 1)

        headers = {
            "Range": f"bytes={chunk_start}-{chunk_end}",
            "User-Agent": BENCHMARK_USER_AGENT,
            "Accept": "*/*",
        }
        req = urllib.request.Request(url, headers=headers)

        t_req = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=20.0) as resp:
                data = resp.read()
                t_resp = time.monotonic()
                if not ttfb_captured:
                    res.ttfb_s = t_resp - t_req
                    ttfb_captured = True
                res.status_codes.append(resp.status)
                res.total_bytes += len(data)
                res.chunks_ok += 1
        except urllib.error.HTTPError as he:
            res.status_codes.append(he.code)
            res.chunks_failed += 1
            res.error = f"HTTP {he.code}: {he.reason}"
        except Exception as e:
            res.chunks_failed += 1
            res.error = f"{type(e).__name__}: {str(e)[:80]}"

        if i < CHUNKS_PER_STREAM - 1:
            time.sleep(INTER_CHUNK_DELAY)

    elapsed = max(time.monotonic() - t_start, 0.001)
    res.total_time_s = elapsed
    res.throughput_mbps = round((res.total_bytes * 8) / elapsed / 1_000_000, 2)
    res.success = res.chunks_failed == 0 and res.chunks_ok > 0
    return res


def _simulate_hls_stream(
    session_id: int,
    base_url: str,
    hls_media_path: str,
) -> StreamSessionResult:
    """Simulate an HLS video player fetching playlist.m3u8 and consecutive segments."""
    res = StreamSessionResult(session_id=session_id)
    encoded = urllib.parse.quote(hls_media_path)
    playlist_url = f"{base_url}/hls/{encoded}/playlist.m3u8"

    t_start = time.monotonic()
    headers = {"User-Agent": BENCHMARK_USER_AGENT, "Accept": "*/*"}
    req = urllib.request.Request(playlist_url, headers=headers)

    segments: list[str] = []
    t_req = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=20.0) as resp:
            content = resp.read().decode("utf-8", errors="ignore")
            t_resp = time.monotonic()
            res.ttfb_s = t_resp - t_req
            res.status_codes.append(resp.status)
            res.total_bytes += len(content)
            res.chunks_ok += 1
            # Extract .ts or .m4s segment filenames
            for line in content.splitlines():
                line = line.strip()
                if line and not line.startswith("#") and (".ts" in line or ".m4s" in line):
                    segments.append(line)
    except Exception as e:
        res.chunks_failed += 1
        res.error = f"Playlist fetch failed: {str(e)[:80]}"
        res.total_time_s = time.monotonic() - t_start
        return res

    # 2. Fetch up to 4 consecutive segments
    if not segments:
        res.chunks_failed += 1
        res.error = "No segments found in playlist"
        res.total_time_s = time.monotonic() - t_start
        return res

    start_idx = session_id % len(segments)
    target_segments = segments[start_idx: start_idx + 4]
    if len(target_segments) < 4:
        target_segments.extend(segments[: 4 - len(target_segments)])

    for seg in target_segments:
        seg_url = f"{base_url}/hls/{encoded}/{seg}"
        s_req = urllib.request.Request(seg_url, headers=headers)
        try:
            with urllib.request.urlopen(s_req, timeout=25.0) as s_resp:
                s_data = s_resp.read()
                res.status_codes.append(s_resp.status)
                res.total_bytes += len(s_data)
                res.chunks_ok += 1
        except Exception as e:
            res.chunks_failed += 1
            res.error = f"Segment {seg} failed: {str(e)[:80]}"

        time.sleep(INTER_CHUNK_DELAY)

    elapsed = max(time.monotonic() - t_start, 0.001)
    res.total_time_s = elapsed
    res.throughput_mbps = round((res.total_bytes * 8) / elapsed / 1_000_000, 2)
    res.success = res.chunks_failed == 0 and res.chunks_ok > 0
    return res


def _simulate_api_stream(session_id: int, base_url: str) -> StreamSessionResult:
    """Simulate lightweight API polling during streaming load."""
    res = StreamSessionResult(session_id=session_id)
    endpoints = ["/api/movies", "/api/system/status", "/api/admin/status", "/api/devices"]
    url = f"{base_url}{endpoints[session_id % len(endpoints)]}"
    t_start = time.monotonic()
    req = urllib.request.Request(url, headers={"User-Agent": BENCHMARK_USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=15.0) as resp:
            data = resp.read()
            dt = time.monotonic() - t_start
            res.ttfb_s = dt
            res.total_time_s = dt
            res.total_bytes = len(data)
            res.status_codes.append(resp.status)
            res.chunks_ok = 1
            res.throughput_mbps = round((len(data) * 8) / max(dt, 0.001) / 1_000_000, 2)
            res.success = resp.status == 200
    except Exception as e:
        res.chunks_failed = 1
        res.error = f"API probe failed: {str(e)[:80]}"
        res.total_time_s = time.monotonic() - t_start
        res.success = False
    return res


def run_benchmark_level(
    concurrency: int,
    base_url: str,
    workload: str,
    media_path: str,
    file_size: int,
    hls_media_path: str | None,
    sampler: HardwareSampler,
) -> ConcurrencyLevelReport:
    """Execute a single concurrency level and collect telemetry and metrics."""
    target_label = "Local Origin" if "127.0.0.1" in base_url else "Cloudflare Tunnel"
    print(f"\n---> [{target_label}] Workload: {workload.upper()} | Concurrency: {concurrency} clients", flush=True)

    sampler.start()
    t_start = time.monotonic()
    results: list[StreamSessionResult] = []

    with ThreadPoolExecutor(max_workers=concurrency) as executor:
        if workload == "direct":
            futures = [
                executor.submit(_simulate_direct_stream, i, base_url, media_path, file_size)
                for i in range(concurrency)
            ]
        elif workload == "hls" and hls_media_path:
            futures = [
                executor.submit(_simulate_hls_stream, i, base_url, hls_media_path)
                for i in range(concurrency)
            ]
        elif workload == "mixed":
            # 75% video streaming + 25% API traffic
            futures = []
            for i in range(concurrency):
                if i % 4 == 0:
                    # Simulated API caller
                    futures.append(executor.submit(_simulate_api_stream, i, base_url))
                else:
                    futures.append(executor.submit(_simulate_direct_stream, i, base_url, media_path, file_size))
        else:
            futures = [
                executor.submit(_simulate_direct_stream, i, base_url, media_path, file_size)
                for i in range(concurrency)
            ]

        for fut in as_completed(futures):
            try:
                results.append(fut.result())
            except Exception as e:
                err_res = StreamSessionResult(session_id=-1, error=str(e)[:80])
                results.append(err_res)

    duration = max(time.monotonic() - t_start, 0.1)
    telemetry = sampler.stop()

    # Calculate statistics
    successes = [r for r in results if r.success]
    failures = [r for r in results if not r.success]
    ttfbs = sorted([r.ttfb_s * 1000 for r in results if r.ttfb_s > 0])
    throughputs = [r.throughput_mbps for r in successes if r.throughput_mbps > 0]
    total_bytes = sum(r.total_bytes for r in results)

    status_dist: dict[int, int] = {}
    for r in results:
        for code in r.status_codes:
            status_dist[code] = status_dist.get(code, 0) + 1

    error_list = list({r.error for r in failures if r.error})

    report = ConcurrencyLevelReport(
        target=target_label,
        workload=workload,
        concurrency=concurrency,
        total_sessions=len(results),
        success_sessions=len(successes),
        failed_sessions=len(failures),
        success_rate_percent=round((len(successes) / max(len(results), 1)) * 100, 1),
        ttfb_min_ms=round(min(ttfbs), 1) if ttfbs else 0.0,
        ttfb_p50_ms=round(statistics.median(ttfbs), 1) if ttfbs else 0.0,
        ttfb_p95_ms=round(ttfbs[int(len(ttfbs) * 0.95)], 1) if len(ttfbs) >= 5 else (ttfbs[-1] if ttfbs else 0.0),
        ttfb_max_ms=round(max(ttfbs), 1) if ttfbs else 0.0,
        avg_stream_throughput_mbps=round(statistics.mean(throughputs), 2) if throughputs else 0.0,
        min_stream_throughput_mbps=round(min(throughputs), 2) if throughputs else 0.0,
        aggregate_bandwidth_mbps=round((total_bytes * 8) / duration / 1_000_000, 2),
        total_bytes_transferred=total_bytes,
        duration_s=round(duration, 2),
        telemetry=telemetry,
        status_distribution=status_dist,
        error_summary=error_list,
    )

    # Print live level summary
    print(f"      Success Rate : {report.success_rate_percent}% ({report.success_sessions}/{report.total_sessions})")
    print(f"      TTFB Latency : p50={report.ttfb_p50_ms}ms | p95={report.ttfb_p95_ms}ms | max={report.ttfb_max_ms}ms")
    print(f"      Bandwidth    : Aggregate {report.aggregate_bandwidth_mbps} Mbps (Avg {report.avg_stream_throughput_mbps} Mbps/client)")
    print(f"      Host Telemetry: CPU={telemetry.cpu_percent_avg}% (Max {telemetry.cpu_percent_max}%) | Waitress RSS={telemetry.waitress_mem_mb} MB ({telemetry.waitress_threads} threads)")
    if report.failed_sessions > 0:
        print(f"      [WARNING] Failures: {report.failed_sessions} errors: {error_list}")

    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Media Server Concurrency & Streaming Benchmark")
    parser.add_argument(
        "--target",
        choices=["local", "remote", "rust", "both", "all"],
        default="both",
        help="Target to benchmark (default: both local and remote)",
    )
    parser.add_argument(
        "--workload",
        choices=["direct", "hls", "mixed", "all"],
        default="all",
        help="Streaming workload profile to test (default: all)",
    )
    parser.add_argument(
        "--levels",
        type=str,
        default="1,2,4,8,12,16",
        help="Comma-separated concurrency client levels (default: 1,2,4,8,12,16)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=REPO_ROOT / "tests" / "load",
        help="Directory to save benchmark JSON artifacts",
    )

    args = parser.parse_args()
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass

    # Discover test media
    direct_mp4, size_str, hls_media_path, hls_key = _find_test_media()
    if not direct_mp4:
        print("[ERROR] No direct MP4 media files found in library for testing.", file=sys.stderr)
        return 1
    file_size = int(size_str)

    # Locate server PID for telemetry (port 8001 for Rust, port 8000 for Waitress)
    target_port = 8001 if args.target == "rust" else 8000
    server_pid = None
    for proc in psutil.process_iter(["pid", "name"]):
        try:
            conns = proc.net_connections(kind="inet")
            for c in conns:
                if c.laddr.port == target_port and c.status == "LISTEN":
                    server_pid = proc.info["pid"]
                    break
            if server_pid:
                break
        except Exception:
            continue

    sampler = HardwareSampler(target_pid=server_pid)
    levels = [int(x.strip()) for x in args.levels.split(",") if x.strip().isdigit()]

    targets = []
    if args.target in ("local", "both", "all"):
        targets.append((LOCAL_ORIGIN, "Local Origin Waitress (127.0.0.1:8000)"))
    if args.target in ("rust", "all"):
        targets.append(("http://127.0.0.1:8001", "Native Rust Axum (127.0.0.1:8001)"))
    if args.target in ("remote", "both", "all"):
        targets.append((REMOTE_TUNNEL, "Cloudflare Tunnel (media.anisparvez.in)"))

    workloads = []
    if args.workload == "all":
        workloads = ["direct"]
        if hls_media_path:
            workloads.append("hls")
        workloads.append("mixed")
    else:
        workloads = [args.workload]

    print("==========================================================================", flush=True)
    print("  MEDIA SERVER CONCURRENCY & REMOTE STREAMING BENCHMARK (2026.10)", flush=True)
    print("==========================================================================", flush=True)
    print(f"  Direct MP4 Target   : {direct_mp4} ({file_size / (1024*1024):.1f} MB)", flush=True)
    print(f"  HLS Target Media    : {hls_media_path if hls_media_path else 'None available (skipping HLS)'}", flush=True)
    print(f"  HLS Cache Key Target: {hls_key if hls_key else 'None'}", flush=True)
    print(f"  Server Process      : PID {server_pid if server_pid else 'unknown'}", flush=True)
    print(f"  Concurrency Levels  : {levels}", flush=True)
    print(f"  Workloads           : {workloads}", flush=True)
    print(f"  Targets             : {[t[1] for t in targets]}", flush=True)
    print("==========================================================================", flush=True)

    all_reports: list[ConcurrencyLevelReport] = []

    for base_url, label in targets:
        print(f"\n==================================================", flush=True)
        print(f"  BENCHMARKING TARGET: {label}", flush=True)
        print(f"==================================================", flush=True)
        for wl in workloads:
            for c in levels:
                report = run_benchmark_level(
                    concurrency=c,
                    base_url=base_url,
                    workload=wl,
                    media_path=direct_mp4,
                    file_size=file_size,
                    hls_media_path=hls_media_path,
                    sampler=sampler,
                )
                all_reports.append(report)
                # Short ramp cooldown
                time.sleep(1.0)

    # Save JSON artifact
    args.output_dir.mkdir(parents=True, exist_ok=True)
    ts_str = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    json_path = args.output_dir / f"benchmark_results_{ts_str}.json"

    export_data = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "server_pid": server_pid,
        "direct_media": direct_mp4,
        "hls_key": hls_key,
        "reports": [asdict(r) for r in all_reports],
    }

    json_path.write_text(json.dumps(export_data, indent=2), encoding="utf-8")
    print("\n==========================================================================")
    print(f"  BENCHMARK COMPLETE. Results saved to: {json_path}")
    print("==========================================================================")

    return 0


if __name__ == "__main__":
    sys.exit(main())
