# Triage Plan — Issue 14.3: Playback Stuck at 0:00 (Web)

**Date:** 2026-10-23 (IST)
**Issue:** [`docs/Current issues.md`](Current%20issues.md) → Issue 14, fault 3
**Branch:** `fix/issue-14-user-reported-faults`
**Status:** ✅ **FIXED and verified** (2026-10-23). Root cause measured, fix applied in
`web/src/features/playback/PlayerPage.tsx`, regression tests added, live playback verified. The
earlier "fix implemented and verified" status in this file was withdrawn before the restart; see §2.

---

## 1. Fault

Movies such as *2001: A Space Odyssey* do not start playing when the player opens, and after pressing
play they stay at **0:00**. Occasionally, after trying other media and returning, the same title does
play. Consistency unknown to the reporter.

---

## 2. Why this triage was restarted

The previous entry in this file recorded the fault as "player mode initialization / gesture handling"
and shipped two changes to `web/src/features/playback/PlayerPage.tsx`. Both are withdrawn:

1. **`togglePlay()` error reporting.** The cause of the stall is not a rejected `play()` promise, so
   logging one changes nothing. Worse, `setError()` is not a HUD: `error` replaces the whole player
   with *"Playback unavailable"*, so a perfectly normal autoplay-policy rejection would turn a
   press-play-to-start screen into a dead end.
2. **A mount-time `pendingQualityRestoreRef` pre-seed** in place of the Picture-in-Picture listeners.
   On mount it stores `{ seekTime: 0, shouldPlay: false }`, so the first `loadedmetadata` takes the
   restore branch and **returns before the autoplay and resume blocks** — suppressing both — and the
   PiP `enterpictureinpicture` / `leavepictureinpicture` listeners are deleted outright.

Both hunks were reverted from the working tree on 2026-10-23 before this plan was written. Note that
`web/dist` **was built while they were present** (assets `index-Dx7FGXJ9.js`, 05:06) and the running
service is serving that build; the fix must be followed by a rebuild and a service restart.

---

## 3. Measured evidence (2026-10-23)

Reproduced in Microsoft Edge (`--disable-gpu`, `--autoplay-policy=no-user-gesture-required`), against
the live service on `http://127.0.0.1:8000`, driving the real `/watch/*` route.

| Observation | Value |
| --- | --- |
| `<video>` `src` attribute, 8 s after the player rendered | `null` |
| `<video>` `currentSrc` / `readyState` / `networkState` | `''` / `0` / `0` (`NETWORK_EMPTY`) |
| Requests to `/media/` | **none** (only `/api/media-info`, `200`, 1.3 s) |
| Clicking the centre Play button | `paused` → `false`, `currentTime` stays `0`, `duration` stays `null` |
| Selecting *Direct Play (Source)* in the quality ladder | `src` attaches, `readyState` 4, playing at 2.71 s, one `206` on `/media/` |
| A second direct-play MP4 (*Monsters Inc*) on a fresh mount | `src` `null`, `readyState` 0 — identical |
| `GET /api/media-info` | `direct_play: true`, `duration: 8931.712`, `is_transcode_ready: true` |
| File itself | `ftyp@0, moov@32, mdat@6 060 479` — **faststart**, 2.44 GB |
| `GET /media/…` with `Range: bytes=0-1023` | `206`, `content-type: video/mp4`, correct `content-range` |

**The server, the file, `media-info` and the direct-play decision are all correct. The `<video>`
element is simply never given a source.** `play()` on an element with no resource resolves and waits
forever, which is exactly "press play, nothing happens, stays at 0:00" — with no console error and no
failed request, which is why the previous triage found nothing to log.

---

## 4. Root cause

`PlayerPage.tsx:506` attaches the media source in an effect that gates on the element ref:

```tsx
useEffect(() => {
  const video = videoRef.current;
  if (!video || !mode || !isPlaybackReady) return;   // <- runs once with null
  …
}, [decoded, effectiveMode, selectedQuality, isPlaybackReady, mode]);
```

