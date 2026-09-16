# Media Server Project Guidelines & Invariants

## 1. Process Safety & Task Management (Strict Guardrail)
- **Zero Lingering Test Tasks**: Under no circumstances should background automation tasks (Selenium, WebDriver, FFmpeg) be left running indefinitely or orphaned.
- **Selenium Cleanup**: All browser automation scripts must wrap driver lifecycles in `try ... finally: if driver: driver.quit()`.
- **Bounded Wait Times**: Scripts must use bounded polling (max 15–20s) and explicitly exit. Never run blocking polling loops that hang conversational turns or force IDE restarts.

## 2. Browser Testing & Automation Protocol
- **Autonomous Browser Automation Permitted**: The agent may use Selenium / WebDriver automation to inspect DOM state, test interactions, and capture screenshots for its own analysis and verification.
- **No Interactive User Expectation**: Do not wait for the user to interact with the automated test browser, and do not expect browser windows to appear in the user's desktop session. Automated browser scripts must execute entirely autonomously and terminate promptly.
- **Strict Process Safety & Teardown**: Always wrap driver instances in `try ... finally: if driver: driver.quit()` to ensure zero orphaned WebDriver or browser background processes.

## 3. Media Playback & Transcoding Invariants
- **Multi-Format Regression Checks**: When updating HLS segmentation for MKV/HEVC or seek handling, verify that:
  - Both MKV (HLS) and direct MP4/AAC streams (*Oculus*, *Spider-Man*, *GTA VI*, *Ghost in the Cell*) remain playable.
  - Seeking to time `0:00` functions smoothly without freezing or indefinite "Preparing media" states.
- **In-Progress Transcode HLS Timeline Synchronization**:
  - Dynamic chunk-based HLS playlists must specify `#EXT-X-START:TIME-OFFSET=0` and `#EXT-X-PLAYLIST-TYPE:EVENT` while transcoding is active. This prevents HLS.js and native video elements from treating the stream as a live sliding window and skipping forward to the live edge.
  - Chunk worker encoders must apply `-output_ts_offset <start_time>` corresponding to each chunk's timeline offset to maintain monotonic presentation timestamps (PTS) across chunk transitions.
  - Master playlist assembly must parse actual `#EXTINF:<duration>,` segment durations from individual chunk playlists (`chunk_{id}.m3u8`) rather than assuming constant segment lengths, preventing cumulative timeline drift.

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
- **Header Multi-Action Wrapping**: Top navigation forms containing a search input alongside multiple action buttons must declare:
  ```css
  @media(max-width: 768px) {
    header form {
      max-width: 100%;
      width: 100%;
      min-width: 0;
      display: flex;
      flex-wrap: wrap;
      gap: .5rem;
    }
    header input {
      min-width: 0;
      flex: 1 1 100%;
    }
    header select, header button, header .header-nav-btn {
      flex: 1 1 auto;
      justify-content: center;
      text-align: center;
      min-width: 0;
    }
  }
  ```
  This prevents rightmost navigation elements (such as `📁 My Library`) from overflowing off-screen on phones.

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

## 9. Modal Dialog Safety & Touch Dismissal Invariants
- **Destructive/Critical Modal Outside-Touch Immunity**:
  - Confirmation modals for irreversible or destructive actions (such as `#purgeModal`) must NEVER dismiss on backdrop touch or click.
  - Omit native `closedby="any"` and do NOT register backdrop bounding-box dismissal listeners (`if (e.target !== dialog) close()`).
  - Destruction or permanent deletion modals must require explicit user action via a dedicated close cross button (`✕`), Cancel button, or the Escape key.
- **Zero Vertical Scrolling on Mobile Modals**:
  - Mobile modals must be designed with compact vertical footprints (total height \(\le 260\text{px}\)) using `max-height: min(90vh, 90dvh)`, reduced padding (\(\le 1\text{rem}\)), and concise checklist copy (\(\le 3\) items).
  - Modals must fit within compact 375×667 mobile viewports without forcing vertical scrolling.

## 10. Upload Telemetry & Post-Upload Ingestion Invariants
- **Post-Upload Abort Concealment**:
  - In `XMLHttpRequest` upload workflows, immediately hide the Abort/Cancel button (`cb.style.display = 'none'`) upon `xhr.upload` completion (`load` event).
  - Once file bytes are written to disk, client abort is invalid because server-side background ingestion (TMDb querying, ffprobe stream analysis, transcode profiling) has begun.
- **Dynamic In-Progress Processing Indicator**:
  - Post-upload backend processing must NOT display a static checklist of tasks.
  - Implement an animated dynamic processing card with an active spinner and cycling status labels (e.g. *Probing video stream...*, *Querying TMDb...*, *Caching posters...*, *Synchronizing subtitles...*) to give continuous visual feedback while the server finishes indexing.
