# Transcode Correctness, Throughput and Telemetry

Date: 2026-10-11
Scope: `app/services/chunk_transcode_service.py`, `app/services/transcode_service.py`,
`app/services/gpu_service.py`, `app/routes/api.py`

This records three changes made on 2026-10-11 while chasing "the transcoder is slow
and the GPU sits idle". They are separate concerns and are recorded separately.

---

## 1. Frame accounting must never report "unknown" as "empty"

### The defect

`measure_segment_frame_count()` documented:

> Returns **-1** for "unknown" (unreadable file, no ffprobe, segment still being
> written) and **0** only for a file that was successfully read and genuinely holds
> no video packets.

It did not do that. It returned `0` in two of those three cases:

```python
key = _segment_cache_key(path)
if key is None:
    return 0          # should be -1
...
if not ffprobe:
    return 0          # should be -1
```

`_segment_cache_key()` returns `None` for three distinct reasons, and the third is
the damaging one:

```python
if (time.time() - st.st_mtime) < _SEGMENT_PROBE_FRESH_SECONDS:
    return None  # still being written by ffmpeg: a probe would be meaningless
```

That freshness guard exists so the 1 Hz progress updater never probes a
half-written segment. Its refusal was being converted into a **genuine zero frame
count**.

### The consequence

A chunk re-rendered by the serial repair measures its own brand-new segments as
empty. It is reported as missing ~15 s of video, `ENDLIST` is refused, and the
cache sits "incomplete" while measuring complete minutes later. Because the
measurement was wrong rather than the content, the repair re-rendered a chunk that
was already fine — and the repair's own output was then re-measured as short.

Measured wall clock on a fixed 96 s clip, identical source and identical settings:

| | before | after |
|---|---|---|
| 8-bit legacy pipeline | 26.2 s | **13.7 s** |
| 10-bit legacy pipeline | 34.6 s | **20.9 s** |

Roughly half the elapsed time was spent re-rendering chunks that were never short.

### Why it looked like a pipeline problem

It reproduced identically on the 10-bit (`vpp_amf`) and 8-bit (direct) paths, which
is what made it look like a filter-chain regression. It was neither: it was the
measuring instrument.

### Live confirmation

The audit of a 107-chunk in-progress cache now reports
`1 of 107 chunk(s) could not be measured` — the chunk being actively written is
skipped rather than reported as a large deficit.

### Rule

> **Unknown is never empty.** `-1` means unmeasurable and the chunk is skipped.
> Only a successfully-read 0 counts as zero.

This is the invariant `AGENTS.md` already carried; the code did not implement it at
the one place that decides.

---

## 2. Per-source pipeline and chunk worker sizing

### The starting position

Concurrency was structurally capped at two: `chunk_transcode_service.py` started
exactly one thread per detected GPU.

### Measurement caveat (important)

Early ad-hoc benchmarks were taken **while a live transcode was saturating the CPU**
that libx264 needs. That inverted the result and produced the conclusion "CPU beats
the GPU". It was an artifact. All figures below were taken on an idle machine with
**verified frame counts** (`-progress` must emit `progress=end` *and* a final
`frame=`), never wall-clock alone — a failed run exits in under a second and looks
fast. One earlier "2.67x" figure was exactly that: a run that had exited
immediately with `10-bit encoder is not supported by AMD GPU drivers versions lower
than 23.30`.

### Verified aggregate throughput (idle machine, 15 s slices, 4 classes)

| source class | 2 workers (legacy) | best | config |
|---|---|---|---|
| 4K HEVC Main10 | 1.62x | **1.86x** | 4 workers |
| 1080p HEVC Main10 | 4.01x | **4.51x** | 3 workers |
| 1080p HEVC Main 8-bit | 6.06x | **7.19x** | 2 workers, no `vpp_amf` |
| 1080p H.264 Main 8-bit | 6.03x | **7.06x** | 2 workers, no `vpp_amf` |

### Why the filter chain must vary by source

`vpp_amf` is not only a scaler. For a **10-bit** source it is the only thing that
converts depth to 8-bit, because `h264_amf` **rejects 10-bit input on this host**.