The page early-returns a "Probing media…" skeleton while `loading || !info || !mode`
(`PlayerPage.tsx:1267`), so the `<video>` is **not mounted** on the commit that first sets
`info`. The probe handler sets `info` at line 275 and `loading = false` at line 295 — **after** an
`await` on `probeClientMediaCapabilities`. Those are therefore two separate commits:

1. **Commit A** — `info` arrives, `loading` still `true`: `mode` and `isPlaybackReady` change from
   `undefined`/`false` to `'direct'`/`true`, the effect runs, `videoRef.current` is `null`, it returns.
2. **Commit B** — the capability probe resolves, `loading` becomes `false`: the `<video>` mounts, but
   **no dependency of the effect changes**, so the effect never runs again.

Nothing re-attaches the source until an unrelated dependency moves — a quality selection, a changed
direct-play verdict, or a re-probe. That is the intermittency the reporter described: the player works
the moment anything nudges `selectedQuality`, `effectiveMode`, `mode` or `isPlaybackReady`, and "works
after trying other media" is the same nudge arriving by another route (inferred from the measured
dep-change behaviour, not from a separate experiment).

HLS titles are structurally immune: the transcode poll keeps updating `transcode`, and
`isPlaybackReady` moves when the cache becomes ready, which re-runs the effect after the element
exists.

---

## 5. Fix design

**Recommended — make the element's availability observable to the effect.**

```tsx
const videoRef = useRef<HTMLVideoElement | null>(null);
const [videoEl, setVideoEl] = useState<HTMLVideoElement | null>(null);
const attachVideo = useCallback((node: HTMLVideoElement | null) => {
  videoRef.current = node;
  setVideoEl(node);
}, []);
…
<video ref={attachVideo} … />
```

then in the attach effect (and in the PiP listener effect, which has the same defect):

```tsx
const video = videoEl;
…
}, [videoEl, decoded, effectiveMode, selectedQuality, isPlaybackReady, mode]);
```

The callback is referentially stable, so React calls it only on mount/unmount; `setVideoEl` with an
identical node is a no-op. This is four small edits, keeps `videoRef` for every existing imperative
caller, and touches no other behaviour.

**Rejected alternatives.**

- *Add `loading` to the dependency array.* Works, because `loading` flips at the same moment the
  element mounts — but it is a coincidence of the current early-return condition, not a statement that
  the effect depends on the element. It breaks again the moment the skeleton condition changes.
- *Render `<video>` outside the early return.* Correct in principle, but it restructures the player's
  loading shell and enlarges the regression surface for a four-line defect. Out of scope.
- *A `setTimeout` retry or a `requestAnimationFrame` poll.* Hides an ordering bug behind timing.
  Rejected.

---

## 6. Scope

**In scope**

- `web/src/features/playback/PlayerPage.tsx`: the callback-ref state, the attach effect and the PiP
  listener effect dependencies.
- `web/src/features/playback/PlayerPage.test.tsx`: a regression test that mounts the page with the
  probe resolving in two commits (media-info first, capabilities second) and asserts the `<video>`
  receives the `/media/` source — the exact sequencing jsdom can control and a live browser cannot.
- `docs/TRIAGE_03_PLAYBACK_ZERO_STALL.md` (this file) and a dated entry in
  `docs/Current issues.md` → Issue 14.3.
- Rebuild `web/dist` and restart `MediaServerRust`, verified by artefact timestamp per `AGENTS.md`.

**Explicitly out of scope**

- The HLS path, the transcode gate, resume semantics, seeking, subtitles, casting, keyboard handling.
- `useSubtitles`' own `videoRef` reads. It has the same class of defect, but its track list arrives
  asynchronously and re-runs it, so it is not implicated here; changing its contract now would mix two
  fixes.
- Issues 14.1, 14.2, 14.4, 14.5 and 14.6 and their working-tree edits.
- Any backend, `/api/*` or Flutter-client change.

