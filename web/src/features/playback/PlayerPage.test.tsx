import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { PlayerPage } from './PlayerPage';

/*
 * hls.js reports `isSupported() === false` under jsdom because jsdom
 * implements neither MediaSource nor the codecs HLS needs. Left unmocked, every
 * HLS test would take the "this browser cannot play HLS" branch and assert
 * nothing about playback. Mocking it also keeps the dynamic import from pulling
 * a 500 kB module into the test run.
 */
const mockLoadSource = vi.fn();
const mockAttachMedia = vi.fn();
const mockDestroy = vi.fn();

vi.mock('hls.js', () => {
  class MockHls {
    static isSupported(): boolean {
      return true;
    }
    static Events = { ERROR: 'hlsError' };
    static ErrorTypes = { NETWORK_ERROR: 'networkError', MEDIA_ERROR: 'mediaError' };
    loadSource = mockLoadSource;
    attachMedia = mockAttachMedia;
    on = vi.fn();
    startLoad = vi.fn();
    recoverMediaError = vi.fn();
    destroy = mockDestroy;
  }
  return { default: MockHls };
});

const FILENAME = '2001 A Space Odyssey (1968) [BluRay]/2001.mkv';

function renderPlayer() {
  return render(
    <MemoryRouter initialEntries={[`/watch/${encodeURI(FILENAME)}`]}>
      <Routes>
        <Route path="/watch/*" element={<PlayerPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

function jsonResponse(body: unknown, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 200 ? 'OK' : 'Error',
    json: async () => body,
  } as Response;
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
  mockLoadSource.mockClear();
  mockAttachMedia.mockClear();
  mockDestroy.mockClear();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('PlayerPage playback mode', () => {
  it('takes the direct path and never polls transcode status for a direct stream', async () => {
    /*
     * AGENTS.md, Player invariants: "Direct streams must remain isolated from
     * transcoding status/polling logic." A direct play has no transcode to wait
     * for. This is asserted rather than assumed, because the natural
     * implementation polls unconditionally and the failure is invisible until
     * someone reads the network tab.
     */
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/media-info/')) {
        return jsonResponse({
          container: 'matroska',
          duration: 900,
          direct_play: true,
          needs_transcode: false,
          is_transcode_ready: false,
        });
      }
      if (url.startsWith('/api/subtitles/')) return jsonResponse({ tracks: [] });
      if (url.startsWith('/api/progress?')) return jsonResponse({ position: 0, duration: 900 });
      throw new Error(`unexpected request: ${url}`);
    });

    renderPlayer();

    await waitFor(() => {
      expect(screen.getByTestId('player')).toHaveAttribute('data-mode', 'direct');
    });

    // Give any stray poll a chance to fire before asserting its absence.
    await new Promise((resolve) => setTimeout(resolve, 50));

    const requested = fetchMock.mock.calls.map((call) => String(call[0]));
    expect(requested.some((url) => url.includes('/api/transcode-status/'))).toBe(false);
  });

  it('polls transcode status while an HLS cache is still building', async () => {
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/media-info/')) {
        return jsonResponse({
          container: 'matroska',
          duration: 900,
          direct_play: false,
          needs_transcode: true,
          is_transcode_ready: false,
        });
      }
      if (url.startsWith('/api/transcode-status/')) {
        return jsonResponse({
          status: 'building',
          percent: 42,
          remaining: 90,
          encoded: 0,
          duration: 900,
          speed: 2.4,
        });
      }
      if (url.startsWith('/api/subtitles/')) return jsonResponse({ tracks: [] });
      if (url.startsWith('/api/progress?')) return jsonResponse({ position: 0, duration: 900 });
      throw new Error(`unexpected request: ${url}`);
    });

    renderPlayer();

    await waitFor(() => {
      expect(screen.getByTestId('player')).toHaveAttribute('data-mode', 'hls');
    });

    await waitFor(() => {
      const requested = fetchMock.mock.calls.map((call) => String(call[0]));
      expect(requested.some((url) => url.includes('/api/transcode-status/'))).toBe(true);
    });

    // The waiting state must be visible, not a silent blank player.
    expect(await screen.findByText(/building a transcode/i)).toBeInTheDocument();
  });

  it('surfaces a probe failure instead of rendering an empty player', async () => {
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/media-info/')) return jsonResponse({}, 404);
      if (url.startsWith('/api/progress?')) return jsonResponse({ position: 0, duration: 0 });
      throw new Error(`unexpected request: ${url}`);
    });

    renderPlayer();

    expect(await screen.findByRole('alert')).toHaveTextContent(/playback unavailable/i);
  });
});

