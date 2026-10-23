import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';

import {
  AUTH_LOCKED_EVENT,
  notifyAuthLocked,
} from '../../auth/AuthProvider';
import { fetchMe, loginWithPin } from './account';

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

describe('account client', () => {
  it('reports an unauthenticated caller without throwing', async () => {
    fetchMock.mockResolvedValue(jsonResponse({ authenticated: false }));
    await expect(fetchMe()).resolves.toEqual({ authenticated: false });
  });

  it('always sends same-origin credentials', async () => {
    fetchMock.mockResolvedValue(jsonResponse({ authenticated: false }));
    await fetchMe();
    expect(fetchMock.mock.calls[0][1]).toMatchObject({ credentials: 'same-origin' });
  });

  it('announces a 401 so the app can lock rather than each screen rediscovering it', async () => {
    fetchMock.mockResolvedValue(jsonResponse({ error: 'nope' }, 401));
    const seen = vi.fn();
    window.addEventListener(AUTH_LOCKED_EVENT, seen);

    await expect(fetchMe()).rejects.toThrow();
    expect(seen).toHaveBeenCalledTimes(1);

    window.removeEventListener(AUTH_LOCKED_EVENT, seen);
  });

  it('does not announce non-401 failures', async () => {
    fetchMock.mockResolvedValue(jsonResponse({ error: 'boom' }, 500));
    const seen = vi.fn();
    window.addEventListener(AUTH_LOCKED_EVENT, seen);

    await expect(fetchMe()).rejects.toThrow();
    expect(seen).not.toHaveBeenCalled();

    window.removeEventListener(AUTH_LOCKED_EVENT, seen);
  });

  it('carries the status on the thrown error', async () => {
    fetchMock.mockResolvedValue(jsonResponse({ error: 'nope' }, 403));
    await expect(fetchMe()).rejects.toMatchObject({ status: 403 });
  });

  it('sends a JSON content type only when there is a body', async () => {
    fetchMock.mockResolvedValue(jsonResponse({ authenticated: false }));
    await fetchMe();
    expect(fetchMock.mock.calls[0][1].headers).toBeUndefined();

    fetchMock.mockResolvedValue(jsonResponse({ success: true }));
    await loginWithPin('97531');
    expect(fetchMock.mock.calls[1][1].headers).toEqual({ 'Content-Type': 'application/json' });
    expect(fetchMock.mock.calls[1][1].method).toBe('POST');
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({ pin: '97531' });
  });
});

describe('notifyAuthLocked', () => {
  it('dispatches the lock event', () => {
    const seen = vi.fn();
    window.addEventListener(AUTH_LOCKED_EVENT, seen);
    notifyAuthLocked();
    expect(seen).toHaveBeenCalledTimes(1);
    window.removeEventListener(AUTH_LOCKED_EVENT, seen);
  });
});