---

## 7. Exit criteria

1. **Direct play attaches a source with no user action.** Fresh navigation to
   `2001.A.Space.Odyssey.1968.1080p.BluRay.x264-[YTS.AM].mp4`: `src` non-empty within 5 s of the
   player rendering, at least one `206` on `/media/`, `readyState >= 2`, and `currentTime > 0` with no
   click and no quality change. (Same harness as §3, which currently fails at 0 for 8 s.)
2. **A second direct-play title behaves identically** (*Monsters Inc*), proving the fix is not
   title-specific.
3. **HLS is unregressed.** A `needs_transcode` title still reaches the transcode gate and, once ready,
   plays from `/hls/`.
4. **A quality switch still preserves position and play state** — the path that used to be the only
   way to start playback must keep working.
5. **Resume is unregressed:** a title with saved progress above 30 s still resumes there rather than
   starting at 0.
6. **PiP state still tracks:** `#pipBtn` reflects `enterpictureinpicture` / `leavepictureinpicture`.
7. `cd web && npm run typecheck && npm run lint && npm run test` green, `npm run build` green.
8. `python scripts/probe_android_api.py` → 22/22 (the client contract is untouched; run it because a
   deploy is part of the work).
9. Deployed binary/asset freshness proven by timestamp, not by `/health`.

---

## 8. Risks

- **A callback ref that sets state can cause an extra render or a loop if it is not stable.** It is
  `useCallback(…, [])` and setting the same node is a no-op; the regression test would catch a loop as
  a render-count blow-up.
- **Unmount ordering.** React detaches the callback ref (passing `null`) around unmount; the effect's
  `teardown()` closes over its own `video` variable and never re-reads the ref, so a detached node
  cannot be torn down twice. `removeAttribute('src')` on a detached element is harmless; verify the
  existing unmount flush test still passes.
- **Autoplay policy.** Without `--autoplay-policy=no-user-gesture-required`, a first `play()` may still
  be rejected until a gesture — correct browser behaviour, unchanged by this fix. The fix guarantees
  the *source*, which is what makes the press-play path work; exit criterion 1 is measured with the
  flag, and the manual check is a signed-in browser without it.
- **Stale deployed build.** The running `web/dist` was built from the withdrawn WIP. Shipping the fix
  requires `npm run build` + a `MediaServerRust` restart, verified by artefact timestamp — a `/health`
  200 proves only that *some* build is running.
- **GPU.** The verification harness runs headless Edge with `--disable-gpu` and must not run while a
  transcode is active (`AGENTS.md` §7: GPU TDR / hard-reset history).

---

## 9. Open decisions

1. **Fix shape** — callback-ref state (recommended, §5) or the one-token `loading` dependency
   (smaller diff, fragile).
2. **A rejected user-initiated `play()`** — surface a transient HUD ("Playback could not start") or
   stay silent as today? Recommended: HUD, because silence is what made this bug invisible.
3. **`useSubtitles`' identical ref-read defect** — fix in this slice or record it as a separate issue?
   Recommended: record it, keep this slice single-purpose.
4. **`preload="metadata"`** — leave unchanged (recommended; the defect is not a preload problem).

---

## 10. Verification procedure

```powershell
# 1. Unit / component
cd web; npm run typecheck; npm run lint; npm run test; npm run build; cd ..

# 2. Live direct-play + HLS harness (headless Edge, --disable-gpu, no transcode running)
node C:\Users\anis7\AppData\Local\Temp\opencode\repro-14-3.cjs   # must now show src + currentTime > 0
node C:\Users\anis7\AppData\Local\Temp\opencode\repro-14-3b.cjs  # title A and title B both attach

# 3. Client contract
python scripts/probe_android_api.py

# 4. Deploy proof
scripts\restart_rust_service.bat
Get-Item rust\target\release\media-server-api.exe | Select LastWriteTime
Get-ChildItem web\dist\assets\index-*.js | Select LastWriteTime
```

