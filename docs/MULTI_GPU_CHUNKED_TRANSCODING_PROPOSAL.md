# Dynamic Multi-GPU Chunked Transcoding Architecture

Status: **Implemented & Operational** (via `app/services/chunk_transcode_service.py` and `app/services/gpu_service.py`)

Related: GitHub Issue #8 — **Simultaneous use of AMD Radeon RX 560X and AMD Radeon Vega 8 for transcoding**

## 1. Purpose

The current Windows test host has two graphics adapters:

- **AMD Radeon RX 560X** discrete GPU (Task Manager GPU 0 / FFmpeg `dx11:1`).
- **AMD Radeon Vega 8** integrated GPU (Task Manager GPU 1 / FFmpeg `dx11:0`).

During heavy transcoding, distributing the workload across both GPUs provides higher aggregate transcoding throughput and reduces CPU utilization.

The server does **not** try to make two GPUs encode the same frame. Instead, the server treats each capable GPU as an independent transcoding worker and dynamically distributes **larger sequential chunks of the same movie** between them.

The dynamic chunk scheduler preserves correct HLS playback, timestamps, audio synchronization, resume behavior, and platform compatibility.


---

## 2. Core idea

A single FFmpeg job normally uses one hardware-encoding pipeline. Trying to make one encode simultaneously use the discrete GPU and Vega 8 is not the target design.

Instead:

```text
                         Source Movie
                              |
                       Chunk Scheduler
                         /          \
                        /            \
               Chunk A               Chunk B
                  |                     |
             GPU Worker 0          GPU Worker 1
             Discrete GPU            Vega 8
                  |                     |
              HLS chunks             HLS chunks
                   \                   /
                    \                 /
                     HLS Assembly / Playlist
                              |
                         Client playback
```

For example, a two-hour movie could conceptually be divided into larger transcoding jobs:

```text
00:00–01:00  -> discrete GPU
01:00–02:00  -> Vega 8
02:00–03:00  -> discrete GPU
03:00–04:00  -> Vega 8
...
```

The assignment must be **dynamic**, not permanently round-robin. A faster or less-loaded GPU should receive more work.

---

## 3. Why this is preferable to splitting every HLS segment

The current HLS output uses approximately 4-second segments. That does **not** mean the scheduler should launch a new FFmpeg process for every 4-second segment.

Launching and tearing down FFmpeg that frequently introduces significant overhead:

- decoder initialization
- hardware-device initialization
- encoder initialization
- source seeking
- timestamp setup
- GOP/keyframe boundary handling
- output muxer startup/flush
- process creation overhead

The proposed scheduler should instead use a larger **transcode chunk** and produce the normal HLS segments inside that chunk.

Candidate starting points for benchmarking:

- 30 seconds
- 60 seconds
- 120 seconds

The optimum size must be measured rather than assumed.

HLS segment duration and scheduling chunk duration are therefore separate concepts:

```text
HLS segment:       ~4 seconds
Transcode chunk:   ~30–120 seconds (benchmark)
```

---

## 4. Keyframe / GOP boundary requirement

Chunk boundaries must be aligned with independently decodable video boundaries wherever possible.

The existing transcoder deliberately forces approximately 4-second keyframes using FFmpeg's `-force_key_frames` behavior. This is useful, but future agents must not assume that a nominal time boundary is automatically an exact keyframe boundary.

Before implementing parallel chunk encoding, the scheduler should determine suitable boundaries using media/keyframe information, preferably from `ffprobe` or a controlled encoding strategy.

Failure to respect independently decodable boundaries can cause:

- duplicated frames
- dropped frames
- timestamp discontinuities
- A/V synchronization problems
- visible glitches between chunks
- broken HLS playback
- resume/seek corruption

---

## 5. Proposed architecture

### 5.1 Transcode manager

Introduce a logical layer above individual FFmpeg processes:

```text
TranscodeManager
  |
  +-- GPU capability registry
  |
  +-- Chunk planner
  |
  +-- Work queue
  |
  +-- GPU scheduler
  |
  +-- Chunk state database/cache
  |
  +-- HLS assembler / playlist coordinator
```

