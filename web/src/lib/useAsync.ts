import { useCallback, useEffect, useState } from 'react';

/**
 * Minimal async-data hook covering the three states the roadmap calls for:
 * loading, error, and empty. Deliberately not a data-fetching library - the
 * contract is two endpoints in this slice, and a cache/revalidation layer would
 * be scaffolding nothing here needs.
 */
export interface AsyncState<T> {
  readonly data: T | undefined;
  readonly error: Error | undefined;
  readonly loading: boolean;
  /**
   * Re-run the loader, keeping the same arguments.
   *
   * Exists because a failed load used to be terminal: the only recovery was a
   * full page reload, which discards scroll position and every other piece of
   * client state. A retry is one function call away for every caller, so a
   * timeout or a dropped connection is recoverable without a navigation.
   */
  readonly reload: () => void;
}

export function useAsync<T>(
  load: (signal: AbortSignal) => Promise<T>,
  deps: readonly unknown[],
): AsyncState<T> {
  const [state, setState] = useState<AsyncState<T>>({
    data: undefined,
    error: undefined,
    loading: true,
    reload: () => {},
  });

  /*
   * Bumping this re-runs the effect. It lives in the hook rather than in each
   * caller because the effect's dependency list is caller-owned, and a caller
   * cannot otherwise express "run this again" without inventing a dep that
   * changes on demand.
   */
  const [attempt, setAttempt] = useState(0);

  const reload = useCallback(() => setAttempt((n) => n + 1), []);

  useEffect(() => {
    const controller = new AbortController();
    let active = true;

    setState((prev) => ({ ...prev, data: undefined, error: undefined, loading: true }));

    load(controller.signal)
      .then((data) => {
        if (active) setState({ data, error: undefined, loading: false, reload });
      })
      .catch((error: unknown) => {
        // An abort is a deliberate teardown, not a failure to report.
        if (!active || controller.signal.aborted) return;
        setState({
          data: undefined,
          error: error instanceof Error ? error : new Error(String(error)),
          loading: false,
          reload,
        });
      });

    return () => {
      active = false;
      controller.abort();
    };
    // The caller owns the dependency list; `load` is re-created every render
    // and listing it would restart the effect on every render. `reload` is a
    // stable useCallback and `attempt` is this hook's own retry counter.
    // oxlint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, attempt]);

  return { ...state, reload };
}