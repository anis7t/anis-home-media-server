# Triage Plan — Issue 14.3: Playback Stuck at 0:00 (Web)

**Date:** 2026-10-23 (IST 03-18)
**Issue:** [`docs/Current issues.md`](../docs/Current%20issues.md) → Issue 14, fault 3
**Branch:** `fix/issue-14-user-reported-faults`

---

## 1. Fault

Movies such as *2001: A Space Odyssey* do not play automatically and, after pressing play, stay at
**0:00**. Occasionally, after trying other media and returning to the unplayable media, it does
play — consistency uncertain.

## 2. Context

- Player invariants (AGENTS.md §6): direct play (zero-copy RFC 7233) vs HLS (fMP4); container
  isolation; seeking must not sync `currentTime` on every drag; `/api/media-info` duration semantics
  (video end for HLS, container end for direct).

## 3. Hypotheses

1. Autoplay policy blocking (user gesture required) in some entry paths.
2. HLS master playlist / direct-play flag mis-evaluation for that title.
3. Media-info probe failure leaving the player at 0:00.
4. Transcode/direct-play decision inconsistency causing the player to sit unplayable.

## 4. Verification approach

- Live: signed-in web browser, play *2001*; capture `/api/media-info`, console logs, network.
- Test manual vs autoplay; direct vs HLS delivery.

## 5. Exit criteria

- Root cause isolated; fix applied narrowly without violating player invariants.

## 6. Risks / open decisions

- High-blast-radius area (player); avoid broad rewrites; keep Flutter contract intact.

---

**Next step (pending approval):** reproduce, then fix.
