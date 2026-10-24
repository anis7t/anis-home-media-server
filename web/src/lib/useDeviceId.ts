/**
 * Stable per-browser device identifier.
 *
 * `/api/movies` and `/api/movie/{filename}` scope watch progress and presence
 * to the `X-Device-Id` header. The server treats an unknown device as a new
 * one, so the id must survive reloads or every page load would look like a
 * fresh device with zero progress.
 *
 * Deliberately localStorage, not a cookie: the API has no auth and no session
 * (see the roadmap's Phase 2 note), so there is no server-side identity to
 * read, and nothing here should pretend otherwise.
 */
import { useSyncExternalStore } from 'react';

const STORAGE_KEY = 'media-server.device-id';

function createId(): string {
  const random =
    typeof crypto !== 'undefined' && 'randomUUID' in crypto
      ? crypto.randomUUID()
      : Math.random().toString(36).slice(2);
  return `web_${random.replace(/-/g, '').slice(0, 16)}`;
}

function read(): string {
  if (typeof window === 'undefined') return 'web_server';
  try {
    const existing = window.localStorage.getItem(STORAGE_KEY);
    if (existing) return existing;
    const created = createId();
    window.localStorage.setItem(STORAGE_KEY, created);
    return created;
  } catch {
    // Private mode / storage disabled: fall back to an ephemeral id rather
    // than failing the render. Progress will not persist for this session,
    // which is a smaller harm than an unhandled exception.
    return createId();
  }
}

let cached: string | null = null;
const listeners = new Set<() => void>();

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function snapshot(): string {
  if (cached === null) cached = read();
  return cached;
}

export function useDeviceId(): string {
  return useSyncExternalStore(subscribe, snapshot, () => 'web_server');
}