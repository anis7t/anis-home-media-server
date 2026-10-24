import { render, screen, waitFor } from '@testing-library/react';
import { StrictMode } from 'react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import BrandIntroOverlay from './BrandIntroOverlay';
import { INTRO_SEEN_KEY } from '../../lib/intro/mode';
import { useIntroSequence } from '../../hooks/useIntroSequence';

/**
 * The brand opening sequence's lifecycle.
 *
 * Two things are load-bearing here and both are AGENTS.md invariants:
 *
 *  - **The container owns the session gate.** The overlay must never touch
 *    `sessionStorage`; it reports that it started, and the container records
 *    it.
 *  - **The gate is decided once, at mount.** Under `StrictMode` an
 *    effect-time read would see the flag the container had just written and
 *    decide never to play.
 */

/** A container that behaves like `AppShell` does: it owns the gate. */
function Host({ onStarted }: { onStarted?: () => void }) {
  const intro = useIntroSequence();
  return (
    <div>
      {intro.shouldMount ? (
        <BrandIntroOverlay
          mode={intro.mode}
          onStarted={() => {
            intro.onStarted();
            onStarted?.();
          }}
          onFinished={intro.onFinished}
        />
      ) : null}
      <p>page content</p>
    </div>
  );
}

const renderAt = (search: string, onStarted?: () => void) =>
  render(
    <MemoryRouter initialEntries={[`/${search}`]}>
      <Routes>
        <Route path="/" element={<Host onStarted={onStarted} />} />
      </Routes>
    </MemoryRouter>,
  );

beforeEach(() => {
  sessionStorage.clear();
  /*
   * jsdom has no 2D canvas backend, so `getContext('2d')` is not implemented
   * and logs a warning on every call. The component already guards for a null
   * context, so returning null is exactly the code path jsdom would take -
   * it just stops the noise.
   *
   * The stub is installed per test, not once: the global `afterEach` in
   * `src/test/setup.ts` restores every mock between tests.
   */
  vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue(null);
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('the intro modes', () => {
  it('mounts nothing in the off mode', () => {
    renderAt('?intro=off');
    expect(document.querySelector('.intro-stage')).toBeNull();
    expect(screen.queryByText('page content')).not.toBeNull();
  });

  it('mounts the overlay in the auto mode', () => {
    renderAt('?intro=auto');
    expect(document.querySelector('.intro-stage')).not.toBeNull();
  });

  it('shows the gate card in the gate mode, and does not start until it is pressed', async () => {
    renderAt('?intro=gate');
    expect(document.querySelector('.intro-gate')).not.toBeNull();
    expect(document.querySelector('.intro-stage')).not.toBeNull();

    // The play button starts it, and the card goes away.
    screen.getByRole('button', { name: /play/i }).click();
    await waitFor(() => expect(document.querySelector('.intro-gate')).toBeNull());
  });

  it('exposes the capture handle only in the capture mode', async () => {
    renderAt('?intro=auto');
    expect((window as unknown as Record<string, unknown>).__INTRO__).toBeUndefined();

    renderAt('?intro=capture');
    await waitFor(() =>
      expect((window as unknown as Record<string, unknown>).__INTRO__).toBeDefined(),
    );
    const api = (window as unknown as { __INTRO__: { renderAt: (t: number) => void; pageMode: () => string } }).__INTRO__;
    expect(api.pageMode()).toBe('capture');
    expect(() => api.renderAt(1)).not.toThrow();
  });
});

describe('the session gate', () => {
  it('is owned by the container, not the overlay', async () => {
    const started = vi.fn();

    renderAt('?intro=auto', started);

    await waitFor(() => expect(started).toHaveBeenCalled());
    // The container recorded it. (jsdom's Storage is a Proxy whose named
    // properties cannot be replaced, so the write cannot be intercepted and
    // counted here - the effect is asserted instead, and the ownership below
    // is asserted against the overlay's own source.)
    expect(sessionStorage.getItem(INTRO_SEEN_KEY)).toBe('1');
  });

  it('starts the sequence exactly once, even under StrictMode', async () => {
    const started = vi.fn();
    render(
      <StrictMode>
        <MemoryRouter initialEntries={['/?intro=auto']}>
          <Routes>
            <Route path="/" element={<Host onStarted={started} />} />
          </Routes>
        </MemoryRouter>
      </StrictMode>,
    );

    await waitFor(() => expect(started).toHaveBeenCalled());
    // React runs effects twice in development. The sequence must still start
    // once, and the intro must not decide it had already been seen because it
    // read the flag it had written itself.
    expect(started).toHaveBeenCalledTimes(1);
    expect(document.querySelector('.intro-stage')).not.toBeNull();
  });

  it('is never written by the overlay itself', () => {
    // The invariant, asserted against the source rather than against a
    // runtime spy: the component must not contain a sessionStorage reference
    // at all.
    const source = readOverlaySource();
    expect(source).not.toMatch(/sessionStorage/);
    expect(source).not.toMatch(/localStorage/);
  });

  it('does not replay once the intro has been seen', () => {
    sessionStorage.setItem(INTRO_SEEN_KEY, '1');
    renderAt('?intro=auto');
    expect(document.querySelector('.intro-stage')).toBeNull();
  });

  it('is not consumed by a capture run', async () => {
    const started = vi.fn();
    renderAt('?intro=capture', started);
    // A capture run never starts the sequence on its own...
    expect(started).not.toHaveBeenCalled();
    // ...and it must not mark the intro as seen for the user's session.
    expect(sessionStorage.getItem(INTRO_SEEN_KEY)).toBeNull();
  });

  it('plays again in a fresh session', () => {
    sessionStorage.clear();
    renderAt('?intro=auto');
    expect(document.querySelector('.intro-stage')).not.toBeNull();
  });
});

describe('dismissal', () => {
  it('dismisses on a click anywhere on the overlay', async () => {
    const finished = vi.fn();
    render(
      <MemoryRouter>
        <BrandIntroOverlay mode="auto" onFinished={finished} />
      </MemoryRouter>,
    );
    const stage = document.querySelector('.intro-stage') as HTMLElement;
    expect(stage).not.toBeNull();
    stage.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
    await waitFor(() => expect(finished).toHaveBeenCalled());
  });

  it('dismisses on any key', async () => {
    const finished = vi.fn();
    render(
      <MemoryRouter>
        <BrandIntroOverlay mode="auto" onFinished={finished} />
      </MemoryRouter>,
    );
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'a' }));
    await waitFor(() => expect(finished).toHaveBeenCalled());
  });
});

/**
 * The overlay's own source, read from disk.
 *
 * Reading the file is the only way to assert the AGENTS.md invariant
 * literally: "the overlay does not set `sessionStorage.setItem('introSeen')`
 * prior to the enclosing component's evaluation". A runtime spy would only
 * prove it for the paths a test happens to exercise.
 */
function readOverlaySource(): string {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const nodePath = 'node:fs';
  const nodePath2 = 'node:path';
  const fs = require(nodePath) as typeof import('node:fs');
  const path = require(nodePath2) as typeof import('node:path');
  const file = path.resolve(__dirname, 'BrandIntroOverlay.tsx');
  return fs.readFileSync(file, 'utf8');
}
