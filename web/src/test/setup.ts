import '@testing-library/jest-dom/vitest';
import { cleanup } from '@testing-library/react';
import { afterEach, vi } from 'vitest';

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

/*
 * jsdom implements neither of these, and both are load-bearing for the player:
 *  - `HTMLMediaElement.play()` rejects unless called from a user gesture, which
 *    jsdom enforces, and is not implemented at all without this stub;
 *  - a <video> has no duration and reports readyState HAVE_NOTHING, so the
 *    resume and seek logic can never be exercised.
 */
Object.defineProperty(HTMLMediaElement.prototype, 'play', {
  configurable: true,
  value: vi.fn().mockResolvedValue(undefined),
});

Object.defineProperty(HTMLMediaElement.prototype, 'pause', {
  configurable: true,
  value: vi.fn(),
});

/*
 * jsdom implements neither `load()` nor a real duration/currentTime model. The
 * player calls `load()` on teardown to stop outstanding network activity, which
 * is correct in production; stubbed here so it does not log "Not implemented".
 */
Object.defineProperty(HTMLMediaElement.prototype, 'load', {
  configurable: true,
  value: vi.fn(),
});

/*
 * jsdom does not implement window.scrollTo(). Stubbed here so route scroll
 * resets do not produce "Not implemented: Window's scrollTo() method" warnings.
 */
Object.defineProperty(window, 'scrollTo', {
  configurable: true,
  value: vi.fn(),
});

/*
 * jsdom implements neither the `EventSource` constructor nor its event API.
 *
 * The QR device sign-in panel subscribes to the server's SSE stream, so
 * without this stub every test that renders the account page throws
 * `ReferenceError: EventSource is not defined` from inside an effect. React
 * treats an error thrown in an effect as fatal for that subtree, which tears
 * the whole page down - so a missing `EventSource` did not fail one
 * assertion, it failed every assertion in the file.
 *
 * The stub exposes the surface the hook actually uses, so the hook's real
 * code path runs rather than being skipped.
 */
class MockEventSource {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSED = 2;

  readonly url: string;
  readonly withCredentials = false;
  readyState: number = MockEventSource.CONNECTING;

  onopen: ((event: Event) => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;

  constructor(url: string | URL) {
    this.url = String(url);
  }

  addEventListener(): void {}
  removeEventListener(): void {}
  dispatchEvent(): boolean {
    return true;
  }

  close(): void {
    this.readyState = MockEventSource.CLOSED;
  }
}

Object.defineProperty(globalThis, 'EventSource', {
  configurable: true,
  writable: true,
  value: MockEventSource,
});