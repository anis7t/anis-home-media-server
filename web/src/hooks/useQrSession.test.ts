import { act, renderHook, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { useQrSession } from './useQrSession';
import { createQrSession } from '../lib/api/account';

vi.mock('../lib/api/account', () => ({
  createQrSession: vi.fn(),
}));

const mockedCreate = vi.mocked(createQrSession);

function sessionFixture(overrides: Partial<Awaited<ReturnType<typeof createQrSession>>> = {}) {
  const now = Math.floor(Date.now() / 1000);
  return {
    qr_id: 'qr_test_1',
    code: 'K7R2P',
    sig: 'deadbeef',
    expires_at: now + 120,
    qr_url: 'https://media.anisparvez.in/remotelogin?qr_id=qr_test_1&code=K7R2P&sig=deadbeef',
    login_url: 'https://media.anisparvez.in/remotelogin',
    ...overrides,
  } as Awaited<ReturnType<typeof createQrSession>>;
}

/**
 * A controllable EventSource, so a test can drive the server-sent event
 * stream by hand. The global stub in `src/test/setup.ts` is inert on purpose.
 */
class FakeEventSource {
  static instances: FakeEventSource[] = [];

  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onopen: ((event: Event) => void) | null = null;
  readyState = 0;
  closed = false;
  readonly url: string;

  constructor(url: string) {
    this.url = url;
    FakeEventSource.instances.push(this);
  }

  addEventListener(): void {}
  removeEventListener(): void {}
  dispatchEvent(): boolean {
    return true;
  }
  close(): void {
    this.closed = true;
  }

  /** Deliver a server-sent event to the hook. */
  emit(data: string): void {
    this.onmessage?.({ data } as MessageEvent);
  }
}

let assignMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  FakeEventSource.instances = [];
  mockedCreate.mockReset();
  mockedCreate.mockResolvedValue(sessionFixture());

  vi.stubGlobal('EventSource', FakeEventSource);

  assignMock = vi.fn();
  Object.defineProperty(window, 'location', {
    configurable: true,
    writable: true,
    value: { ...window.location, assign: assignMock, search: '' },
  });
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe('useQrSession', () => {
  it('creates a pair session on mount and subscribes to the wait stream', async () => {
    const { result } = renderHook(() => useQrSession());

    await waitFor(() => expect(result.current.session?.qr_id).toBe('qr_test_1'));
    expect(mockedCreate).toHaveBeenCalledTimes(1);
    expect(result.current.loading).toBe(false);

    await waitFor(() => expect(FakeEventSource.instances).toHaveLength(1));
    expect(FakeEventSource.instances[0].url).toContain('/api/auth/qr/qr_test_1/wait');
  });

  it('derives the countdown from the server-issued expiry', async () => {
    mockedCreate.mockResolvedValue(sessionFixture({ expires_at: Math.floor(Date.now() / 1000) + 90 }));

    const { result } = renderHook(() => useQrSession());

    await waitFor(() => expect(result.current.session).not.toBeNull());
    expect(result.current.secondsLeft).toBeGreaterThan(80);
    expect(result.current.secondsLeft).toBeLessThanOrEqual(90);
  });

  it('finalizes the session when the stream reports it was confirmed', async () => {
    const { result } = renderHook(() => useQrSession());

    await waitFor(() => expect(FakeEventSource.instances).toHaveLength(1));

    act(() => {
      FakeEventSource.instances[0].emit('confirmed');
    });

    await waitFor(() => expect(result.current.confirmed).toBe(true));
    expect(assignMock).toHaveBeenCalledWith('/api/auth/qr/qr_test_1/finalize');
  });

  it('requests a fresh session when the stream reports expiry', async () => {
    renderHook(() => useQrSession());

    await waitFor(() => expect(FakeEventSource.instances).toHaveLength(1));

    act(() => {
      FakeEventSource.instances[0].emit('expired');
    });

    await waitFor(() => expect(mockedCreate).toHaveBeenCalledTimes(2));
  });

  it('requests exactly one replacement session when the countdown expires', async () => {
    /*
     * The regression this pins: the expiry check used to live inside a
     * `setSecondsLeft` updater, which React's StrictMode double-invokes in
     * development. Every expiry therefore created *two* pair sessions on the
     * server - one of them orphaned, expiring two minutes later.
     */
    vi.useFakeTimers({ shouldAdvanceTime: true });

    const { result } = renderHook(() => useQrSession());

    await waitFor(() => expect(result.current.session).not.toBeNull());
    expect(mockedCreate).toHaveBeenCalledTimes(1);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(121_000);
    });

    await waitFor(() => expect(mockedCreate).toHaveBeenCalledTimes(2));
    // And not a third: the refresh starts a new countdown, it does not
    // immediately re-trigger one.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1_000);
    });
    expect(mockedCreate).toHaveBeenCalledTimes(2);
  });

  it('closes the event stream on unmount', async () => {
    const { unmount } = renderHook(() => useQrSession());

    await waitFor(() => expect(FakeEventSource.instances).toHaveLength(1));
    const source = FakeEventSource.instances[0];

    unmount();
    expect(source.closed).toBe(true);
  });

  it('retries soon when the session cannot be created', async () => {
    mockedCreate.mockRejectedValueOnce(new Error('network down'));

    const { result } = renderHook(() => useQrSession());

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.secondsLeft).toBe(10);
    expect(result.current.session).toBeNull();
  });

  it('falls back to polling when the SSE connection errors', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ status: 'pending' }),
    });
    vi.stubGlobal('fetch', fetchMock);

    renderHook(() => useQrSession());

    await waitFor(() => expect(FakeEventSource.instances).toHaveLength(1));

    // Simulate SSE error
    act(() => {
      FakeEventSource.instances[0].onerror?.(new Event('error'));
    });

    // Advance 3s so the poll interval fires
    await act(async () => {
      fetchMock.mockResolvedValueOnce({
        ok: true,
        json: async () => ({ status: 'confirmed' }),
      });
      await vi.advanceTimersByTimeAsync(3000);
    });

    await waitFor(() =>
      expect(assignMock).toHaveBeenCalledWith('/api/auth/qr/qr_test_1/finalize'),
    );
  });

  it('freezes the countdown and does not refresh session once confirmed', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });

    const { result } = renderHook(() => useQrSession());

    await waitFor(() => expect(FakeEventSource.instances).toHaveLength(1));
    expect(mockedCreate).toHaveBeenCalledTimes(1);

    act(() => {
      FakeEventSource.instances[0].emit('confirmed');
    });

    await waitFor(() => expect(result.current.confirmed).toBe(true));

    // Advance by 150 seconds past the original 120s expiry
    await act(async () => {
      await vi.advanceTimersByTimeAsync(150_000);
    });

    // Should NOT have requested a replacement session because the session was confirmed
    expect(mockedCreate).toHaveBeenCalledTimes(1);
  });
});

