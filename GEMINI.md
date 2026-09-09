# Media Server Project Guidelines & Invariants

## 1. Process Safety & Task Management (Strict Guardrail)
- **Zero Lingering Test Tasks**: Under no circumstances should background automation tasks (Selenium, WebDriver, FFmpeg) be left running indefinitely or orphaned.
- **Selenium Cleanup**: All browser automation scripts must wrap driver lifecycles in `try ... finally: if driver: driver.quit()`.
- **Bounded Wait Times**: Scripts must use bounded polling (max 15–20s) and explicitly exit. Never run blocking polling loops that hang conversational turns or force IDE restarts.

## 2. Live Browser Testing Protocol
- **Live Context Required**: When the user requests browser verification, run tests in the live desktop session using `DISPLAY=:0.0` so execution is visible.
- **Driver Initialization**: In this Linux environment, Selenium Manager cannot auto-download binaries. Always explicitly configure:
  ```python
  service = Service('/usr/bin/geckodriver')
  options.binary_location = '/usr/bin/firefox'
  ```

## 3. Media Playback & Transcoding Invariants
- **Multi-Format Regression Checks**: When updating HLS segmentation for MKV/HEVC or seek handling, verify that:
  - Both MKV (HLS) and direct MP4/AAC streams (*Oculus*, *Spider-Man*, *GTA VI*, *Ghost in the Cell*) remain playable.
  - Seeking to time `0:00` functions smoothly without freezing or indefinite "Preparing media" states.

## 4. Video Player & Subtitle Viewport Invariants
- **Viewport Clamping**: In CSS, never allow `<video>` to expand container height via intrinsic aspect ratio or unconstrained CSS Grid rows. Use:
  ```css
  video {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: contain;
    background: #000;
  }
  ```
  This guarantees that in non-fullscreen or tiled windows (e.g. 1024×424), the video element never overflows below the viewport.
- **Cue Elevation**: Subtitle cues rendered via WebVTT must be elevated (baseline `line: -3.5`, `line: -4` for huge font sizes) so single-line and multi-line cues sit comfortably above the playback controls across all font sizes (75%–200%).
- **Timestamp Regex**: When converting or parsing WebVTT timestamps, match both `HH:MM:SS.mmm` and `MM:SS.mmm` (`r'((?:\d\d:)?\d\d:\d\d\.\d{3}\s*-->\s*(?:\d\d:)?\d\d:\d\d\.\d{3})'`).

## 5. Mobile Responsive & Viewport Clamping Invariants
- **Root Viewport Clamping**: On mobile-targeted pages, both `html` and `body` must explicitly declare:
  ```css
  html.details-html, body.details-page {
    width: 100%;
    max-width: 100%;
    overflow-x: hidden;
    touch-action: pan-y;
  }
  ```
  Never rely solely on `body { overflow-x: hidden }`, as mobile rendering engines (WebKit, Blink, Gecko) treat `html` as the root scrolling canvas.
- **Grid & Flex Child Track Clamping (`min-width: 0`)**: Any element relying on `text-overflow: ellipsis` or variable-length metadata (e.g. subtitle track listings, audio codecs, long titles) MUST have `min-width: 0; max-width: 100%;` applied to its container and all ancestor grid/flex tracks (e.g. `minmax(0, 1fr)`). Without `min-width: 0`, `auto` tracks expand to the intrinsic text width and blow out mobile viewports.
- **Sub-Scroll Gesture Isolation**: Horizontally swipeable rails (such as cast lists or carousel strips) must specify:
  ```css
  .cast-rail {
    width: 100%;
    max-width: 100%;
    min-width: 0;
    overscroll-behavior-x: contain;
    touch-action: pan-x;
    -webkit-overflow-scrolling: touch;
  }
  ```
  This prevents internal swipe gestures from bubbling up and causing accidental page-level horizontal panning.