That rejection is worth stating precisely, because ffmpeg's own message misleads:
`10-bit encoder is not supported by AMD GPU drivers versions lower than 23.30` reads
like a stale-driver problem. It is not. Re-measured directly on both adapters with the
driver currently installed:

```
RX 560X  31.0.21923.1000 (2025-06-03)   exit=-1313558101  10-bit encoder is not supported
Vega 8   31.0.21923.1000 (2025-06-03)   exit=-1313558101  10-bit encoder is not supported
```

The driver is current, and the check is against the **AMF runtime**, not the Windows driver
version. H.264's High10 profile is not available on this VCN hardware regardless of driver
age. Do not spend time chasing a driver update over this; the encode fails outright rather
than degrading, which is the safe failure mode.

For an **8-bit** source no taller than the 1080p profile, `vpp_amf` performs no
resize and no conversion. It is a full GPU round-trip for nothing, and dropping it
is worth roughly 19%.

Alternatives were tested and rejected on this hardware:

- `scale_d3d11` / `scale_d3d12` — `Could not create the texture (80070057)`; the
  driver will not create a texture from `p010le` on these cards.
- CPU scale + GPU encode — format negotiation fails
  (`Impossible to convert between the formats supported by ...`).

### Worker sweep — completeness is the acceptance criterion

A finished transcode must lose zero seconds. Throughput is reported alongside, but
a faster render that drops content is worthless.

| workers | speed | frames missing | ENDLIST | `hls.loss.json` | verdict |
|---|---|---|---|---|---|
| 2 | 4.55x | −4 (surplus) | yes | no | PASS |
| 3 | 5.16x | −4 | yes | no | PASS |
| **4** | **5.26x** | −4 | yes | no | PASS |
| 6 | 5.05x | −4 | yes | no | PASS |

**Worker count does not affect the output.** Every run produced byte-identical
layout: 151 segments, index range 0..320, 170 inter-chunk gaps. That is the
property that makes more workers safe.

A negative missing count is a rounding surplus at a chunk boundary, not a failure.
The criterion is `missing_frames <= 0`, never `== 0`.

### Activation

Gated behind `MEDIA_SERVER_TRANSCODE_STRATEGY`, **default `legacy`** — the deployed
pipeline is unchanged until the flag is set.

```
MEDIA_SERVER_TRANSCODE_STRATEGY=adaptive
MEDIA_SERVER_TRANSCODE_WORKERS_MAIN10=4      # measured optimum (default 3)
MEDIA_SERVER_TRANSCODE_WORKERS_8BIT=2       # also enables the no-vpp_amf path
```

### Fail-safe

`select_amf_strategy()` returns `use_vpp_amf=True` for an **unprobed** source.
Guessing "no resize needed" from missing data is the one mistake that would
silently emit a 10-bit or oversized stream, so unknown always means the historical
pipeline.

`expand_workers()` gives duplicates distinct names. The scheduler retires a GPU for
a whole job **by name**, so shared names would take down every duplicate of that
adapter at once and defeat the fallback path.

### Known cosmetic issue

A zero-duration tail chunk (when the source duration divides exactly) trips
`MIN_CHUNK_YIELD_RATIO` and spuriously retires workers for that job. No content
impact.

---

## 3. Speed and ETA telemetry

### The defects

`hls.progress` is written by the job, not by ffmpeg. Three problems:

1. **`_initial_cached_sec` walked segment indices densely from 0.** On the strided
   layout that loop stops at the *first inter-chunk gap*, so a resumed cache holding
   2447 s reported 15 segments → 60 s. "Newly encoded" then became the entire
   cache, and dividing by real elapsed time produced **16.84x on a job actually
   running near 2x**. This is the same dense-walk trap `AGENTS.md` records for
   segment accounting, in a second place.

2. **Speed was a lifetime average** (`newly_encoded / elapsed-since-start`). It
   cannot represent a resume or a stall, and it is computed from a quantity that
   advances in per-chunk bursts.

3. **No ETA was emitted**, so the API divided the remaining duration by an
   instantaneous number. Observed: the UI claimed **5.3x with a 7m53s ETA** on a
   job whose real rate was ~2.2x with ~16 minutes left.