This manager should remain independent of the UI.

### 5.2 GPU worker model

Conceptually:

```text
GPUWorker[discrete]
  - backend: NVENC or AMF, depending on OS/hardware path
  - device: explicit adapter identifier
  - utilization: measured or estimated
  - active job: chunk
  - capabilities: codecs/resolutions

GPUWorker[vega8]
  - backend: VAAPI/AMF/other supported backend
  - device: explicit adapter identifier
  - utilization: measured or estimated
  - active job: chunk
  - capabilities: codecs/resolutions
```

The exact backend must be discovered on each host. Never hard-code the assumption that a particular adapter supports a particular backend.

### 5.3 Work queue

A movie becomes a sequence of chunk tasks:

```text
READY
  chunk-0000
  chunk-0001
  chunk-0002
  chunk-0003
  ...
```

Workers claim tasks according to compatibility and load.

A worker finishing early should immediately claim another suitable chunk rather than waiting for a fixed round-robin turn.

---

## 6. Dynamic scheduling strategy

The scheduler should be load-aware.

Do not assume both GPUs have equal performance.

Example:

```text
Discrete GPU: 2.8x realtime
Vega 8:       1.1x realtime
```

The scheduler could naturally assign more chunks to the discrete GPU.

If measured performance changes:

```text
Discrete GPU -> 3 chunks
Vega 8       -> 1 chunk
```

or:

```text
Discrete GPU -> 60 s
Vega 8       -> 60 s
```

or:

```text
Discrete GPU -> 90 s
Vega 8       -> 30 s
```

The exact policy can evolve toward weighted scheduling/work stealing after benchmarks.

A useful first implementation strategy is:

1. Detect capable adapters.
2. Maintain one worker per enabled adapter.
3. Track current assignment and recent throughput.
4. Prefer the least-loaded compatible worker.
5. Update worker weighting from observed throughput.
6. Allow a worker to claim additional queued chunks immediately after completion.

---

## 7. Playback-aware prioritization

The architecture may eventually provide an additional advantage for on-demand playback.

Instead of treating all chunks equally, prioritize the portion closest to current playback:

```text
Current playback window
        |
        v
00:00–05:00   HIGH priority
05:00–15:00   MEDIUM priority
15:00–30:00   BACKGROUND
30:00+        LOWEST priority
```

A possible future strategy is:

```text
Discrete GPU -> current playback / urgent chunks
Vega 8       -> future buffer / lower-priority chunks
```

This is optional and should be considered only after the basic dual-worker pipeline is correct.

---

## 8. HLS assembly model

Parallel chunk outputs must ultimately behave like one continuous HLS stream.

Potential strategies include:

### Strategy A — shared deterministic HLS segment namespace

Each worker writes a known non-overlapping segment-number range into one HLS directory, followed by controlled playlist generation.

Pros:

- potentially avoids a full post-transcode merge
- aligns well with existing HLS cache architecture

Cons:

- concurrent playlist mutation becomes complex
- timestamp continuity must be guaranteed
- failure/retry handling is difficult

### Strategy B — per-chunk temporary HLS directories, then ordered assembly

Each worker writes into a temporary chunk directory:

```text
hls/tmp/chunk-0000/
hls/tmp/chunk-0001/
hls/tmp/chunk-0002/
```

After validation, the coordinator assembles/copies/renames the segments and builds the canonical playlist in order.

Pros:

- clearer ownership
- easier retry and cleanup
- easier validation before publication

Cons:

- additional filesystem operations
- temporary storage requirements

**Preferred initial prototype:** Strategy B, unless benchmarking or the existing HLS resume implementation makes Strategy A clearly safer.

---

## 9. Timestamp and audio requirements

The audio stream is often continuous even when video is processed in chunks.

The implementation must explicitly preserve:

- monotonically correct timestamps
- exact chunk start/end behavior
- audio continuity
- no cumulative A/V drift
- no repeated or missing audio
- valid HLS segment durations

Potential approaches include:

- controlled input seeking and timestamp normalization
- splitting audio consistently with video chunks
- using a single shared decode/remux stage where necessary
- carefully applying FFmpeg timestamp options