/*
 * Resume and progress persistence. jsdom gives a <video> no duration and no
 * seekable media, so the element's properties are stubbed per test.
 */
function stubVideo({ duration, currentTime = 0 }: { duration: number; currentTime?: number }) {
  let time = currentTime;
  Object.defineProperty(HTMLMediaElement.prototype, 'duration', {
    configurable: true,
    get: () => duration,
  });
  Object.defineProperty(HTMLMediaElement.prototype, 'currentTime', {
    configurable: true,
    get: () => time,
    set: (value: number) => {
      time = value;
    },
  });
  return {
    get currentTime() {
      return time;
    },
  };
}

function directPlayPayload() {
  return {
    container: 'mp4',
    duration: 3600,
    direct_play: true,
    needs_transcode: false,
    is_transcode_ready: false,
  };
}

describe('PlayerPage resume', () => {
  beforeEach(() => {
    // Remove any property stubs left by a previous test.
    Reflect.deleteProperty(HTMLMediaElement.prototype, 'duration');
    Reflect.deleteProperty(HTMLMediaElement.prototype, 'currentTime');
  });

  it('resumes a meaningful saved position', async () => {
    const video = stubVideo({ duration: 3600, currentTime: 0 });
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/media-info/')) return jsonResponse(directPlayPayload());
      if (url.startsWith('/api/subtitles/')) return jsonResponse({ tracks: [] });
      if (url.startsWith('/api/progress?')) return jsonResponse({ position: 1200, duration: 3600 });
      throw new Error(`unexpected request: ${url}`);
    });

    renderPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    // jsdom never fires this on its own once `src` is assigned.
    const element = document.querySelector('video') as HTMLVideoElement;
    fireEvent.loadedMetadata(element);

    await waitFor(() => expect(video.currentTime).toBe(1200));
  });

  it('does not resume a position under the 30s threshold', async () => {
    const video = stubVideo({ duration: 3600, currentTime: 0 });
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/media-info/')) return jsonResponse(directPlayPayload());
      if (url.startsWith('/api/subtitles/')) return jsonResponse({ tracks: [] });
      // 12s in - the viewer has barely started.
      if (url.startsWith('/api/progress?')) return jsonResponse({ position: 12, duration: 3600 });
      throw new Error(`unexpected request: ${url}`);
    });

    renderPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    fireEvent.loadedMetadata(document.querySelector('video') as HTMLVideoElement);
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect(video.currentTime).toBe(0);
  });

  it('does not resume a position within the final 3% of the title', async () => {
    const video = stubVideo({ duration: 3600, currentTime: 0 });
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/media-info/')) return jsonResponse(directPlayPayload());
      if (url.startsWith('/api/subtitles/')) return jsonResponse({ tracks: [] });
      // 3580 / 3600 = 99.4% - effectively finished.
      if (url.startsWith('/api/progress?')) return jsonResponse({ position: 3580, duration: 3600 });
      throw new Error(`unexpected request: ${url}`);
    });

    renderPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    fireEvent.loadedMetadata(document.querySelector('video') as HTMLVideoElement);
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect(video.currentTime).toBe(0);
  });

  it('starts at zero when there is no saved progress', async () => {
    const video = stubVideo({ duration: 3600, currentTime: 0 });
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/media-info/')) return jsonResponse(directPlayPayload());
      if (url.startsWith('/api/subtitles/')) return jsonResponse({ tracks: [] });
      if (url.startsWith('/api/progress?')) return jsonResponse({ position: 0, duration: 3600 });
      throw new Error(`unexpected request: ${url}`);
    });

    renderPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    fireEvent.loadedMetadata(document.querySelector('video') as HTMLVideoElement);
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect(video.currentTime).toBe(0);
  });

  it('persists the position when the player unmounts', async () => {
    stubVideo({ duration: 3600, currentTime: 600 });
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/media-info/')) return jsonResponse(directPlayPayload());
      if (url.startsWith('/api/subtitles/')) return jsonResponse({ tracks: [] });
      if (url.startsWith('/api/progress?')) return jsonResponse({ position: 600, duration: 3600 });
      if (url === '/api/progress')
        return jsonResponse({ ok: true }, 200);
      throw new Error(`unexpected request: ${url}`);
    });

    const { unmount } = renderPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    // Mirror a real session: timeupdate fires during playback, which is what
    // keeps the persisted position current.
    fireEvent.loadedMetadata(document.querySelector('video') as HTMLVideoElement);
    fireEvent.timeUpdate(document.querySelector('video') as HTMLVideoElement);

    unmount();

    await waitFor(() => {
      const posts = fetchMock.mock.calls.filter(
        (call) => String(call[0]) === '/api/progress' && call[1]?.method === 'POST',
      );
      expect(posts).toHaveLength(1);
      expect(posts[0][1].body).toContain('"position":600');
    });
  });
});

