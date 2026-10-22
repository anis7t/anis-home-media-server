# Slice D Walkthrough: Native 4K HEVC Direct Play Unlock via W3C Media Capabilities API

## 1. Executive Summary
- **Issue**: Chrome 107+ natively supports hardware-accelerated HEVC (H.265) Direct Play when GPU decoding is present. However, 4K HEVC playback was blocked on the web client because `probeClientMediaCapabilities` hardcoded an obsolete Level 3.1 profile string (`hvc1.1.6.L93.B0`, restricted to <=720p) and hardcoded 1080p probe dimensions, causing modern GPU decoders in Chromium to report `supported: false` and needlessly trigger heavy transcode jobs on the dual AMD server GPUs.
- **Solution**:
  - Upgraded `normalizeVideoCodecMime` to be dimension-aware:
    - 4K HEVC (`width >= 3840` or `height >= 2160`): `hvc1.1.6.L150.90` (Level 5.0 Main 10).
    - 1080p HEVC: `hvc1.1.6.L120.90` (Level 4.0 Main 10).
    - 4K H.264: `avc1.640033` (Level 5.1 High Profile).
    - 4K VP9: `vp09.00.50.10`.
    - 4K AV1: `av01.0.12M.10`.
  - Extended `probeClientMediaCapabilities` to accept `options?: { width?: number | null; height?: number | null; bitrate?: number | null; framerate?: number | null }`.
  - Fed real video dimensions into `navigator.mediaCapabilities.decodingInfo()`.
  - Implemented automatic fallback probing for the alternative `hev1.1.6.L150.90` parameter tag if `hvc1` is rejected.
  - Made the verdict cache dimension-aware (`${container}:${video}:${audio}:${w}x${h}`) and added `clearVerdictCache()` for test isolation.
  - Updated `PlayerPage.tsx` to pass `result.width` and `result.height` into `probeClientMediaCapabilities`.

---

## 2. Key Code Changes

### Web Client (`web/src/lib/capabilities/mediaCapabilities.ts`)
- Added `width` and `height` parameters to `normalizeVideoCodecMime` to construct standard Level 5.0 MIME strings for 4K.
- Added `MediaProbeOptions` interface and passed actual dimensions into `navigator.mediaCapabilities.decodingInfo()`.
- Implemented dual `hvc1` / `hev1` parameter tag probing.
- Added resolution dimensions to `verdictCache` key to avoid caching collisions across different quality tiers.

### Web Player Integration (`web/src/features/playback/PlayerPage.tsx`)
- Passed `result.width` and `result.height` from `getMediaInfo` directly to `probeClientMediaCapabilities`.

### Unit Tests (`web/src/lib/capabilities/mediaCapabilities.test.ts`)
- Verified 4K HEVC MIME generation (`hvc1.1.6.L150.90`).
- Verified 4K H.264 Level 5.1 MIME generation (`avc1.640033`).
- Verified 4K HEVC Direct Play unlock when W3C mediaCapabilities reports `supported: true`.
- Verified alternate `hev1` tag probing when `hvc1` is rejected.
- Verified existing codec tests continue to pass.

---

## 3. Verification & Test Battery
- **Unit Tests (`mediaCapabilities.test.ts`)**: **8/8 passed**.
- **Player Suite (`PlayerPage.test.tsx`)**: **23/23 passed**.
- **Full Vitest Suite**: **212/212 passed across all 30 test files**.
- **TypeScript Typecheck (`tsc -b`)**: **0 errors**.
- **Vite Production Build**: **Clean compilation in 792ms** into `web/dist/`.
- **Android Client Probe (`scripts/probe_android_api.py`)**: **22/22 endpoints passed**.
