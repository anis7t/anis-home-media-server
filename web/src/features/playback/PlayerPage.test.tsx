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
vi.mock('hls.js', () => {
  class MockHls {
    static isSupported(): boolean {
      return true;
    }
    static Events = { ERROR: 'hlsError' };
    static ErrorTypes = { NETWORK_ERROR: 'networkError', MEDIA_ERROR: 'mediaError' };
    loadSource = vi.fn();
    attachMedia = vi.fn();
    on = vi.fn();
    startLoad = vi.fn();
    recoverMediaError = vi.fn();
    destroy = vi.fn();
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