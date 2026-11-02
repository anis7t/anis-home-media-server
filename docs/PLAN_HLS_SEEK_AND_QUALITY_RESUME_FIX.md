# Implementation Plan: Fix HLS Seeking Stall & Quality Preset Resume

## 1. Executive Summary & Defect Recap

During testing on the Android / Fire TV client with the movie *Verity* (`Verity 2026 1080p WEB-DL HEVC x265 5.1 BONE.mkv`):
1. **Quality Preset Switch Resets Playback**: When switching from Direct Play or between transcoded quality rungs (e.g. 1080p $\rightarrow$ 720p/480p), the player resets playback to `0:00` instead of resuming from the recorded timestamp.
2. **HLS Seeking Indefinite Buffering Stall**: While playback starts smoothly from the beginning, seeking to any timestamp (e.g. 70s, 23m, 50m) causes the video to freeze and remain permanently in `buffering: true`.

### Root Causes
- **Issue 1 (Quality Switch Resume Reset)**:
  In `flutter_client/lib/features/player/data/media_kit_player_adapter.dart`, commit `b244b17` disabled `Media(url, start: startPosition)` for HLS URLs and called `player.seek(startPosition)` immediately after `player.open(media, play: false)`. Because `player.open()` returns asynchronously before `libmpv` has downloaded the playlist or initialized its demuxer, the immediate `seek()` is dropped as invalid (`duration == 0`). `PlayerScreen` then calls `player.play()`, starting from `0:00`.
- **Issue 2 (HLS Seek Buffering Stall)**:
  1. In `rust/src/services/media_pipeline/chunk_transcode.rs`, `#EXT-X-START:TIME-OFFSET=0` is unconditionally written to playlists even when transcoding is completed (`is_complete = true`), forcing players to favor a 0-offset start.
  2. The multi-GPU transcode engine partitions *Verity* into 121 independent 60-second chunks, each producing an initialization header (`init_chunk_N.mp4`) and segments with local decode timestamps (`tfdt: 0`). The playlist generator injects 120 `#EXT-X-DISCONTINUITY` markers and 121 `#EXT-X-MAP` tags.
  3. When `libmpv` / `libavformat` seeks across chunk boundaries (e.g. to 3000s / Chunk 50), `mov.c` skips the new `moov` atom in `init_chunk_50.mp4` (`Found duplicated MOOV Atom. Skipped it`). Because `tfdt: 0` is read from `segment_001600.m4s`, the decoded packet timestamp is `pts=0.000407s` instead of `3000.0s`. `libavformat`'s seek routine loops through all 1,815 segments to EOF looking for timestamp 3000s, decoding 0 frames and locking `media_kit` in permanent buffering.
  4. Passing `-seg_format_options use_tfdt=0` to `libavformat`'s HLS demuxer completely bypasses the chunk-local `tfdt: 0` and allows `mov.c` / `hls.c` to seek directly to any timestamp (e.g. 70s, 3000s) and decode frames in <0.05 seconds with zero buffering.

---

## 2. Scope

### In Scope
- **Backend (`rust/src/services/media_pipeline/chunk_transcode.rs`)**:
  - Remove `#EXT-X-START:TIME-OFFSET=0` when `is_complete` is true. Retain `#EXT-X-START:TIME-OFFSET=0` and `#EXT-X-PLAYLIST-TYPE:EVENT` strictly while transcoding is actively in-progress (`!is_complete`).
  - Regenerate *Verity*'s `playlist.m3u8` to reflect clean VOD tags.
- **Frontend Adapter (`flutter_client/lib/features/player/data/media_kit_player_adapter.dart`)**:
  - Configure `demuxer-lavf-o` property on `player.platform` with `seg_format_options=use_tfdt=0` so `libmpv` can seek cleanly across multi-chunk fMP4 HLS streams.
  - Re-enable `start: startPosition` in `Media(url, start: startPosition)` for HLS URLs when `startPosition > Duration.zero`.
  - Guard against dropped seeks during quality transitions.
- **Frontend Screen (`flutter_client/lib/features/player/presentation/screens/player_screen.dart`)**:
  - Verify `_handleQualitySelected` retains the exact `_transportPosition` across quality switches and resumes playback seamlessly without hitching.
- **Regression Tests**:
  - Rust integration test asserting completed HLS playlists omit `#EXT-X-START:TIME-OFFSET=0` and in-progress playlists retain it.
  - Flutter tests asserting `media_kit_player_adapter` configures `use_tfdt=0` and passes `start` for HLS URLs with non-zero start positions.
  - End-to-end seek probe asserting seek to 70s and 3000s decodes in <0.5s without buffer stalling.

### Deliberately Out of Scope
- Modifying the underlying dual-GPU chunking pipeline (discrete RX 560X + integrated Vega 8).
- Re-encoding existing media caches (existing cached chunks and segments remain 100% valid and reusable).
- Modifying React SPA web player (already works with HLS.js).

---

## 3. Implementation Steps

