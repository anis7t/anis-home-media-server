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
- **Player Shell Container Isolation**: The `#shell` element uses `display: grid; place-items: center; overflow: hidden`. Supplementary page sections (such as `<main class="watch-info">`) MUST be placed outside `#shell` following its closing `</div>` (`</div><main class="watch-info">`). Never allow `#shell` to remain unclosed, as CSS grid placement will center supplementary content (such as movie posters and synopsis cards) directly over the `<video>` canvas.
- **Dual-Axis Subtitle Positioning & Cue Elevation**:
  - Subtitle settings must support both **Horizontal Alignment** (`center`, `left`, `right`) and **Vertical Position** (`lowered`, `bottom`, `raised`, `middle`, `top`).
  - WebVTT cues must be elevated to prevent overlapping playback controls:
    - `lowered`: `c.snapToLines = true; c.line = isHuge ? -2.8 : -2.2`
    - `bottom` (Default): `c.snapToLines = true; c.line = isHuge ? -4.8 : -4`
    - `raised`: `c.snapToLines = true; c.line = isHuge ? -6.2 : -5.5`
    - `middle`: `c.snapToLines = false; c.line = 50`
    - `top`: `c.snapToLines = true; c.line = 2`
  - Subtitle preview elements (`#subPreviewBox`) must synchronize both `justifyContent` (horizontal) and `alignItems` (vertical).
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

## 6. Git Operations & Index Recovery Protocol
- **Zero Data Loss Index Recovery**: If Git fails with `fatal: .git/index: index file smaller than expected` (due to `.git/index` being truncated to 0 bytes), NEVER run `git reset --hard` or `git clean`. Run the non-destructive recovery:
  ```bash
  rm -f .git/index && git reset
  ```
  This immediately regenerates `.git/index` from `HEAD` and leaves all modified files and untracked assets completely intact.
- **Non-Interactive Push Guardrail**: Do not run `git push` commands that prompt for credentials in non-interactive background terminals. Instruct the user to use VS Code's Source Control Sync button (`⟳ 1 ↑`) or provide explicit credentials.

## 7. Modular Architecture & Package Import Invariants
- **Package Precedence (`app/` vs `app.py`)**: When `app/` directory and root `app.py` coexist, Python resolves `import app` to `app/__init__.py`.
  - `app/__init__.py` must export `app = create_app()` and all public interfaces (`init_db`, `get_db`, `CSS`, `DETAILS_HTML`, `video_paths`, `_paths`, etc.) to maintain 100% compatibility with test imports and external scripts.
  - Root `app.py` must remain lightweight and executable as the systemd entrypoint (`/usr/bin/python3 /home/iamroot/media-server-1/app.py`).
- **Dual Blueprint Endpoint Aliasing**: In `create_app()`, all blueprint endpoints must also be registered as bare route names (e.g. `details` alongside `pages.details`, `poster` alongside `api.poster`) so that `url_for('details')` calls in templates and helpers resolve cleanly without blueprint prefix requirements.

## 8. Player Gestures, Navigation & Telemetry Invariants
- **Tap-to-Reveal Playback Interaction**:
  - When controls are hidden during active playback, a tap/click on `#shell` must FIRST reveal controls without toggling play/pause.
  - Play/pause should only toggle if the controls were already visible when the user initiated the interaction.
- **Non-Redundant Navigation & Title Alignment**:
  - The in-player back button (`.watch-back`) must use concise text (`← Details` or `← Back`) to avoid duplicating title text alongside `.watch-title-badge`.
  - `.watch-title-badge` must declare an explicit horizontal offset (`left: calc(1.2rem + 95px)`) and `max-width` clamping so it sits adjacent to the back button without visual clipping or overlap.
- **Stats for Nerds (Telemetry HUD)**:
  - Technical telemetry buttons in `.controls-row` must be direct child buttons (preserving `#restartBtn` as the first element and no nested `<div>`s in `.controls-row`).
  - Live stats HUD (`#nerdStatsHud`) must track `v.getVideoPlaybackQuality()` (dropped/total frames), native vs viewport resolution, forward buffer calculation, and stream transcode state, accessible via button, close button, and keyboard shortcut `n` / `N`.