- **Exponentially Smoothed Upload ETA**:
  - Upload progress handlers must apply exponential moving average smoothing to transfer speed (`smoothSpeed = smoothSpeed * 0.7 + instSpeed * 0.3`) and render human-readable remaining time (`ETA: Xm Ys` or `ETA: Xs`).

## 11. Jinja Template Safety & DOM Attribute Invariants
- **Data Attributes for Dynamic Values**: Never pass dynamic Jinja expressions directly into inline JavaScript function arguments (e.g., `onclick="fn('{{ dev.name }}')"`). Unescaped quotes or apostrophes (such as `Anis' iPhone`) cause JavaScript `SyntaxError: missing ) after argument list`. Always bind values to HTML5 data attributes with HTML escaping (`data-name="{{ dev.name|e }}"`) and retrieve them via `this.dataset.name` or `element.dataset.*`.
- **Defensive NoneType Containment Checks**: Jinja's `in` operator raises `TypeError: argument of type 'NoneType' is not a container or iterable` when checking containment against a variable that can be `None`. Always guard with an explicit truthiness check:
  ```jinja2
  {% if dev.mac_address and 'WAN' in dev.mac_address %}
  ```

## 12. Client Telemetry, User-Agent Reduction & Heartbeats
- **Chromium High-Entropy Client Hints**: To identify Android device make, model, and OS versions accurately despite Chromium User-Agent Reduction (which freezes UAs to `Linux; Android 10; K`):
  - In `create_app()`, set response headers:
    ```python
    response.headers['Accept-CH'] = 'Sec-CH-UA-Model, Sec-CH-UA-Platform-Version, Sec-CH-UA-Platform, Sec-CH-UA-Mobile, Sec-CH-UA-Arch, Sec-CH-UA-Bitness'
    response.headers['Permissions-Policy'] = 'ch-ua-model=*, ch-ua-platform-version=*'
    ```
  - Use `navigator.userAgentData.getHighEntropyValues(['model', 'platformVersion'])` on the client to report real hardware models and Android releases to `POST /api/devices/client-hints`.
  - Maintain a brand/model decoding dictionary in `device_service.py` to translate OEM model codes (e.g., `I2011`, `SM-S928B`, `Pixel 8`) into human-readable consumer names.
- **Client Heartbeat & Active State Lifecycle**:
  - Implement periodic client keepalive pings (`POST /api/devices/heartbeat` every 40s) only when `document.visibilityState === 'visible'`.
  - Dispatch a `navigator.sendBeacon('/api/devices/heartbeat')` on the `pagehide` event to immediately mark the client's departure or final active timestamp.
  - Active threshold must be bounded (e.g. 3 minutes) with distinct status indicators (🟢 Active now vs ⚪ Offline) and top-level filter tabs.

## 13. Single-Script Block & Dynamic Asset Injection Invariants
- **Single Script Block on Player View**: In `templates/player.html`, automated test invariants strictly assert that the template contains exactly one `<script>` block (`html.count('</script>') == 1`). Never add auxiliary `<script src="...">` or `<script>` tags to `player.html`.
- **Dynamic Script Loading**: When external JavaScript modules (such as navigation transitions, telemetry, or third-party libraries) must be included on the player page, inject them dynamically from within the existing `<script>` block:
  ```javascript
  const s = document.createElement('script');
  s.src = '/static/js/nav.js';
  s.defer = true;
  document.head.appendChild(s);
  ```

## 14. Navigation Transitions, Canvas Isolation & Motion Accessibility
- **Player Canvas Isolation**: Video playback containers (`#shell`, `<video>`, `.watch-info`) must remain strictly isolated from page-enter and cross-document transition animations (e.g. `main:not(#shell):not(.watch-info)`). Never apply layout transforms or translate keyframes to `#shell`.
- **Motion Accessibility**: All view transitions, progress bars, and page enter animations must provide `@media (prefers-reduced-motion: reduce)` overrides (`animation: none !important; transition: none !important; display: none !important;`).
- **bfcache (Back/Forward Cache) Resilience**: Navigation progress indicators must bind to the `pageshow` event and check `e.persisted` to immediately reset animation and dimming states when users navigate with browser Back/Forward gestures.

## 15. HTML5 Media Seeking, Range Streaming & Slider Invariants
- **Direct Stream Isolation**: Never invoke transcode status polling (`checkPreparing`) or display transcoding overlay cards on native direct streams (`!source.dataset.transcoded`). Transcode status endpoints return `status: "idle"` for direct files, which must never set seek locks or leave `currentSeekTarget` frozen.
- **Decoupled Seek Scrubbing & Commit**:
  - Dragging/scrubbing gestures (`seek.oninput`) must only update visual seek fills and time HUD indicators (`isScrubbing = true`).
  - Do NOT set `v.currentTime` synchronously on micro-pixel movements during drag, which floods the server with aborted HTTP range requests.
  - Commit seeks (`v.currentTime = target`) strictly on gesture completion (`pointerup`, `touchend`, `change`, and window fallback listeners) and resume playback cleanly if the video was active prior to scrubbing.
