import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { getProgress, setProgress } from './client';

let fetchMock: ReturnType<typeof vi.fn>;

function jsonResponse(body: unknown, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: 'OK',
    json: async () => body,
  } as Response;
}

beforeEach(() => {
  fetchMock = vi.fn().mockResolvedValue(jsonResponse({}));
  vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

/** Headers actually sent on the most recent fetch call. */
function lastHeaders(): Record<string, string> {
  const [, options] = fetchMock.mock.calls[fetchMock.mock.calls.length - 1];
  return (options?.headers ?? {}) as Record<string, string>;
}

describe('progress scoping', () => {
  it('sends X-Device-Id when persisting progress', () => {
    /*
     * Regression: the write omitted the device header while the read sent it.
     * The write landed only in the shared `progress` table and the resume
     * lookup read `device_watch_history` for the calling device, so a browser
     * could save a position it could never read back. Verified against the
     * live server: the device-scoped read returned position 0 while the
     * position was being written.
     */
    void setProgress(
      { filename: 'a.mkv', position: 30, duration: 100 },
      { deviceId: 'web_abc123' },
    );

    expect(lastHeaders()['X-Device-Id']).toBe('web_abc123');
  });

  it('sends the same device header on the resume read', () => {
    void getProgress('a.mkv', { deviceId: 'web_abc123' });
    expect(lastHeaders()['X-Device-Id']).toBe('web_abc123');
  });

  it('omits the header when no device is supplied rather than sending undefined', () => {
    void setProgress({ filename: 'a.mkv', position: 30, duration: 100 });
    expect('X-Device-Id' in lastHeaders()).toBe(false);
  });

  it('passes the filename as a query parameter on the read', () => {
    void getProgress('sub dir/a b.mkv', { deviceId: 'web_abc123' });
    const [url] = fetchMock.mock.calls[0];
    expect(String(url)).toBe('/api/progress?filename=sub+dir%2Fa+b.mkv');
  });
});

describe('client error handling', () => {
  it('rejects with the HTTP status rather than returning an empty payload', async () => {
    fetchMock.mockResolvedValueOnce({
      ok: false,
      status: 404,
      statusText: 'NOT FOUND',
      json: async () => ({}),
    } as Response);

    await expect(getMediaInfoStub()).rejects.toMatchObject({ status: 404 });
  });

  it('does not surface an unhandled rejection from a failed progress write', async () => {
    fetchMock.mockRejectedValueOnce(new Error('network down'));

    // Best-effort by contract: the caller is responsible for swallowing this,
    // and the player does. This asserts the rejection is observable, so the
    // caller's `.catch` is doing real work rather than hiding a bug.
    await expect(
      setProgress({ filename: 'a.mkv', position: 1, duration: 2 }, { deviceId: 'd' }),
    ).rejects.toThrow('network down');
  });
});

describe('request deadline', () => {
  /*
   * Motivation, measured against this server rather than assumed: a cold
   * `/api/movie/{filename}` for an unseen title costs 2.5-8s (the route probes
   * the file server-side), and one request was observed exceeding 30s outright.
   * With no deadline, any of those presents identically to a hung socket - an
   * indefinite skeleton with no error and no recovery short of a page reload.
   */

  /**
   * A hung socket that behaves like a real one: never resolves on its own, and
   * rejects with `AbortError` when the request is aborted. A mock that simply
   * never settles would leave `await fetch(...)` pending after the abort and
   * make every deadline test hang instead of failing - which is the one outcome
   * that cannot distinguish a working timeout from a broken one.
   */
  function hungFetch() {
    fetchMock.mockImplementation((_url: string, init: RequestInit) => {
      const signal = init.signal as AbortSignal;
      return new Promise((_resolve, reject) => {
        if (signal.aborted) {
          reject(new DOMException('Aborted', 'AbortError'));
          return;
        }
        signal.addEventListener('abort', () =>
          reject(new DOMException('Aborted', 'AbortError')),
        );
      });
    });
  }

  it('rejects with ApiTimeoutError when the response never arrives', async () => {
    vi.useFakeTimers();
    try {
      hungFetch();

      const { getProgress } = await import('./client');
      const pending = getProgress('a.mkv').catch((e: unknown) => e);

      await vi.advanceTimersByTimeAsync(20_000);
      const error = await pending;

      expect(error).toMatchObject({ name: 'ApiTimeoutError', timeoutMs: 20_000 });
      expect((error as Error).message).toContain('20s');
    } finally {
      vi.useRealTimers();
    }
  });

  it('does not fire once the response has arrived', async () => {
    vi.useFakeTimers();
    try {
      fetchMock.mockResolvedValue(jsonResponse({ position: 42 }));

      const { getProgress } = await import('./client');
      const pending = getProgress('a.mkv');

      // Well past the deadline: a resolved request must not be retroactively
      // turned into a timeout, which would discard a good response.
      await vi.advanceTimersByTimeAsync(60_000);
      await expect(pending).resolves.toMatchObject({ position: 42 });
    } finally {
      vi.useRealTimers();
    }
  });

  it('honours a caller-supplied deadline', async () => {
    vi.useFakeTimers();
    try {
      hungFetch();

      const { getMediaInfo } = await import('./client');
      const pending = getMediaInfo('a.mkv', { timeoutMs: 5_000 }).catch((e: unknown) => e);

      await vi.advanceTimersByTimeAsync(5_000);
      expect(await pending).toMatchObject({ timeoutMs: 5_000 });
    } finally {
      vi.useRealTimers();
    }
  });

  it('gives media-probing endpoints a longer deadline than the catalog', async () => {
    /*
     * `/api/movie/` and `/api/media-info/` probe the file server-side, so
     * timing them out on the 20s default would fail the slowest titles
     * deterministically rather than by accident.
     */
    const client = await import('./client');
    expect(client.MEDIA_PROBE_TIMEOUT_MS).toBeGreaterThan(20_000);
  });

  it('aborts the underlying fetch when the deadline fires', async () => {
    vi.useFakeTimers();
    try {
      let capturedSignal: AbortSignal | undefined;
      fetchMock.mockImplementation((_url: string, init: RequestInit) => {
        capturedSignal = init.signal as AbortSignal;
        return new Promise(() => {});
      });

      const { getProgress } = await import('./client');
      void getProgress('a.mkv').catch(() => {});
      await vi.advanceTimersByTimeAsync(20_000);

      // The socket must actually be released, not merely abandoned: without
      // this the connection stays open and the server keeps working for a
      // request nobody will read.
      expect(capturedSignal?.aborted).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });

  it('still surfaces a caller abort as an abort, not as a timeout', async () => {
    /*
     * `useAsync` aborts on unmount and route change. If a caller abort were
     * reported as a timeout, every navigation away from a slow page would
     * render a spurious "server took too long" error on the way out.
     */
    const controller = new AbortController();
    fetchMock.mockImplementation((_url: string, init: RequestInit) => {
      const signal = init.signal as AbortSignal;
      return new Promise((_resolve, reject) => {
        signal.addEventListener('abort', () =>
          reject(new DOMException('Aborted', 'AbortError')),
        );
      });
    });

    const { getProgress } = await import('./client');
    const pending = getProgress('a.mkv', { signal: controller.signal }).catch(
      (e: unknown) => e,
    );
    controller.abort();

    const error = await pending;
    expect((error as Error).name).toBe('AbortError');
  });
});

async function getMediaInfoStub() {
  const { getMediaInfo } = await import('./client');
  return getMediaInfo('a.mkv');
}