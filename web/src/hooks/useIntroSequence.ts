import { useCallback, useMemo, useState } from 'react';
import { useLocation } from 'react-router';

import { INTRO_SEEN_KEY, parseIntroMode } from '../lib/intro/mode';
import type { IntroMode } from '../lib/intro/mode';

export interface UseIntroSequenceResult {
  /** The mode, parsed from `?intro=`. */
  mode: IntroMode;
  /** Whether the overlay should be in the tree at all. */
  shouldMount: boolean;
  /**
   * Called by the overlay when the sequence actually starts.
   *
   * This is how the session gate is written. The **container** owns the gate;
   * the overlay never touches `sessionStorage` itself.
   */
  onStarted: () => void;
  /** Called by the overlay when the sequence has finished. */
  onFinished: () => void;
}

const hasSeenIntro = (): boolean => {
  try {
    return typeof sessionStorage !== 'undefined' && !!sessionStorage.getItem(INTRO_SEEN_KEY);
  } catch {
    // A browser with storage disabled is not a reason to play the intro on
    // every single page load.
    return true;
  }
};

/**
 * Owns the brand opening sequence's lifecycle.
 *
 * This hook is the **container side** of the sequence, and it is deliberately
 * where the session gate lives: the overlay is told when the sequence starts,
 * and the container records it. The overlay has no `sessionStorage` reference
 * at all.
 *
 * ## The gate is decided once, during render
 *
 * The decision is made in a `useState` initialiser, not in an effect, and it
 * is **not** re-read afterwards. That matters under `StrictMode`, which runs
 * effects twice: an effect-time read would see the flag this component had
 * just written itself, decide that the intro had already been seen, and never
 * play it at all. Reading during render also means the decision cannot change
 * underneath a running sequence.
 *
 * ## Which modes the gate applies to
 *
 * - `auto` — the product behaviour. Plays once per browser session.
 * - `gate` — manual testing. Always shows the card, and records the intro as
 *   seen once it starts, so a manual view does not leave the intro pending.
 * - `capture` — verification. Always shows, and **does not** record the intro
 *   as seen: a capture run must not consume the user's session.
 * - `off` — nothing is mounted.
 */
export function useIntroSequence(): UseIntroSequenceResult {
  const location = useLocation();
  const mode = useMemo(() => parseIntroMode(location.search), [location.search]);

  // Decided once, at mount, and never re-read. See the note above.
  const [shouldPlay] = useState(() => {
    if (mode === 'off') return false;
    if (mode === 'gate' || mode === 'capture') return true;
    return !hasSeenIntro();
  });

  const [visible, setVisible] = useState(shouldPlay);

  const onStarted = useCallback(() => {
    if (mode === 'capture') return;
    try {
      if (typeof sessionStorage !== 'undefined') {
        sessionStorage.setItem(INTRO_SEEN_KEY, '1');
      }
    } catch {
      // Storage being unavailable must never break the sequence.
    }
  }, [mode]);

  const onFinished = useCallback(() => {
    setVisible(false);
  }, []);

  return {
    mode,
    shouldMount: visible,
    onStarted,
    onFinished,
  };
}