Do not assume that independently launched FFmpeg commands will automatically concatenate cleanly.

---

## 10. Source seeking requirements

Arbitrary chunk starts are expensive or inaccurate when they require decoding from a distant previous keyframe.

Chunk planning should therefore prefer keyframe-aligned boundaries where feasible.

For example:

```text
Actual keyframes:
00:00
00:04
00:08
...
00:56
01:00
01:04
...
```

A nominal 60-second boundary can be shifted to an exact suitable keyframe rather than blindly using `-ss 60`.

Benchmark the effect of input-vs-output seeking and keyframe selection before choosing the production strategy.

---

## 11. Failure and retry model

Every chunk should be independently trackable:

```text
PENDING
RUNNING
VALIDATING
COMPLETE
FAILED
RETRYING
```

If the Vega worker fails:

```text
chunk-0042 -> FAILED
                    |
                    v
             requeue chunk
                    |
          discrete GPU claims it
```

A failed GPU should be marked unavailable for subsequent scheduling until it passes a health check.

This is especially important for Windows hardware backends, where driver/device initialization can fail independently of the Python process.

---

## 12. Caching and resume integration

The existing transcoding system already uses deterministic cache paths, HLS directories, progress files and resume logic. Future implementation must preserve those semantics.

The new chunk layer should not create a second unrelated cache universe.

Recommended model:

```text
CACHE_DIR/
  hls/<source-key>/
     chunks/
        chunk-0000/
        chunk-0001/
     playlist.m3u8
  transcodes/
  ...
```

The exact directory layout may differ after implementation review.

The important requirement is that:

- completed chunks survive restart where safe
- incomplete chunks are identifiable
- stale chunks can be purged
- source changes invalidate old chunks
- permanent media deletion removes all associated artifacts

This proposal also interacts directly with the permanent-purge issue documented in GitHub Issue #7.

---

## 13. Worker concurrency limits

Do not blindly launch one FFmpeg process per available GPU plus arbitrary extra workers.

The scheduler must consider:

- CPU threads
- system RAM
- disk throughput
- GPU utilization
- GPU memory
- simultaneous client demand
- active FFmpeg count
- network delivery demand

The current project uses a bounded worker/concurrency architecture. Multi-GPU scheduling must fit into that architecture instead of bypassing it.

---

## 14. Linux and Windows support

The architecture is intended to be cross-platform, but hardware backends differ.

### Linux

Investigate:

- NVIDIA CUDA/NVENC
- AMD VAAPI or another actually supported AMD path
- explicit device selection
- `/dev/dri/*` handling

### Windows

Investigate:

- NVIDIA CUDA/NVENC where applicable
- AMD AMF/D3D11
- explicit D3D11 adapter binding
- reliable adapter discovery

The current Windows work already establishes that explicit D3D11 adapter selection matters and that Windows Task Manager GPU numbering must not be assumed to equal FFmpeg adapter numbering.

Future agents must preserve that rule.

---

## 15. Telemetry requirements

The existing telemetry implementation should evolve from a single-GPU concept to a list of adapters.

Instead of:

```json
{"gpu": {...}}
```

prefer a future shape conceptually similar to:

```json
{
  "gpus": [
    {
      "name": "Discrete GPU",
      "vendor": "NVIDIA/AMD",
      "backend": "nvenc/amf/vaapi",
      "utilization": 97,
      "vram_used": 1234,
      "vram_total": 4096,
      "active_jobs": 1
    },
    {
      "name": "AMD Radeon Vega 8",
      "vendor": "AMD",
      "backend": "vaapi/amf",
      "utilization": 12,
      "active_jobs": 1
    }
  ]
}
```

This is a conceptual API shape, not an instruction to change the API immediately.

The dashboard should eventually display each adapter separately.

---

## 16. Benchmark protocol — mandatory before implementation

The feature must be benchmark-driven.

At minimum measure:

### Test 1 — discrete GPU only

- one transcode
- record realtime factor
- GPU utilization
- GPU memory
- CPU
- RAM
- disk I/O
- output correctness

### Test 2 — Vega 8 only

Same measurements.

### Test 3 — two jobs on the discrete GPU