---

**Status:** investigation complete, fix not yet applied. Awaiting approval to implement §5 and run §10.

---

## 11. Implementation (2026-10-23, approved)

**File:** `web/src/features/playback/PlayerPage.tsx`

```tsx
const [videoEl, setVideoEl] = useState<HTMLVideoElement | null>(null);
const attachVideo = useCallback((node: HTMLVideoElement | null) => {
  videoRef.current = node;
  setVideoEl(node);
}, []);
…
<video id="video" ref={attachVideo} … />
```

- source-attach effect: `const video = videoEl;`, dependencies
  `[videoEl, decoded, effectiveMode, selectedQuality, isPlaybackReady, mode]`;
- PiP listener effect: `const v = videoEl;`, dependencies `[videoEl]`;
- `togglePlay()`: a rejected `play()` now raises a transient `showHud('Playback could not start')`
  instead of being swallowed. It deliberately does **not** call `setError`, which replaces the whole
  player.

`videoRef` is retained for every existing imperative caller; only the two mount-sensitive effects and
the ref callback changed.

**Regression tests** — `web/src/features/playback/PlayerPage.test.tsx`,
`describe('PlayerPage source attachment (Issue 14.3)')`:

1. *attaches the direct-play source when the `<video>` mounts after the probe resolves* — holds the
   capability probe open across the commit that sets `info` (the real browser ordering), then releases
   it and asserts the `/media/` source is attached. The file's `probeClientMediaCapabilities` is
   mocked with a gate (`probeGate`) because jsdom settles the whole probe inside one microtask and
   would otherwise hide the ordering defect entirely.
2. *tracks Picture-in-Picture state* — dispatches `enterpictureinpicture` / `leavepictureinpicture`
   and asserts `#pipBtn` reflects both.

**Proof the tests pin the defect:** with the player reverted to `HEAD` and the new tests kept,
`PlayerPage.test.tsx` reports **2 failed | 23 passed** — both new tests fail. With the fix restored,
**25 passed**.

**Live verification** (headless Microsoft Edge, `--disable-gpu`, no transcode running, against the
live service on `:8000`):

| Check | Result |
| --- | --- |
| *2001* cold load, **no interaction** | `src` attached at 1.5 s, one `206` on `/media/`, `readyState` 4, playing from 2.0 s, `duration` 8931.712 |
| *2001* playhead | advancing 0.11 → 6.29 s over 8 s of observation; buffered ahead of the playhead |
| *Monsters Inc* (second direct title) | `src` attached, `readyState` 4, playing, `duration` 5535.905 |
| Quality switch to *Direct Play (Source)* during playback | position and play state preserved (6.11 s, still playing) |
| *28 Days Later* (HLS / `needs_transcode`) | mode `hls`, master playlist `200`, ABR 360p↔720p, `readyState` 4, playing at 4.67 s, no console errors |
| Console / failed requests on all three | none |

**Suite state:** `npm run typecheck` and `npm run lint` clean; `npm run build` green
(`index-CzhLP70g.js`), and the live server serves that asset from `web/dist` (no service restart
required — the SPA is read from disk; no Rust source changed). `python scripts/probe_android_api.py`
→ **22/22**.

`npm run test` is **9 failed | 307 passed**, and all nine failures are in
`LibraryPage.test.tsx` (`Error: useAuth must be used inside <AuthProvider>`), caused by the retained
Issue 14.2 `Avatar` edit in `LibraryPage.tsx` — not by this fix. `PlayerPage.test.tsx` is 25/25.
Resume (exit criterion 5) is covered by the existing resume unit tests; no live title currently holds
a >30 s resume point, and writing one would pollute real watch history.

**Exit criteria:** 1 ✅, 2 ✅, 3 ✅, 4 ✅, 5 ✅ (unit), 6 ✅ (unit), 7 ⚠️ (blocked by the retained
14.2 edit, see above), 8 ✅, 9 ✅.