### The fix

- `_initial_cached_sec` globs and counts.
- Speed is a **trailing-window** rate (`RATE_WINDOW_S = 90`), from a bounded ring
  buffer of `(wall_time, rendered_seconds)` samples taken by the 1 Hz updater.
- The job emits its own **`eta_s`** and **`rate_window_s`**. The API prefers that
  ETA over dividing by `speed`.
- Speed is **withheld entirely** until the window spans at least
  `MIN_RATE_WINDOW_S = 20 s`, or when there is no measurable progress across the
  window. The UI then shows "Calculating..." instead of a confident wrong number.
- A fallback that divided by the age of the *first segment* is gated to jobs under
  one hour old, because on a resumed cache that segment can be days old and the
  result collapses toward zero.

### Result (live)

```
19:39:19  67.4%  encoded=79:39/118:08  speed=7.3x  eta=5m 15s
19:39:39  69.9%  encoded=82:34/118:08  speed=7.5x  eta=4m 43s
19:40:00  71.8%  encoded=84:50/118:08  speed=7.4x  eta=4m 30s
19:40:21  73.9%  encoded=87:17/118:08  speed=7.2x  eta=4m 17s
```

Speed holds a stable band instead of oscillating; the ETA falls monotonically.
Cross-check at 67.4 %: 38m29s remaining at 7.3x is 316 s, and 5m15s was reported.

---

### Enabling it, and a registry trap worth knowing

Activation is three variables in the service environment (NSSM `AppEnvironmentExtra`):

```
MEDIA_SERVER_TRANSCODE_STRATEGY=adaptive
MEDIA_SERVER_TRANSCODE_WORKERS_MAIN10=4      # measured optimum (default 3)
MEDIA_SERVER_TRANSCODE_WORKERS_8BIT=2       # also enables the no-vpp_amf path
```

Confirmed live in the service log:
`Transcode strategy: mode=adaptive workers(10-bit/oversized)=4 workers(8-bit)=2`

**Two traps, both hit here:**

1. **An empty entry in `AppEnvironmentExtra` silently truncates everything after it.** The stored
   `REG_MULTI_SZ` carried an empty string at index 5 — it predated this session. The three new
   variables were correctly in the registry, and the service still reported `mode=legacy`. NSSM stops
   applying entries at the empty string. The value was rebuilt without it. Verify with a startup log
   line rather than by reading the registry.

2. **`Restart-Service` is not enough; the NSSM wrapper must be torn down.** A restart keeps
   `nssm.exe` alive and it keeps serving the environment block it built at its own launch, so the new
   variables were still not visible. `Stop-Service` (which exits the wrapper) followed by
   `Start-Service` is what made them appear. A machine reboot is never required for this — only a
   newly launched service process.

That is why `log_transcode_configuration()` now logs the resolved mode, the worker counts, and a
variable NSSM has always set, so "my override did not arrive" is distinguishable from "the service
inherited no environment at all".

## Rule for measuring this pipeline
Do not benchmark a transcode pipeline while another transcode is running, and never
accept a wall-clock number without confirming the run completed. A failed ffmpeg
invocation exits in under a second and reads as a very fast encode. Verify with
`-progress` (`progress=end` plus a final `frame=`) or a frame count.

## Rules for progress telemetry

- A progress number must be a **rate over a stated window**, not a lifetime average.
- If the window is too short to be meaningful, publish **no number**. Silence is
  correct; a confident wrong number is not.
- The component that knows both the rate and how much work was already cached owns
  the ETA. Consumers must not re-derive it from a rate alone.

## Tests

- `tests/test_frame_accounting_unknown.py` — 7 tests, pins the unknown/empty boundary.
- `tests/test_transcode_strategy.py` — 22 tests + 38 subtests, strategy selection,
  worker expansion, unique names, fail-safe on unprobed sources.
- `tests/test_transcode_rate_telemetry.py` — 9 tests, windowed rate, withheld speed,
  lifetime-average regression, the dense-walk bug, ETA arithmetic.
- `tests/test_media_root_health.py` — 8 tests, startup media-root diagnostics.

Suite on `main` after these changes: **410 passed, 0 failed**.

---