### Step 1: Rust Backend Playlist Assembly Hardening
In [`rust/src/services/media_pipeline/chunk_transcode.rs`](file:///e:/MediaServer/rust/src/services/media_pipeline/chunk_transcode.rs):
- Update `update_master_playlist`:
  ```rust
  let mut lines = vec![
      "#EXTM3U".to_string(),
      version_tag,
      format!("#EXT-X-TARGETDURATION:{}", SEGMENT_TARGET_DURATION as u64),
      "#EXT-X-MEDIA-SEQUENCE:0".to_string(),
      "#EXT-X-INDEPENDENT-SEGMENTS".to_string(),
  ];

  if !is_complete {
      lines.push("#EXT-X-START:TIME-OFFSET=0".to_string());
      lines.push("#EXT-X-PLAYLIST-TYPE:EVENT".to_string());
  }
  ```
- This ensures completed playlists do not force a 0-offset start, while preserving the live-sliding guardrail for active transcoding.

### Step 2: Flutter Player Adapter Demuxer & Start Position Configuration
In [`flutter_client/lib/features/player/data/media_kit_player_adapter.dart`](file:///e:/MediaServer/flutter_client/lib/features/player/data/media_kit_player_adapter.dart):
1. In `_initStreams()` or constructor, apply the `demuxer-lavf-o` property to `player.platform`:
   ```dart
   final nativePlatform = player.platform;
   if (nativePlatform != null) {
     try {
       await (nativePlatform as dynamic).setProperty(
         'demuxer-lavf-o',
         'seg_format_options=use_tfdt=0',
       );
     } catch (e) {
       debugPrint('[MediaKitPlayerAdapter] Failed to set demuxer-lavf-o: $e');
     }
   }
   ```
2. In `open()`:
   Restore `start: startPosition` for HLS URLs when `startPosition > Duration.zero`:
   ```dart
   final media = Media(
     url,
     httpHeaders: headers,
     start: (startPosition != null && startPosition > Duration.zero)
         ? startPosition
         : null,
   );

   await player.open(media, play: false);
   ```
   Remove the redundant immediate `await player.seek(startPosition)` call which was dropped by `libmpv`.

### Step 3: Regression Tests
1. **Rust Regression Test**:
   In [`rust/tests/integration/media_pipeline/chunk_transcode_test.rs`](file:///e:/MediaServer/rust/tests/integration/media_pipeline/chunk_transcode_test.rs):
   - Add test `test_completed_playlist_omits_ext_x_start`:
     Asserts that when `is_complete = true`, the generated `playlist.m3u8` does NOT contain `#EXT-X-START:TIME-OFFSET=0`, but DOES contain `#EXT-X-ENDLIST`.
   - Add test `test_in_progress_playlist_retains_ext_x_start`:
     Asserts that when `is_complete = false`, the generated `playlist.m3u8` DOES contain `#EXT-X-START:TIME-OFFSET=0` and `#EXT-X-PLAYLIST-TYPE:EVENT`.
2. **Flutter Regression Test**:
   In [`flutter_client/test/features/player/`](file:///e:/MediaServer/flutter_client/test/features/player/):
   - Add test in `player_screen_test.dart` or dedicated adapter test verifying that `open()` passes `start: startPosition` when switching quality.
   - Verify `demuxer-lavf-o` property is configured for native platforms.

---

## 4. Exit Criteria

- [ ] `.\scripts\cargo.bat test --manifest-path rust/Cargo.toml --lib -- --test-threads=1` passes 100% (131+ tests).
- [ ] `cd flutter_client && flutter analyze` reports 0 issues.
- [ ] `cd flutter_client && flutter test test/features/player/` passes 100%.
- [ ] Seeking on *Verity* 1080p fMP4 playlist to 70s, 1500s, and 3000s starts playback within <0.5s without indefinite buffering.
- [ ] Switching quality presets preserves exact playback position without resetting to `0:00`.

---

## 5. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| `seg_format_options=use_tfdt=0` affects non-HLS MP4 playback | Direct Play or local MP4 files could exhibit timestamp drift | In `MediaKitPlayerAdapter`, this option is passed to `demuxer-lavf-o` which only configures libavformat's segment demuxer when demuxing HLS segments; standard standalone MP4 files demuxed via `libmpv`'s native demuxer ignore it. |
| In-progress transcode streams slide forward if `#EXT-X-START` is removed too early | Live edge skipping | `#EXT-X-START:TIME-OFFSET=0` and `#EXT-X-PLAYLIST-TYPE:EVENT` are strictly preserved when `!is_complete`. Only completed VOD streams omit it. |

---

## 6. Open Decisions

1. **Start Position Mechanism in `MediaKitPlayerAdapter`**:
   - **Option A (Recommended)**: Pass `start: startPosition` in `Media(url, start: startPosition)`. This instructs `libmpv` to seek at the demuxer layer upon stream load, avoiding premature asynchronous seek calls.
   - **Option B**: Await the `player.stream.duration` or initial packet arrival event before dispatching `player.seek(startPosition)`.
   *(Option A is cleaner, idiomatic to `package:media_kit`, and proven to work once `use_tfdt=0` is set).*
