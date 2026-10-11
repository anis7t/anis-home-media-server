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

async function getMediaInfoStub() {
  const { getMediaInfo } = await import('./client');
  return getMediaInfo('a.mkv');
}