describe('PlayerPage extended controls & telemetry', () => {
  beforeEach(() => {
    Reflect.deleteProperty(HTMLMediaElement.prototype, 'duration');
    Reflect.deleteProperty(HTMLMediaElement.prototype, 'currentTime');
  });

  function setupStandardPlayer() {
    stubVideo({ duration: 3600, currentTime: 100 });
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/media-info/')) return jsonResponse(directPlayPayload());
      if (url.startsWith('/api/subtitles/')) return jsonResponse({ tracks: [] });
      if (url.startsWith('/api/progress?')) return jsonResponse({ position: 100, duration: 3600 });
      throw new Error(`unexpected request: ${url}`);
    });
    return renderPlayer();
  }

  it('renders all Phase 3 controls buttons with correct DOM IDs', async () => {
    setupStandardPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    expect(document.getElementById('restartBtn')).toBeInTheDocument();
    expect(document.getElementById('play')).toBeInTheDocument();
    expect(document.getElementById('skipBackBtn')).toBeInTheDocument();
    expect(document.getElementById('skipForwardBtn')).toBeInTheDocument();
    expect(document.getElementById('mute')).toBeInTheDocument();
    expect(document.getElementById('volume')).toBeInTheDocument();
    expect(document.getElementById('speed')).toBeInTheDocument();
    expect(document.getElementById('qualityBtn')).toBeInTheDocument();
    expect(document.getElementById('ccMergedPill')).toBeInTheDocument();
    expect(document.getElementById('aspectBtn')).toBeInTheDocument();
    expect(document.getElementById('rotateBtn')).toBeNull();
    expect(document.getElementById('volumePercent')).toBeInTheDocument();
    expect(document.getElementById('pipBtn')).toBeInTheDocument();
    expect(document.getElementById('nerdStatsBtn')).toBeInTheDocument();
    expect(document.getElementById('shortcutsBtn')).toBeInTheDocument();
    expect(document.getElementById('full')).toBeInTheDocument();
  });

  it('cycles aspect ratio modes and displays HUD toast', async () => {
    setupStandardPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    const aspectBtn = document.getElementById('aspectBtn')!;
    const video = document.getElementById('video')!;

    // Initial aspect is fit
    expect(video.className).toContain('aspect-fit');

    // Click aspectBtn -> crop
    fireEvent.click(aspectBtn);
    expect(video.className).toContain('aspect-crop');
    expect(document.getElementById('playerHud')?.textContent).toBe('Aspect: Crop (Zoom)');

    // Press 'a' key -> stretch
    fireEvent.keyDown(window, { key: 'a' });
    expect(video.className).toContain('aspect-stretch');
    expect(document.getElementById('playerHud')?.textContent).toBe('Aspect: Stretch');
  });

  it('updates volume percentage indicator and progressive fill slider', async () => {
    setupStandardPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    const volumeSlider = document.getElementById('volume') as HTMLInputElement;
    const volumePercent = document.getElementById('volumePercent')!;

    expect(volumePercent.textContent).toBe('100%');
    expect(volumeSlider.style.background).toContain('100%');

    // Change volume to 0.5
    fireEvent.change(volumeSlider, { target: { value: '0.5' } });
    expect(volumePercent.textContent).toBe('50%');
    expect(volumeSlider.style.background).toContain('50%');
    expect(document.getElementById('playerHud')?.textContent).toBe('🔊 50%');
  });

  it('renders movie details section below player shell', async () => {
    setupStandardPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    const watchInfo = document.querySelector('main.watch-info');
    expect(watchInfo).toBeInTheDocument();

    // Ensure watchInfo is outside #shell
    const shell = document.getElementById('shell')!;
    expect(shell.contains(watchInfo)).toBe(false);

    expect(screen.getByRole('heading', { level: 1 })).toBeInTheDocument();
    expect(screen.getByText('← Back to Details')).toBeInTheDocument();
    expect(screen.getByText("← Anis' Home Media Server")).toBeInTheDocument();
  });

  it('toggles Nerd Stats HUD on button click and keyboard shortcut', async () => {
    setupStandardPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    const nerdBtn = document.getElementById('nerdStatsBtn')!;
    expect(document.getElementById('nerdStatsHud')).toBeNull();

    // Open via button
    fireEvent.click(nerdBtn);
    expect(document.getElementById('nerdStatsHud')).toBeInTheDocument();
    expect(nerdBtn.className).toContain('active');

    // Close via 'Escape'
    fireEvent.keyDown(window, { key: 'Escape' });
    expect(document.getElementById('nerdStatsHud')).toBeNull();

    // Toggle via 'n' key
    fireEvent.keyDown(window, { key: 'n' });
    expect(document.getElementById('nerdStatsHud')).toBeInTheDocument();

    // Close via close button
    const closeBtn = document.getElementById('closeNerdStats')!;
    fireEvent.click(closeBtn);
    expect(document.getElementById('nerdStatsHud')).toBeNull();
  });

  it('toggles Shortcuts modal on button click and ? shortcut', async () => {
    setupStandardPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    const scBtn = document.getElementById('shortcutsBtn')!;
    expect(document.getElementById('shortcutsModal')).toBeNull();

    // Open via button
    fireEvent.click(scBtn);
    expect(document.getElementById('shortcutsModal')).toBeInTheDocument();

    // Close via 'Escape'
    fireEvent.keyDown(window, { key: 'Escape' });
    expect(document.getElementById('shortcutsModal')).toBeNull();

    // Open via '?' key
    fireEvent.keyDown(window, { key: '?' });
    expect(document.getElementById('shortcutsModal')).toBeInTheDocument();
  });

  it('renders preloader and seek ripples in player shell', async () => {
    setupStandardPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    const preloader = document.getElementById('playerPreloader');
    expect(preloader).not.toBeNull();

    const leftRipple = document.getElementById('seekRippleLeft');
    const rightRipple = document.getElementById('seekRippleRight');
    expect(leftRipple).not.toBeNull();
    expect(rightRipple).not.toBeNull();
    expect(leftRipple).toHaveAttribute('hidden');
    expect(rightRipple).toHaveAttribute('hidden');
  });

  it('triggers ripples on skip back and skip forward', async () => {
    setupStandardPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    const skipBackBtn = document.getElementById('skipBackBtn')!;
    const skipForwardBtn = document.getElementById('skipForwardBtn')!;

    // Skip back triggers left ripple
    fireEvent.click(skipBackBtn);
    expect(document.getElementById('seekRippleLeft')).not.toHaveAttribute('hidden');

    // Skip forward triggers right ripple
    fireEvent.click(skipForwardBtn);
    expect(document.getElementById('seekRippleRight')).not.toHaveAttribute('hidden');
  });

  it('triggers left and right ripples on double-tap zones', async () => {
    setupStandardPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    const shell = document.getElementById('shell')!;
    vi.spyOn(shell, 'getBoundingClientRect').mockReturnValue({
      left: 0,
      top: 0,
      width: 1000,
      height: 600,
      right: 1000,
      bottom: 600,
      x: 0,
      y: 0,
      toJSON: () => {},
    });

    // Double-tap left zone (clientX = 200 < 400)
    fireEvent.click(shell, { clientX: 200, clientY: 300 });
    fireEvent.click(shell, { clientX: 200, clientY: 300 });

    expect(document.getElementById('seekRippleLeft')).not.toHaveAttribute('hidden');

    // Double-tap right zone (clientX = 800 > 600)
    fireEvent.click(shell, { clientX: 800, clientY: 300 });
    fireEvent.click(shell, { clientX: 800, clientY: 300 });

    expect(document.getElementById('seekRippleRight')).not.toHaveAttribute('hidden');
  });

  it('locks playback behind TranscodeGate when media requires transcoding and is not 100% ready', async () => {
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/media-info/')) {
        return jsonResponse({
          container: 'matroska',
          duration: 900,
          direct_play: false,
          needs_transcode: true,
          is_transcode_ready: false,
        });
      }
      if (url.startsWith('/api/transcode-status/')) {
        return jsonResponse({
          status: 'transcoding',
          percent: 55,
          remaining: 60,
          encoded: 495,
          duration: 900,
          speed: 2.1,
        });
      }
      if (url.startsWith('/api/subtitles/')) return jsonResponse({ tracks: [] });
      if (url.startsWith('/api/progress?')) return jsonResponse({ position: 0, duration: 900 });
      throw new Error(`unexpected request: ${url}`);
    });

    renderPlayer();

    expect(await screen.findByRole('region', { name: /transcode progress gate/i })).toBeInTheDocument();
    expect(screen.getByText(/Dual AMD GPU Transcoder Active/i)).toBeInTheDocument();
    expect(await screen.findByText(/Transcoding 55%/i)).toBeInTheDocument();

    const shell = document.getElementById('shell');
    expect(shell).toHaveStyle({ display: 'none' });
  });

  it('opens CastModal on cast button click and switches to CastBar upon device selection', async () => {
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = typeof input === 'string' ? input : input.toString();
      if (url.startsWith('/api/media-info/')) {
        return jsonResponse({
          filename: 'test.mp4',
          container: 'mp4',
          duration: 3600,
          direct_play: true,
          needs_transcode: false,
          is_transcode_ready: true,
        });
      }
      if (url.startsWith('/api/seek-preview-meta/')) {
        return jsonResponse({ duration: 3600, interval: 10, count: 360, base_url: '/seek-preview/test.mp4' });
      }
      if (url.startsWith('/api/subtitles/')) return jsonResponse({ tracks: [] });
      if (url.startsWith('/api/progress?')) return jsonResponse({ position: 0, duration: 3600 });
      if (url.startsWith('/api/cast/devices')) {
        return jsonResponse({
          ok: true,
          devices: [
            {
              id: 'dlna:samsung-tv-1',
              name: 'Living Room TV',
              kind: 'dlna',
              model: 'Samsung QLED',
              ip: '192.168.1.100',
            },
          ],
          scanning: false,
        });
      }
      if (url.startsWith('/api/cast/play')) {
        return jsonResponse({ ok: true, device: 'Living Room TV' });
      }
      if (url.startsWith('/api/cast/status')) {
        return jsonResponse({ ok: true, state: 'playing', position: 10, duration: 3600, volume: 80 });
      }
      if (url.startsWith('/api/cast/control')) {
        return jsonResponse({ ok: true });
      }
      throw new Error(`unexpected request: ${url}`);
    });

    renderPlayer();

    const castBtn = await screen.findByRole('button', { name: /cast to smart tv/i });
    expect(castBtn).toBeInTheDocument();
    fireEvent.click(castBtn);

    // CastModal is open
    expect(await screen.findByRole('dialog', { name: /cast to device/i })).toBeInTheDocument();
    const deviceItem = await screen.findByRole('button', { name: /living room tv/i });
    fireEvent.click(deviceItem);

    // CastBar is now active
    expect(await screen.findByRole('region', { name: /active cast remote controller/i })).toBeInTheDocument();
    expect(screen.getByText('Living Room TV')).toBeInTheDocument();

    const shell = document.getElementById('shell');
    expect(shell).toHaveStyle({ display: 'none' });
  });
});

