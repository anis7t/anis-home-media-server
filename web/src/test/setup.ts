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