## 4. Startup diagnostics

Two configuration problems were invisible from the UI for an extended period. Both are
now reported at startup.

### A wrong media root that still appeared to work

`MEDIA_SERVER_MEDIA_ROOT` pointed at `C:\Flicks` — an **empty** directory — while `.env`
and the project documentation both said `D:\Flicks`. Nothing looked broken, because
`get_media_roots()` falls back to `UPLOAD_TARGET_DIR`, which hardcodes `D:` when the drive
exists. The library resolved, the UI worked, and the misconfiguration was undetectable.

`media_root_health()` now checks every configured root at startup and reports missing,
non-directory, unreadable, and **empty** roots — the empty case explicitly noting that
the library will resolve only via a fallback, which is what hides it. It is diagnostic
only: never raises, never mutates, returns problem strings rather than booleans so the log
can say what is actually wrong.

### The transcode strategy is environment-driven and therefore invisible

`log_transcode_configuration()` reports the resolved mode, worker counts, and a variable
NSSM has always set, so a missing override is distinguishable from an inherited-empty
environment. This is what caught the `AppEnvironmentExtra` truncation described above —
reading the registry would have said everything was configured correctly.

### Windows service configuration

- `AppEnvironmentExtra` must not contain an empty entry; everything after it is ignored.
- `Restart-Service` does not pick up registry changes — the NSSM wrapper survives and keeps
  its original environment block. Use `Stop-Service` then `Start-Service`. No machine reboot
  is ever required.

---

## 5. The AMF pipeline is a GPU TDR trigger

**This is measurement, and it changes how a "successful" transcode run should be read.**

On 2026-10-20 the machine took a hard reset. The post-mortem is in
[`Handoffs/2026-10-20_15-45_opencode_system-restart-forensics.md`](../Handoffs/2026-10-20_15-45_opencode_system-restart-forensics.md)
and the finding is Issue 13 in [`docs/Current issues.md`](Current%20issues.md). Two things matter
here.

**The hardware fault is chronic.** The WER queue holds **42 kernel "Hardware error" reports**
spanning September 2025 → 18 October 2026: 22× GPU TDR (`141`), 4× AMD driver hang, and 2 real
bugchecks (`0xD1`, `0xA`). A transcode that completes without a visible error can still have
provoked a hang that the driver recovered from.

**The correlation with AMF is to the second.** `rust_api.log` shows `Worker … failed job #1077`
within **11–27 s** of each of the four 18 October GPU hang dumps. The AMF pipeline is not a
bystander to the GPU instability — it is one of the things that provokes it. That is the
project-level risk: the hardware-accelerated HLS the product depends on is the same workload that
hangs the GPU.

### What that means for a transcode run

- **A completed transcode is not, on its own, proof that the GPU was healthy.** The acceptance
  test for the GPU fix is a **2160p AMF job** (3 workers across both GPUs) that produces **no new**
  `C:\Windows\LiveKernelReports` dumps **and** no `Worker … failed job`. A 2160p AMF job is the
  most reliable TDR stress available on this box, so it is the right probe.
- **The `failed job` lines in `rust_api.log` are not just noise to be retried.** In this context
  they are the *evidence* — the thing that correlates a worker failure with a GPU hang. Read them
  when diagnosing a hang; do not dismiss them as a transient.
- **Never run a transcode and the Playwright harness concurrently.** Both are GPU-heavy, and that
  pairing is how a TDR becomes a hard reset. The Playwright harness now launches with
  `--disable-gpu` (`web/playwright.config.ts`); the transcode side cannot be disabled, because
  AMF *is* the accelerator.

### What not to do

- Do not install a generic AMD driver with DDU on this box without a recovery path.
- Do not prune the HLS cache before the GPU fix: pruning means re-transcoding, which means more
  AMF.
- Do not re-enable a system-managed or large pagefile. The 2 GB fixed, reserved pagefile on `C:` is
  deliberate.
- Do not conclude that a media server caused a reset without checking whether it was idle. On
  20 October it was (`scanned=33, queued=0, errors=0`; no `ffmpeg`; no cache writes 13:00–15:05),
  and the trigger was headless-Chromium GPU compositing.
