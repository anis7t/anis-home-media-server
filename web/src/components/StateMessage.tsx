import type { ReactNode } from 'react';

import { ApiTimeoutError } from '../lib/api/client';

/**
 * Shared loading / error / empty presentation.
 *
 * Lives apart from `useAsync` so that file exports only a hook: a module that
 * exports both a component and a hook defeats React Fast Refresh, which forces
 * a full reload on every edit while developing.
 */
export function StateMessage({
  loading,
  error,
  empty,
  emptyText,
  loadingText = 'Loading library…',
  onRetry,
  children,
}: {
  readonly loading: boolean;
  readonly error: Error | undefined;
  readonly empty: boolean;
  readonly emptyText: string;
  readonly loadingText?: string;
  /**
   * Re-runs the failed load. Omit it and the error is terminal, which is only
   * honest where nothing can be retried; a network or timeout failure is
   * recoverable and should not cost the viewer the page.
   */
  readonly onRetry?: () => void;
  readonly children: ReactNode;
}) {
  if (loading) {
    return (
      <div className="py-12 sm:py-16 space-y-8 animate-fade-in" role="status">
        {/* Modern glowing orbital spinner */}
        <div className="flex flex-col items-center justify-center text-center">
          <div className="relative mb-4 flex items-center justify-center">
            <div className="absolute h-14 w-14 rounded-full bg-brand-500/20 blur-lg animate-pulse" />
            <div className="h-10 w-10 rounded-full border-2 border-white/10 border-t-brand-500 animate-spin" />
            <div className="absolute h-3.5 w-3.5 rounded-full bg-brand-500/90 blur-xs" />
          </div>
          <p className="text-sm font-semibold tracking-wide text-white/80 animate-pulse">
            {loadingText}
          </p>
          <p className="mt-1 text-xs text-white/40">
            Fetching catalog and synchronization status
          </p>
        </div>

        {/* Shimmer skeleton grid representing loading items */}
        <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 opacity-40">
          {[1, 2, 3, 4, 5, 6].map((i) => (
            <div key={i} className="space-y-2">
              <div className="aspect-2/3 w-full rounded-2xl border border-white/5 bg-obsidian-900/60 shimmer" />
              <div className="h-3 w-3/4 rounded bg-white/10 shimmer" />
              <div className="h-2.5 w-1/2 rounded bg-white/5 shimmer" />
            </div>
          ))}
        </div>
      </div>
    );
  }

  if (error) {
    // A timeout is the one failure whose cause is unknown but whose remedy is
    // obvious, so it gets its own heading. Telling someone the server is
    // unreachable when it answered a request 30s later is simply wrong.
    const isTimeout = error instanceof ApiTimeoutError || error.name === 'ApiTimeoutError';

    return (
      <div
        className="rounded-xl border border-brand-500/40 bg-brand-500/10 p-6 text-center"
        role="alert"
      >
        <p className="text-sm font-semibold text-brand-400">
          {isTimeout ? 'The server took too long to respond' : 'Could not reach the media server'}
        </p>
        <p className="mt-1 text-xs text-white/60">{error.message}</p>
        {onRetry && (
          <button
            type="button"
            onClick={onRetry}
            className="mt-4 rounded-lg bg-brand-500 px-4 py-2 text-xs font-semibold text-white transition hover:bg-brand-400 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-white"
          >
            Try again
          </button>
        )}
      </div>
    );
  }

  if (empty) {
    return (
      <p className="py-16 text-center text-sm text-white/50" role="status">
        {emptyText}
      </p>
    );
  }

  return <>{children}</>;
}

export default StateMessage;