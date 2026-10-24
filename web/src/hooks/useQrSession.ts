import { useCallback, useEffect, useRef, useState } from 'react';
import { createQrSession, type QrSession } from '../lib/api/account';

interface UseQrSessionResult {
  session: QrSession | null;
  /** Seconds until the current session expires and refreshes */
  secondsLeft: number;
  /** True while the first session is being fetched */
  loading: boolean;
  /** Whether the pair was confirmed on the phone side */
  confirmed: boolean;
  /** Manually trigger a new session (happens automatically on expiry) */
  refresh: () => void;
}

/**
 * Manages the lifecycle of a QR pair session on the TV/browser side:
 * - Fetches a new session from the server on mount
 * - Counts down to the 2-minute expiry and auto-refreshes
 * - Subscribes to the SSE wait stream and signals `confirmed` when the phone pairs
 *
 * The hook cleans up the SSE EventSource and countdown timer on unmount or session refresh.
 */
export function useQrSession(): UseQrSessionResult {
  const [session, setSession] = useState<QrSession | null>(null);
  const [secondsLeft, setSecondsLeft] = useState(120);
  const [loading, setLoading] = useState(true);
  const [confirmed, setConfirmed] = useState(false);

  const esRef = useRef<EventSource | null>(null);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const pollTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const confirmedRef = useRef(false);
  /**
   * Mirror of `secondsLeft`.
   *
   * The countdown interval reads this to decide when the session has
   * expired. The previous implementation did the expiry check *inside* a
   * `setSecondsLeft` updater and called `fetchSession()` from there. A
   * state updater must be pure, and React's StrictMode deliberately
   * double-invokes updaters in development - so every expiry created two
   * pair sessions on the server instead of one.
   */
  const secondsLeftRef = useRef(secondsLeft);

  const cleanup = useCallback(() => {
    if (esRef.current) {
      esRef.current.close();
      esRef.current = null;
    }
    if (timerRef.current !== null) {
      clearInterval(timerRef.current);
      timerRef.current = null;
    }
    if (pollTimerRef.current !== null) {
      clearInterval(pollTimerRef.current);
      pollTimerRef.current = null;
    }
  }, []);

  const handleConfirmed = useCallback(
    (qrId: string) => {
      if (confirmedRef.current) return;
      confirmedRef.current = true;
      setConfirmed(true);
      cleanup();
      // Navigate to finalize — sets session cookie and redirects to /
      window.location.assign(
        `/api/auth/qr/${encodeURIComponent(qrId)}/finalize`,
      );
    },
    [cleanup],
  );

  const fetchSession = useCallback(async () => {
    if (confirmedRef.current) return;
    cleanup();
    setConfirmed(false);
    confirmedRef.current = false;
    try {
      const data = await createQrSession();
      if (confirmedRef.current) return;
      setSession(data);
      // Calculate actual seconds left based on server-issued expires_at
      const secs = Math.max(0, data.expires_at - Math.floor(Date.now() / 1000));
      secondsLeftRef.current = secs;
      setSecondsLeft(secs);
    } catch {
      // Silently retry — the TV page will show old QR until next refresh
      if (!confirmedRef.current) {
        secondsLeftRef.current = 10; // retry sooner
        setSecondsLeft(10);
      }
    } finally {
      setLoading(false);
    }
  }, [cleanup]);

  // Countdown timer — auto-refreshes when it hits 0
  const startCountdown = useCallback(
    (initialSecs: number) => {
      if (confirmedRef.current) return;
      if (timerRef.current !== null) clearInterval(timerRef.current);
      secondsLeftRef.current = initialSecs;
      setSecondsLeft(initialSecs);

      timerRef.current = setInterval(() => {
        if (confirmedRef.current) {
          if (timerRef.current !== null) {
            clearInterval(timerRef.current);
            timerRef.current = null;
          }
          return;
        }
        const next = Math.max(0, secondsLeftRef.current - 1);
        secondsLeftRef.current = next;
        setSecondsLeft(next);

        // The expiry check lives here, in the interval callback, not inside a
        // state updater. An interval callback is an ordinary effect callback
        // and may have side effects; an updater may not.
        if (next === 0) {
          if (timerRef.current !== null) {
            clearInterval(timerRef.current);
            timerRef.current = null;
          }
          // Refresh the session; fetchSession will restart the countdown
          if (!confirmedRef.current) {
            void fetchSession();
          }
        }
      }, 1000);
    },
    [fetchSession],
  );

  // When a new session is issued, start the SSE listener and countdown
  useEffect(() => {
    if (!session || confirmedRef.current) return;

    // SSE wait stream
    const es = new EventSource(`/api/auth/qr/${encodeURIComponent(session.qr_id)}/wait`);
    esRef.current = es;

    const startPollingFallback = () => {
      if (pollTimerRef.current !== null || confirmedRef.current) return;
      pollTimerRef.current = setInterval(async () => {
        if (confirmedRef.current) {
          if (pollTimerRef.current !== null) {
            clearInterval(pollTimerRef.current);
            pollTimerRef.current = null;
          }
          return;
        }
        try {
          const res = await fetch(`/api/auth/qr/${encodeURIComponent(session.qr_id)}/status`);
          if (!res.ok) return;
          const json = (await res.json()) as { status: string };
          if (json.status === 'confirmed') {
            handleConfirmed(session.qr_id);
          } else if (json.status === 'expired') {
            cleanup();
            void fetchSession();
          }
        } catch {
          // ignore transient network/proxy error during poll
        }
      }, 3000);
    };

    es.onmessage = (e) => {
      const data = (e.data as string).trim();
      if (data === 'confirmed') {
        handleConfirmed(session.qr_id);
      } else if (data === 'expired') {
        void fetchSession();
      }
      // 'pending' — no action, countdown continues
    };

    es.onerror = () => {
      // SSE dropped — fall back to active status polling every 3 seconds
      if (esRef.current) {
        esRef.current.close();
        esRef.current = null;
      }
      startPollingFallback();
    };

    const secs = Math.max(5, session.expires_at - Math.floor(Date.now() / 1000));
    startCountdown(secs);

    return cleanup;
  }, [session, cleanup, fetchSession, handleConfirmed, startCountdown]);

  // Initial fetch
  useEffect(() => {
    void fetchSession();
    return cleanup;
  }, [fetchSession, cleanup]);

  return {
    session,
    secondsLeft,
    loading,
    confirmed,
    refresh: () => void fetchSession(),
  };
}