describe('PlayerPage quality ladder & switching', () => {
  beforeEach(() => {
    Reflect.deleteProperty(HTMLMediaElement.prototype, 'duration');
    Reflect.deleteProperty(HTMLMediaElement.prototype, 'currentTime');
  });

  function qualityLadderPayload() {
    return {
      container: 'matroska',
      duration: 3600,
      direct_play: false,
      needs_transcode: true,
      is_transcode_ready: true,
      quality_ladder: [
        {
          label: '1080p',
          quality: '1080p',
          height: 1080,
          width: 1920,
          bitrate: 4500000,
          is_direct: false,
          is_ready: true,
          hls_url: '/hls/test/1080p/playlist.m3u8',
        },
        {
          label: '720p',
          quality: '720p',
          height: 720,
          width: 1280,
          bitrate: 2500000,
          is_direct: false,
          is_ready: false,
          hls_url: '/hls/test/720p/playlist.m3u8',
        },
      ],
    };
  }

  function setupLadderPlayer() {
    stubVideo({ duration: 3600, currentTime: 250 });
    fetchMock.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('/api/media-info/')) return jsonResponse(qualityLadderPayload());
      if (url.startsWith('/api/seek-preview-meta/')) {
        return jsonResponse({ duration: 3600, interval: 10, count: 360, base_url: '/seek-preview/test.mp4' });
      }
      if (url.startsWith('/api/subtitles/')) return jsonResponse({ tracks: [] });
      if (url.startsWith('/api/progress?')) return jsonResponse({ position: 250, duration: 3600 });
      if (url.includes('/api/transcode/start/')) {
        return jsonResponse({ ok: true, status: 'started' });
      }
      throw new Error(`unexpected request: ${url}`);
    });
    return renderPlayer();
  }

  it('renders #qualityBtn in controls and opens QualitySelectorModal with ladder options', async () => {
    setupLadderPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    const qualityBtn = document.getElementById('qualityBtn');
    expect(qualityBtn).toBeInTheDocument();
    expect(qualityBtn?.textContent).toContain('HD');

    // Click qualityBtn to open modal
    fireEvent.click(qualityBtn!);
    expect(await screen.findByRole('dialog', { name: /playback quality/i })).toBeInTheDocument();

    // Verify ladder items are rendered
    expect(screen.getByTestId('quality-opt-auto')).toBeInTheDocument();
    expect(screen.getByTestId('quality-opt-1080p')).toBeInTheDocument();
    expect(screen.getByTestId('quality-opt-720p')).toBeInTheDocument();
  });

  it('switches to ready quality tier, updates stream source, and preserves currentTime', async () => {
    setupLadderPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    const qualityBtn = document.getElementById('qualityBtn')!;
    fireEvent.click(qualityBtn);

    const opt1080p = await screen.findByTestId('quality-opt-1080p');
    fireEvent.click(opt1080p);

    // Modal closes
    await waitFor(() => {
      expect(screen.queryByRole('dialog', { name: /playback quality/i })).not.toBeInTheDocument();
    });

    // Badge updates to 1080P
    expect(qualityBtn.textContent).toContain('1080P');

    // Hls loads 1080p playlist
    await waitFor(() => {
      expect(mockLoadSource).toHaveBeenCalledWith(
        expect.stringContaining('/1080p/playlist.m3u8'),
      );
    });

    // Simulating metadata loaded restores seek position
    const video = document.querySelector('video') as HTMLVideoElement;
    fireEvent.loadedMetadata(video);
    expect(video.currentTime).toBe(250);
  });

  it('triggers on-demand transcode when selecting a non-ready quality tier', async () => {
    setupLadderPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    const qualityBtn = document.getElementById('qualityBtn')!;
    fireEvent.click(qualityBtn);

    const opt720p = await screen.findByTestId('quality-opt-720p');
    fireEvent.click(opt720p);

    // Should POST to start transcode for 720p
    await waitFor(() => {
      const calls = fetchMock.mock.calls.filter(
        (call) =>
          String(call[0]).includes('/api/transcode/start/') &&
          String(call[0]).includes('quality=720p'),
      );
      expect(calls.length).toBeGreaterThanOrEqual(1);
    });

    // Stream switches to 720p playlist
    await waitFor(() => {
      expect(mockLoadSource).toHaveBeenCalledWith(
        expect.stringContaining('/720p/playlist.m3u8'),
      );
    });
  });

  it('toggles Quality modal via keyboard shortcut q and dismisses with Escape', async () => {
    setupLadderPlayer();
    await waitFor(() => expect(screen.getByTestId('player')).toBeInTheDocument());

    expect(screen.queryByRole('dialog', { name: /playback quality/i })).not.toBeInTheDocument();

    // Open via 'q'
    fireEvent.keyDown(window, { key: 'q' });
    expect(await screen.findByRole('dialog', { name: /playback quality/i })).toBeInTheDocument();

    // Close via 'Escape'
    fireEvent.keyDown(window, { key: 'Escape' });
    await waitFor(() => {
      expect(screen.queryByRole('dialog', { name: /playback quality/i })).not.toBeInTheDocument();
    });
  });
});