Determine whether the discrete GPU benefits from parallel FFmpeg work or merely reaches saturation earlier.

### Test 4 — one job on each GPU

Measure aggregate throughput.

### Test 5 — same movie using chunked parallel processing

Try multiple chunk sizes:

- 30 s
- 60 s
- 120 s

### Test 6 — playback-oriented priority scheduling

Optional after the base pipeline is validated.

Record:

- total wall-clock transcoding time
- aggregate realtime factor
- startup latency to first playable HLS segment
- A/V synchronization
- seek correctness
- segment continuity
- output duration
- quality at the same target bitrate
- thermal/power behavior when available

The dual-GPU chunked approach should only be adopted if aggregate throughput and/or startup latency materially improve without unacceptable complexity or quality regressions.

---

## 17. Important non-goals

This proposal does **not** currently authorize:

- combining two GPUs for one individual H.264 frame
- arbitrarily launching dozens of FFmpeg processes
- replacing the current HLS implementation without regression tests
- removing existing CPU fallback paths
- requiring both GPUs to be present
- assuming Vega 8 is useful before benchmarking
- hard-coding adapter index numbers across machines

---

## 18. Future coding-agent instructions

A future coding agent working on this proposal MUST:

1. Read `AGENTS.md`, `docs/PROJECT_STATUS.md`, `docs/DEVELOPMENT_STATUS.md`, and this document before changing transcoding code.
2. Read GitHub Issue #8 and GitHub Issue #7 before modifying worker, cache, purge, or transcoding architecture.
3. Inspect the current `app/services/transcode_service.py` and `app/services/worker_service.py` before designing new classes.
4. Preserve existing direct-play behavior.
5. Preserve existing HLS resume behavior unless the new architecture has equivalent or better behavior and tests prove it.
6. Preserve Linux CPU/VAAPI/NVIDIA fallback behavior.
7. Preserve Windows Waitress/AMF behavior and explicit adapter binding.
8. Detect actual hardware capabilities at runtime.
9. Never assume the GPU named "GPU 0" in Task Manager is the same device as FFmpeg adapter `0`.
10. Do not implement dual-GPU scheduling until baseline benchmarks exist.
11. Prototype with isolated tests/tools before changing production playback behavior.
12. Keep the first implementation small and reversible.
13. Add explicit tests for chunk ordering, timestamps, failure/retry, cache cleanup, and unavailable adapters.
14. Validate actual media output with FFprobe and real playback, not only unit tests.
15. Update project documentation with benchmark findings before declaring the feature complete.

---

## 19. Proposed implementation phases

### Phase 0 — capability discovery

- enumerate all adapters
- enumerate FFmpeg hardware backends
- map adapter identifiers to devices safely
- test one real encode per adapter

### Phase 1 — benchmark harness

- measure per-adapter throughput
- measure concurrent independent jobs
- determine reasonable chunk sizes

### Phase 2 — chunk prototype

- one movie
- two workers
- per-chunk temporary output
- deterministic ordered assembly
- no UI changes initially

### Phase 3 — production integration

- integrate with current HLS cache/resume system
- add failure/retry handling
- add GPU-aware worker scheduling
- maintain existing APIs

### Phase 4 — telemetry

- expose all adapters
- show per-GPU utilization and active jobs
- expose backend/device information

### Phase 5 — playback-aware scheduling

- prioritize current playback window
- pre-buffer future chunks
- dynamically rebalance based on observed throughput

---

## 20. Current project decision

**Decision:** Keep this as an investigation/proposal, not an immediate implementation.

The architecture is promising because the two GPUs do not need to cooperate on the same frame. They can potentially cooperate by processing separate portions of the same source media in parallel.

The deciding evidence must come from real benchmarks on the target host.

The preferred conceptual model is:

```text
              One movie
                  |
          Keyframe-aware planner
                  |
          Dynamic chunk queue
             /          \
            /            \
     Discrete GPU       Vega 8
        worker           worker
            \            /
             \          /
              Ordered HLS
                   |
              Client playback
```

The target outcome is **higher aggregate throughput and/or lower startup latency**, not merely higher reported utilization on both adapters.
