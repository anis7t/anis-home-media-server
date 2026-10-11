import { useEffect, useState } from 'react';

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
}

export function useAsync<T>(
  load: (signal: AbortSignal) => Promise<T>,
  deps: readonly unknown[],
): AsyncState<T> {
  const [state, setState] = useState<AsyncState<T>>({
    data: undefined,
    error: undefined,
    loading: true,
  });

  useEffect(() => {
    const controller = new AbortController();
    let active = true;

    setState({ data: undefined, error: undefined, loading: true });

    load(controller.signal)
      .then((data) => {
        if (active) setState({ data, error: undefined, loading: false });
      })
      .catch((error: unknown) => {
        // An abort is a deliberate teardown, not a failure to report.
        if (!active || controller.signal.aborted) return;
        setState({
          data: undefined,
          error: error instanceof Error ? error : new Error(String(error)),
          loading: false,
        });
      });

    return () => {
      active = false;
      controller.abort();
    };
    // The caller owns the dependency list; `load` is re-created every render
    // and listing it would restart the effect on every render.
    // oxlint-disable-next-line react-hooks/exhaustive-deps
  }, deps);

  return state;
}