#!/usr/bin/env python3
"""
Controlled load test for the media server.

Simulates concurrent video streaming clients using HTTP Range requests.
Measures TTFB, throughput, success rate, CPU, RAM, and disk I/O.

Usage:
    python3 tests/load/load_test.py --target local   [--levels 1,2,5,10,20,30,50]
    python3 tests/load/load_test.py --target prod    [--levels 1,2,5,10,20,30,50]
    python3 tests/load/load_test.py --target both    [--levels 1,2,5,10]
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

LOCAL_BASE = "http://127.0.0.1:8000"
PROD_BASE = "https://media.anisparvez.in"

# The test file: Oculus (smallest available, 1.68 GB, H.264 MP4, direct stream)
MEDIA_PATH = "Oculus (2013) [1080p]/Oculus.2013.1080p.BluRay.x264.YIFY.mp4"
ENCODED_PATH = quote(MEDIA_PATH)

# Each simulated stream fetches CHUNK_SIZE bytes per Range request,
# then pauses briefly to simulate real player buffering.
CHUNK_SIZE = 2 * 1024 * 1024  # 2 MB per chunk (realistic browser fetch)
CHUNKS_PER_STREAM = 5           # Each stream fetches 5 chunks = 10 MB total
INTER_CHUNK_DELAY = 0.3         # 300ms between chunks (simulates playback buffer)

# Test timing
WARMUP_STREAMS = 1              # Streams launched during warmup
STEADY_STATE_DURATION = 15      # Seconds to hold each concurrency level
RAMP_PAUSE = 3                  # Seconds between concurrency levels

# Failure thresholds — stop escalating if any of these are breached
MAX_FAILURE_RATE = 0.20         # 20% of streams failing
MAX_TTFB_SECONDS = 10.0         # 10 seconds time-to-first-byte
MIN_THROUGHPUT_MBPS = 0.5       # 0.5 Mbps per stream minimum

# Default concurrency levels
DEFAULT_LEVELS = [1, 2, 5, 10, 20, 30, 50, 75, 100]

# ---------------------------------------------------------------------------
# System metrics collection
# ---------------------------------------------------------------------------


@dataclass
class SystemSnapshot:
    timestamp: float = 0.0
    cpu_percent: float = 0.0
    mem_used_mb: float = 0.0
    mem_total_mb: float = 0.0
    mem_percent: float = 0.0
    load_1m: float = 0.0
    load_5m: float = 0.0
    disk_read_kbps: float = 0.0
    disk_write_kbps: float = 0.0


def _read_proc_stat():
    """Read /proc/stat for CPU calculation."""
    with open("/proc/stat") as f:
        line = f.readline()
    parts = line.split()
    # user nice system idle iowait irq softirq steal
    vals = [int(x) for x in parts[1:9]]
    idle = vals[3] + vals[4]  # idle + iowait
    total = sum(vals)
    return idle, total


def _read_diskstats():
    """Read /proc/diskstats for I/O calculation."""
    total_read = 0
    total_write = 0
    with open("/proc/diskstats") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 14:
                name = parts[2]
                # Only count whole-disk devices, not partitions
                if name.startswith("sd") and len(name) == 3:
                    total_read += int(parts[5])   # sectors read
                    total_write += int(parts[9])  # sectors written
    return total_read, total_write


class SystemMonitor:
    """Background thread that samples system metrics at 1 Hz."""

    def __init__(self):
        self.snapshots: list[SystemSnapshot] = []
        self._stop = threading.Event()
        self._thread = None

    def start(self):
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)

    def _run(self):
        prev_idle, prev_total = _read_proc_stat()
        prev_rd, prev_wr = _read_diskstats()
        prev_time = time.monotonic()

        while not self._stop.wait(1.0):
            now = time.monotonic()
            dt = now - prev_time
            if dt < 0.1:
                continue

            # CPU
            idle, total = _read_proc_stat()
            d_idle = idle - prev_idle
            d_total = total - prev_total
            cpu_pct = (1.0 - d_idle / max(d_total, 1)) * 100.0
            prev_idle, prev_total = idle, total

            # Memory
            mem = {}
            with open("/proc/meminfo") as f:
                for line in f:
                    k, v = line.split(":")
                    mem[k.strip()] = int(v.split()[0])
            total_mb = mem.get("MemTotal", 0) / 1024
            avail_mb = mem.get("MemAvailable", 0) / 1024
            used_mb = total_mb - avail_mb

            # Load
            load1, load5, _ = os.getloadavg()

            # Disk I/O (sectors are 512 bytes)
            rd, wr = _read_diskstats()
            disk_rd_kbps = ((rd - prev_rd) * 512 / 1024) / dt
            disk_wr_kbps = ((wr - prev_wr) * 512 / 1024) / dt
            prev_rd, prev_wr = rd, wr
            prev_time = now

            snap = SystemSnapshot(
                timestamp=time.time(),
                cpu_percent=round(cpu_pct, 1),
                mem_used_mb=round(used_mb, 1),
                mem_total_mb=round(total_mb, 1),
                mem_percent=round(used_mb / max(total_mb, 1) * 100, 1),
                load_1m=round(load1, 2),
                load_5m=round(load5, 2),
                disk_read_kbps=round(disk_rd_kbps, 1),
                disk_write_kbps=round(disk_wr_kbps, 1),
            )
            self.snapshots.append(snap)

    def summary(self) -> dict:
        """Return aggregated metrics over the monitoring window."""
        if not self.snapshots:
            return {}
        return {
            "samples": len(self.snapshots),
            "cpu_avg": round(statistics.mean(s.cpu_percent for s in self.snapshots), 1),
            "cpu_max": round(max(s.cpu_percent for s in self.snapshots), 1),
            "mem_used_avg_mb": round(statistics.mean(s.mem_used_mb for s in self.snapshots), 0),
            "mem_max_mb": round(max(s.mem_used_mb for s in self.snapshots), 0),
            "mem_percent_avg": round(statistics.mean(s.mem_percent for s in self.snapshots), 1),
            "load_1m_avg": round(statistics.mean(s.load_1m for s in self.snapshots), 2),
            "load_1m_max": round(max(s.load_1m for s in self.snapshots), 2),
            "disk_read_avg_kbps": round(statistics.mean(s.disk_read_kbps for s in self.snapshots), 0),
            "disk_read_max_kbps": round(max(s.disk_read_kbps for s in self.snapshots), 0),
            "disk_write_avg_kbps": round(statistics.mean(s.disk_write_kbps for s in self.snapshots), 0),
        }


# ---------------------------------------------------------------------------
# Stream simulation
# ---------------------------------------------------------------------------

@dataclass
class StreamResult:
    stream_id: int = 0
    success: bool = False
    ttfb_s: float = 0.0
    total_bytes: int = 0
    total_time_s: float = 0.0
    throughput_mbps: float = 0.0
    chunks_ok: int = 0
    chunks_failed: int = 0
    http_codes: list = field(default_factory=list)
    error: str = ""


def simulate_stream(stream_id: int, base_url: str) -> StreamResult:
    """
    Simulate a single video player by issuing sequential Range requests.

    Each stream fetches CHUNKS_PER_STREAM chunks of CHUNK_SIZE bytes from
    random-ish offsets within the file. This models how a real player
    buffers ahead in segments.
    """
    import urllib.request
    import urllib.error
    import ssl

    result = StreamResult(stream_id=stream_id)
    url = f"{base_url}/media/{ENCODED_PATH}"

    # Create SSL context that works with Cloudflare
    ctx = ssl.create_default_context()

    total_bytes = 0
    ttfb_recorded = False
    t0 = time.monotonic()

    # Stagger starting offsets to avoid all streams reading the exact same bytes
    # This is more realistic and tests disk I/O better
    file_size = 1_755_444_678  # Oculus file size
    offset_step = file_size // (CHUNKS_PER_STREAM + 2)
    base_offset = (stream_id * 37 * 1024 * 1024) % (file_size // 2)  # Spread start positions

    for i in range(CHUNKS_PER_STREAM):
        start = base_offset + (i * offset_step)
        end = start + CHUNK_SIZE - 1
        if end >= file_size:
            start = 0
            end = CHUNK_SIZE - 1

        req = urllib.request.Request(url, headers={
            "Range": f"bytes={start}-{end}",
            "User-Agent": f"LoadTest-Stream-{stream_id}",
        })

        try:
            t_req = time.monotonic()
            resp = urllib.request.urlopen(req, timeout=30, context=ctx)
            data = resp.read()
            t_done = time.monotonic()

            if not ttfb_recorded:
                result.ttfb_s = round(t_done - t_req, 4)  # Approximation
                ttfb_recorded = True

            result.http_codes.append(resp.status)
            total_bytes += len(data)
            result.chunks_ok += 1

        except urllib.error.HTTPError as e:
            result.http_codes.append(e.code)
            result.chunks_failed += 1
            result.error = f"HTTP {e.code}: {e.reason}"
        except Exception as e:
            result.chunks_failed += 1
            result.error = str(e)[:200]

        # Simulate player buffering pause between chunks
        if i < CHUNKS_PER_STREAM - 1:
            time.sleep(INTER_CHUNK_DELAY)

    elapsed = time.monotonic() - t0
    result.total_bytes = total_bytes
    result.total_time_s = round(elapsed, 3)
    result.throughput_mbps = round((total_bytes * 8) / max(elapsed, 0.001) / 1_000_000, 2)
    result.success = result.chunks_failed == 0 and result.chunks_ok > 0

    return result


# ---------------------------------------------------------------------------
# TTFB-only probe (more accurate timing via curl)
# ---------------------------------------------------------------------------

def curl_ttfb(base_url: str) -> float:
    """Get accurate TTFB for a single 1MB Range request using curl."""
    url = f"{base_url}/media/{ENCODED_PATH}"
    try:
        r = subprocess.run(
            ["curl", "-s", "-o", "/dev/null",
             "-w", "%{time_starttransfer}",
             "-H", "Range: bytes=0-1048575",
             url],
            capture_output=True, text=True, timeout=30
        )
        return float(r.stdout.strip())
    except Exception:
        return -1.0


# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------

@dataclass
class LevelResult:
    concurrency: int = 0
    streams_total: int = 0
    streams_success: int = 0
    streams_failed: int = 0
    success_rate: float = 0.0
    ttfb_avg_s: float = 0.0
    ttfb_p50_s: float = 0.0
    ttfb_p95_s: float = 0.0
    ttfb_max_s: float = 0.0
    throughput_avg_mbps: float = 0.0
    throughput_min_mbps: float = 0.0
    aggregate_throughput_mbps: float = 0.0
    total_bytes: int = 0
    duration_s: float = 0.0
    system: dict = field(default_factory=dict)
    http_codes: dict = field(default_factory=dict)
    errors: list = field(default_factory=list)
    verdict: str = ""


def run_level(concurrency: int, base_url: str, label: str) -> LevelResult:
    """Run a load test at a specific concurrency level."""
    print(f"\n{'='*60}")
    print(f"[{label}] Testing {concurrency} concurrent streams against {base_url}")
    print(f"{'='*60}")

    monitor = SystemMonitor()
    monitor.start()

    results: list[StreamResult] = []
    t0 = time.monotonic()

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = {
            pool.submit(simulate_stream, i, base_url): i
            for i in range(concurrency)
        }
        for future in as_completed(futures):
            try:
                r = future.result()
                results.append(r)
                status = "✓" if r.success else "✗"
                print(f"  Stream {r.stream_id:3d}: {status}  "
                      f"TTFB={r.ttfb_s:.3f}s  "
                      f"Throughput={r.throughput_mbps:.1f} Mbps  "
                      f"Chunks={r.chunks_ok}/{r.chunks_ok + r.chunks_failed}  "
                      f"{'ERROR: ' + r.error if r.error else ''}")
            except Exception as e:
                print(f"  Stream {futures[future]}: EXCEPTION: {e}")

    elapsed = time.monotonic() - t0
    monitor.stop()

    # Aggregate
    level = LevelResult(concurrency=concurrency)
    level.streams_total = len(results)
    level.streams_success = sum(1 for r in results if r.success)
    level.streams_failed = level.streams_total - level.streams_success
    level.success_rate = round(level.streams_success / max(level.streams_total, 1) * 100, 1)
    level.duration_s = round(elapsed, 2)
    level.total_bytes = sum(r.total_bytes for r in results)

    # TTFB stats
    ttfbs = [r.ttfb_s for r in results if r.ttfb_s > 0]
    if ttfbs:
        ttfbs_sorted = sorted(ttfbs)
        level.ttfb_avg_s = round(statistics.mean(ttfbs), 4)
        level.ttfb_p50_s = round(ttfbs_sorted[len(ttfbs_sorted) // 2], 4)
        level.ttfb_p95_s = round(ttfbs_sorted[int(len(ttfbs_sorted) * 0.95)], 4)
        level.ttfb_max_s = round(max(ttfbs), 4)

    # Throughput stats
    tputs = [r.throughput_mbps for r in results if r.throughput_mbps > 0]
    if tputs:
        level.throughput_avg_mbps = round(statistics.mean(tputs), 2)
        level.throughput_min_mbps = round(min(tputs), 2)
        level.aggregate_throughput_mbps = round(sum(tputs), 2)

    # HTTP code distribution
    code_dist: dict[int, int] = {}
    for r in results:
        for code in r.http_codes:
            code_dist[code] = code_dist.get(code, 0) + 1
    level.http_codes = {str(k): v for k, v in sorted(code_dist.items())}

    # Errors
    level.errors = [r.error for r in results if r.error][:10]

    # System metrics
    level.system = monitor.summary()

    # Verdict
    if level.success_rate < (1 - MAX_FAILURE_RATE) * 100:
        level.verdict = "FAIL — excessive failures"
    elif level.ttfb_avg_s > MAX_TTFB_SECONDS:
        level.verdict = "FAIL — TTFB too high"
    elif level.throughput_avg_mbps < MIN_THROUGHPUT_MBPS and tputs:
        level.verdict = "DEGRADED — throughput too low"
    else:
        level.verdict = "PASS"

    # Print summary
    print(f"\n  Result: {level.verdict}")
    print(f"  Success: {level.streams_success}/{level.streams_total} ({level.success_rate}%)")
    print(f"  TTFB avg/p50/p95/max: {level.ttfb_avg_s:.3f} / {level.ttfb_p50_s:.3f} / "
          f"{level.ttfb_p95_s:.3f} / {level.ttfb_max_s:.3f} s")
    print(f"  Throughput avg/min: {level.throughput_avg_mbps:.1f} / {level.throughput_min_mbps:.1f} Mbps")
    print(f"  Aggregate throughput: {level.aggregate_throughput_mbps:.1f} Mbps")
    if level.system:
        sys_m = level.system
        print(f"  CPU avg/max: {sys_m.get('cpu_avg',0)}% / {sys_m.get('cpu_max',0)}%")
        print(f"  Memory: {sys_m.get('mem_used_avg_mb',0):.0f} MB avg ({sys_m.get('mem_percent_avg',0)}%)")
        print(f"  Load 1m avg/max: {sys_m.get('load_1m_avg',0)} / {sys_m.get('load_1m_max',0)}")
        print(f"  Disk read avg/max: {sys_m.get('disk_read_avg_kbps',0):.0f} / "
              f"{sys_m.get('disk_read_max_kbps',0):.0f} KB/s")
    print(f"  HTTP codes: {level.http_codes}")

    return level


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Media Server Load Test")
    parser.add_argument("--target", choices=["local", "prod", "both"], default="local",
                        help="Test target: local (127.0.0.1:8000), prod (media.anisparvez.in), or both")
    parser.add_argument("--levels", type=str, default=None,
                        help="Comma-separated concurrency levels, e.g., '1,2,5,10,20'")
    parser.add_argument("--output", type=str, default=None,
                        help="Output JSON file path (default: auto-generated in tests/load/)")
    args = parser.parse_args()

    levels = [int(x) for x in args.levels.split(",")] if args.levels else DEFAULT_LEVELS

    targets = []
    if args.target in ("local", "both"):
        targets.append(("local", LOCAL_BASE))
    if args.target in ("prod", "both"):
        targets.append(("prod", PROD_BASE))

    all_results = {
        "test_metadata": {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "media_file": MEDIA_PATH,
            "chunk_size_bytes": CHUNK_SIZE,
            "chunks_per_stream": CHUNKS_PER_STREAM,
            "inter_chunk_delay_s": INTER_CHUNK_DELAY,
            "data_per_stream_mb": round(CHUNK_SIZE * CHUNKS_PER_STREAM / 1024 / 1024, 1),
            "failure_thresholds": {
                "max_failure_rate": MAX_FAILURE_RATE,
                "max_ttfb_s": MAX_TTFB_SECONDS,
                "min_throughput_mbps": MIN_THROUGHPUT_MBPS,
            },
        },
        "results": {},
    }

    for label, base_url in targets:
        print(f"\n{'#'*70}")
        print(f"# LOAD TEST: {label.upper()} ({base_url})")
        print(f"{'#'*70}")

        # Baseline TTFB via curl
        print(f"\nBaseline TTFB (curl, single request):")
        baseline_ttfb = curl_ttfb(base_url)
        print(f"  {baseline_ttfb:.4f}s")

        target_results = {
            "base_url": base_url,
            "baseline_ttfb_s": baseline_ttfb,
            "levels": [],
        }

        max_sustainable = 0
        first_degradation = None

        for conc in levels:
            result = run_level(conc, base_url, label)
            target_results["levels"].append(asdict(result))

            if result.verdict == "PASS":
                max_sustainable = conc
            elif first_degradation is None:
                first_degradation = conc

            # Stop escalating if hard failure
            if "FAIL" in result.verdict:
                print(f"\n⛔ Stopping escalation: {result.verdict} at {conc} concurrent streams")
                break

            # Pause between levels
            if conc != levels[-1]:
                print(f"\n  ⏳ Cooling down for {RAMP_PAUSE}s before next level...")
                time.sleep(RAMP_PAUSE)

        target_results["max_sustainable_streams"] = max_sustainable
        target_results["first_degradation_at"] = first_degradation
        all_results["results"][label] = target_results

        print(f"\n{'='*60}")
        print(f"[{label.upper()}] SUMMARY")
        print(f"  Max sustainable concurrent streams: {max_sustainable}")
        print(f"  First degradation at: {first_degradation or 'N/A'}")
        print(f"{'='*60}")

    # Save results
    output_dir = Path(__file__).parent
    if args.output:
        output_path = Path(args.output)
    else:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        output_path = output_dir / f"results_{ts}.json"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(all_results, f, indent=2)
    print(f"\n📊 Results saved to: {output_path}")


if __name__ == "__main__":
    main()