- **In-Flight Seek Snapback Prevention**:
  - In `timeupdate` listeners, guard seek bar value updates with `!isScrubbing && !v.seeking`.
  - Never allow `timeupdate` to overwrite `seek.value` back to old timestamps while the browser is actively fulfilling a byte-range seek request (`v.seeking === true`).
- **Range Slider Keyboard Focus Immunity**:
  - Interacting with range sliders (`<input id="seek" type="range">`) gives them DOM focus. Never use naive `e.target.matches('input,select')` in `keydown` listeners, as this disables all playback shortcuts (`Space`, `k`, `j`, `l`, `1`–`9`, arrow keys).
  - Guard only text-entry inputs (`input:not([type="range"])`), and explicitly blur range sliders (`seek.blur()`) upon seek commit.
- **Zero-Copy RFC 7233 Range Streaming**:
  - In raw media streaming routes (`/media/<path:filename>`), use Flask/Werkzeug `send_file(path, mimetype=mimetype(path), conditional=True, etag=True, max_age=3600)` rather than custom file chunk generators.
  - This guarantees OS zero-copy streaming (`sendfile(2)`), RFC 7233 byte-range parsing, `If-Range` support, and clean socket closure upon client disconnect without blocking worker threads.

## 16. Windows Process Probing & Test Harness Safety (Strict Guardrail)
- **Zero Console Signal Broadcasting via `os.kill(pid, 0)`**:
  - In Python on Windows, `signal.CTRL_C_EVENT == 0`.
  - Calling `os.kill(pid, 0)` on Windows invokes `GenerateConsoleCtrlEvent(CTRL_C_EVENT, pid)`, broadcasting a `CTRL_C_EVENT` interrupt across the shared console process group.
  - In IDE/agent execution sessions, this Ctrl+C interrupt terminates the IDE language server / Antigravity agent process (`agy.exe`), triggering sudden `"Action cancelled by user"` and `"Lost connection to the language server. Agent features may not work."`.
  - **Strict Invariant**: NEVER call `os.kill(pid, 0)` to check process liveness on Windows. Always use `is_pid_alive(pid)` from `app.services.transcode_service` (exported in `app`), which safely queries process status using the Win32 API (`OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, False, pid)` + `GetExitCodeProcess`).
- **TemporaryDirectory File Locks in Windows Pytest**:
  - SQLite databases or temporary fixtures created during tests may trigger `[WinError 32] The process cannot access the file because it is being used by another process` on teardown due to Windows file-locking semantics.
  - When creating `tempfile.TemporaryDirectory()`, always pass `ignore_cleanup_errors=True` on Python 3.10+.
- **Terminal Environment Relaunch Settings**:
  - Keep `"terminal.integrated.environmentChangesRelaunch": true` and `"python.terminal.shellIntegration.enabled": false` in `.vscode/settings.json` to prevent VS Code extension environment contributions (e.g. `ms-python.debugpy`, `copilot-chat`) from stalling terminals or showing blocking relaunch prompt banners.

## 17. Subdirectory Routing & Subtitle Language Auto-Detection Invariants
- **Werkzeug Multi-Path Greedy Collision**:
  - Never configure consecutive `<path:...>` parameters separated by slashes (e.g. `@subtitles_bp.route('/subtitles/<path:filename>/<path:name>')`). Werkzeug's first path parameter captures non-greedily up to the first slash, which breaks whenever files reside in subdirectories (such as `Folder/Video.mkv`), matching only the directory and returning a 404.
  - Always terminate multi-segment paths with a single component: `@subtitles_bp.route('/subtitles/<path:filename>/<name>')`.
- **Subtitle Language Auto-Detection & Priority**:
  - Subtitle files without language suffixes (e.g., `movie.srt`) must not be left unclassified (`und`).
  - Use `detect_subtitle_language()` to analyze script unicode characters (Devanagari, Cyrillic, Hanzi, Hiragana, Hangul, Arabic, Bengali) and vocabulary stop-word frequency before defaulting to unknown.
  - Local subtitles must always take priority over external API lookups (e.g. OpenSubtitles) when verified to match language, setting `default: True` and preventing redundant network requests.
- **Windows Service Privileges & NSSM Management**:
  - The production `MediaServer` service runs under `NT AUTHORITY\SYSTEM`. Stopping or restarting it requires elevated privileges. Use `scripts/restart_service.bat` (which requests UAC elevation via `Start-Process ... -Verb RunAs`) or an elevated PowerShell terminal (`Restart-Service MediaServer`).
