# Slice C Walkthrough: Subtitle Delay Flicker Elimination

## 1. Executive Summary
- **Issue**: Modifying subtitle delay in the web player using hotkeys (`z` / `x` for ±50ms, `Z` / `X` for ±250ms) or the Subtitle Settings modal caused visible cue flickering, layout resets, and dropped frames on every adjustment step.
- **Solution**:
  - Made `applySubStyles` idempotent: guards DOM mutations by checking if `sEl.textContent !== newCss` before re-injecting CSS into `document.head`.
  - Decoupled preferences effects in `useSubtitles`:
    - **Visual Styles Effect**: Only fires when `color`, `bgOpacity`, `size`, or `align` changes.
    - **Cue Layout Effect**: Only fires when `verticalPos`, `pos`, `align`, or `size` changes, guarded by strict property equality checks.
    - **Timing Offset Effect**: Dedicated effect that shifts `c.startTime` and `c.endTime` dynamically using epsilon comparison (`Math.abs > 0.001`), completely bypassing `<style>` DOM mutations and cue layout resets.
  - Made `adjustOffset` synchronous and deterministic via `latestPrefsRef` to eliminate React update batching delays.
  - Debounced `localStorage` persistence (300ms) with flush on unmount to prevent synchronous disk I/O on rapid keystrokes.
  - Memoized `elevateCues` callback with `useCallback` to prevent cascading hook re-renders in `PlayerPage.tsx`.

---

## 2. Key Code Changes

### Web Client (`web/src/features/playback/useSubtitles.ts`)
1. **Idempotent `applySubStyles`**:
   - Compares generated CSS with `sEl.textContent` before assigning.
2. **`applyCueLayout` & `applyCueTiming` Functions**:
   - `applyCueLayout(c, snap, targetLine, targetAlign, targetPos)`: Updates layout properties only when different from existing cue values.
   - `applyCueTiming(c, offset)`: Caches `_origStartTime` and `_origEndTime`, applying `newStart = Math.max(0, origStart + offset)` and `newEnd = newStart + dur` with epsilon checks.
3. **Decoupled `useEffect` Hooks**:
   - Split single monolithic effect into three dedicated effects for visual CSS, cue layout, and timing offset.
4. **Synchronous `adjustOffset` Calculation**:
   - Reads `latestPrefsRef.current.offset`, calculates clamped offset immediately, and returns the accurate target offset synchronously.
5. **Debounced `savePrefs`**:
   - Prevents synchronous `localStorage.setItem` during rapid 50ms key taps.

### New Unit Tests (`web/src/features/playback/useSubtitles.test.ts`)
- Verified `applySubStyles` idempotency (setter spy confirmed zero writes when styles are unchanged).
- Verified `applyCueTiming` duration preservation and bounds clamping.
- Verified `applyCueLayout` property setting.
- Verified `elevateCues` full track iteration and `cuechange` registration.
- Verified `adjustOffset` offset calculation, bounds clamping ([-5s, +5s]), and HUD toast formatting.

---

## 3. Verification & Test Battery
- **Unit Tests (`useSubtitles.test.ts`)**: **5/5 passed**.
- **Playback Suite (`SubtitleSettingsModal.test.tsx` + `PlayerPage.test.tsx`)**: **29/29 passed**.
- **Full Vitest Suite**: **208/208 passed across all 30 test files**.
- **TypeScript Typecheck (`tsc -b`)**: **0 errors**.
- **Vite Production Build**: **Clean compilation in 822ms** into `web/dist/`.
- **Android Client Probe (`scripts/probe_android_api.py`)**: **22/22 endpoints passed**.
