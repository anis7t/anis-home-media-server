import type { ReactNode } from 'react';

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
  children,
}: {
  readonly loading: boolean;
  readonly error: Error | undefined;
  readonly empty: boolean;
  readonly emptyText: string;
  readonly children: ReactNode;
}) {
  if (loading) {
    return (
      <p className="py-16 text-center text-sm text-white/50" role="status">
        Loading library…
      </p>
    );
  }

  if (error) {
    return (
      <div
        className="rounded-xl border border-brand-500/40 bg-brand-500/10 p-6 text-center"
        role="alert"
      >
        <p className="text-sm font-semibold text-brand-400">Could not reach the media server</p>
        <p className="mt-1 text-xs text-white/60">{error.message}</p>
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