# Implementation Plan: Fix Movie Posters Visibility & Player Controls Hover Immunity

## 1. Problem Diagnosis & Root Causes

### Issue 1: Movie Posters Not Visible on Catalog & Details
- **Symptom:** The library catalog (`/`) renders 53 movie cards, but poster artwork is completely missing (gray placeholder boxes). The movie details page (`/movie/*`) also lacks backdrop artwork.
- **Root Cause Analysis:**
  1. In the React frontend (`web/src/lib/api/poster.ts`), `posterUrl(poster)` expects the canonical server format starting with `tmdb:<id>` (e.g., `tmdb:62`) or `local:<path>`. If `poster` does not start with one of these prefixes, it returns `null` (displaying an empty placeholder).
  2. In `rust/src/services/movie_service.rs`, `list_movies` and `get_movie_details` execute SQL queries against PostgreSQL and attempt to extract:
     ```rust
     let tmdb_id: Option<i64> = r.try_get("tmdb_id").ok();
     let vote_avg: Option<f64> = r.try_get("vote_average").ok();
     ```
  3. In PostgreSQL, the `tmdb_id` column is an `INTEGER` (32-bit `i32`) and `vote_average` is a `REAL` (32-bit `f32`).
  4. SQLx strictly checks data types during runtime extraction. Attempting to extract `INTEGER` as `i64` or `REAL` as `f64` returns a `ColumnDecode(Mismatching types)` error.
  5. Because `.ok()` was chained, SQLx silently suppressed the error and returned `None` for every movie's `tmdb_id`.
  6. As a result, `poster` defaulted to `poster_path` (`/ve72VxNqjGM69Uky4WTo2bK6rfq.jpg`), failing the `tmdb:` prefix check in `posterUrl()`. Similarly, `movie.tmdb_id` returned `null`, breaking `backdropUrl(movie.tmdb_id)`.

### Issue 2: Player Controls Auto-Hiding While Pointer is on Seekbar
- **Symptom:** While watching a video in `PlayerPage.tsx`, the bottom controls overlay and seekbar fade out and disappear after 2.5 seconds, even when the user's cursor is actively hovering over the seekbar, reading timestamps, or inspecting thumbnail previews.
- **Root Cause Analysis:**
  1. In `web/src/features/playback/PlayerPage.tsx`, `resetControlsTimer` unconditionally sets a 2.5-second auto-hide timeout whenever `playing && !isScrubbing`:
     ```tsx
     if (playing && !isScrubbing) {
       controlsTimerRef.current = setTimeout(() => {
         setControlsVisible(false);
       }, 2500);
     }
     ```
  2. `isScrubbing` is only `true` while the pointer is actively dragged (pointer down). When the mouse simply hovers over the seekbar or thumbnail preview, `isScrubbing` is `false`.
  3. The controls container (`#controls`) and seekbar (`#seekTrack`) had no pointer hover detection or timer suspension. If the user paused their mouse on the seekbar for 2.5 seconds, the controls vanished under their cursor.

---

## 2. Proposed Changes

### Component 1: Rust Backend (`rust/src/services/movie_service.rs`)
1. **SQL Query Type Casting:**
   - In both `list_movies` (for both device history and global progress branches) and `get_movie_details`, explicitly cast:
     ```sql
     m.tmdb_id::BIGINT as tmdb_id,
     m.vote_average::DOUBLE PRECISION as vote_average,
     ```
2. **Defensive Type Extraction in Rust:**
   - In `list_movies` and `get_movie_details`, accept both `i64` and `i32` for `tmdb_id`:
     ```rust
     let tmdb_id: Option<i64> = r.try_get::<Option<i64>, _>("tmdb_id")
         .ok()
         .flatten()
         .or_else(|| r.try_get::<Option<i32>, _>("tmdb_id").ok().flatten().map(|id| id as i64));
     ```
   - Accept both `f64` and `f32` for `vote_average`:
     ```rust
     let vote_avg: Option<f64> = r.try_get::<Option<f64>, _>("vote_average")
         .ok()
         .flatten()
         .or_else(|| r.try_get::<Option<f32>, _>("vote_average").ok().flatten().map(|v| (v as f64 * 10.0).round() / 10.0));
     ```
3. **Verify Poster Formatting:**
   - When `tmdb_id` is present (`Some(tid)`), `poster` outputs `Some(format!("tmdb:{}", tid))`.
   - The React client `posterUrl("tmdb:62")` will resolve to `/tmdb-poster/62`, which is reverse-proxied by Rust to Flask port 8000 and served with HTTP 200 JPEG.

### Component 2: React Player Seekbar (`web/src/features/playback/PlayerSeekbar.tsx`)
1. Add `onHoverChange?: (isHovered: boolean) => void` to `PlayerSeekbarProps`.
2. Invoke `onHoverChange?.(true)` on `handleMouseEnter`, `handleMouseMove`, and input `onPointerEnter`.
3. Invoke `onHoverChange?.(false)` on `handleMouseLeave` and input `onPointerLeave` (when not scrubbing).

### Component 3: React Player Page (`web/src/features/playback/PlayerPage.tsx`)
1. Track both `isControlsHovered` and `isSeekbarHovered` using state and refs (`isControlsHoveredRef`, `isSeekbarHoveredRef`).
2. Attach `onPointerEnter` and `onPointerLeave` to `#controls`:
   - `onPointerEnter`: Clears `controlsTimerRef` immediately and ensures `controlsVisible = true`.
   - `onPointerLeave`: Starts the auto-hide timer (increased from 2.5s to 3.0s).
3. Connect `onHoverChange={(hovered) => { setIsSeekbarHovered(hovered); isSeekbarHoveredRef.current = hovered; if (hovered && controlsTimerRef.current) clearTimeout(controlsTimerRef.current); }}` to `PlayerSeekbar`.
4. Update `resetControlsTimer`:
   - If `isControlsHoveredRef.current || isSeekbarHoveredRef.current || isScrubbing`, do NOT set the hide timer. Controls remain visible indefinitely as long as the mouse is over the controls or seekbar.
   - If mouse is over the video canvas and idle for 3.0 seconds, smoothly hide controls.

---

## 3. Verification & Testing Plan

1. **Rust Test Suite:**
   - Run `cargo test` in `rust/` to verify all 57 existing integration and contract tests pass.
2. **Frontend Test Suite:**
   - Run `npm test -- --run` in `web/` to verify all 172 Vitest unit tests pass.
3. **Service Rebuild:**
   - Recompile release binary and restart `MediaServerRust` via `scripts\restart_rust_service.bat`.
   - Rebuild React frontend via `npm run build` in `web/`.
4. **Live Browser Verification (Headful Chrome):**
   - Launch `scripts/verify_phase_2r_d_e2e.py` or an interactive test session to verify:
     a. **Home Catalog (`/`):** All movie cards display real TMDb posters loaded via `/tmdb-poster/<id>`.
     b. **Movie Details (`/movie/*`):** Both poster artwork and top backdrop banner display real TMDb images.
     c. **Player Seekbar (`/watch/*`):** Hover cursor on seekbar for 5+ seconds without moving. Verify controls and seekbar stay 100% visible and do not hide.
     d. Move cursor over video canvas and hold still for 3 seconds. Verify controls fade out cleanly.
