/**
 * Typed API client for the Media Server.
 *
 * Gate B: request and response shapes come from `docs/openapi.yaml` via the
 * generated `schema.ts`. Gate D: this module contains no `any` - the typed
 * client's boundary is the one place where it would silently defeat the
 * purpose of the contract, so it is enforced by review and by `tsc --noEmit`.
 *
 * Base URL is intentionally relative. In development Vite proxies `/api`,
 * `/media` and `/hls` to the Flask origin, so the browser sees a single
 * same-origin server. That is what lets us honour Gate F: no CORS header is
 * added to `/api/*` anywhere, and `routes/media.py` `CORS_PATHS` stays exactly
 * as it is (`/media/`, `/hls/` only, for the benefit of Cast receivers).
 */
import { notifyAuthLocked } from '../../auth/authEvents';
import type {
  MovieDetailsResponseLive,
  MovieListResponseLive,
} from './spec-drift';
import type {
  MediaInfoResponse,
  TranscodeStatusResponse,
} from './types';

export class ApiError extends Error {
  readonly status: number;
  readonly url: string;

  constructor(message: string, status: number, url: string) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.url = url;
  }
}

/**
 * A request that exceeded its deadline.
 *
 * Distinct from `ApiError` on purpose. A hung request and a rejected one are
 * different user-facing situations: one is worth retrying, the other usually
 * is not, and the UI cannot tell them apart from `name` alone once both have
 * been flattened to a message.
 */
export class ApiTimeoutError extends Error {
  readonly timeoutMs: number;
  readonly url: string;

  constructor(timeoutMs: number, url: string) {
    super(`The server did not respond within ${Math.round(timeoutMs / 1000)}s.`);
    this.name = 'ApiTimeoutError';
    this.timeoutMs = timeoutMs;
    this.url = url;
  }
}

/**
 * Default deadline for a single API call.
 *
 * Not arbitrary. Measured against this server, a cold `/api/movie/{filename}`
 * for an unseen title costs 2.5-8s because the details route probes the file
 * server-side, and ten simultaneous cold details requests (what a library grid
 * does) finish in ~3.5s wall. 20s is comfortably above the observed cold path
 * while still converting an indefinite hang into a visible, retryable failure.
 *
 * Without this, a hung fetch is indistinguishable from a slow one: the caller
 * waits forever on a skeleton with no error and no way to recover short of a
 * full page reload.
 */
const DEFAULT_TIMEOUT_MS = 20_000;

/**
 * Longer deadline for the two endpoints that probe media server-side and so
 * can legitimately take seconds on a cold cache.
 */
export const MEDIA_PROBE_TIMEOUT_MS = 45_000;

/** Header the server uses to scope watch progress and presence per device. */
const DEVICE_HEADER = 'X-Device-Id';

export interface RequestOptions {
  readonly signal?: AbortSignal;
  readonly deviceId?: string;
  readonly method?: 'GET' | 'POST';
  readonly body?: unknown;
  readonly timeoutMs?: number;
}

export async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const {
    signal,
    deviceId,
    method = 'GET',
    body,
    timeoutMs = DEFAULT_TIMEOUT_MS,
  } = options;

  const headers: Record<string, string> = {};
  if (deviceId) headers[DEVICE_HEADER] = deviceId;
  if (body !== undefined) headers['Content-Type'] = 'application/json';

  /*
   * One controller for both reasons to stop: the caller's cancellation (a route
   * change, an unmount) and our own deadline. Wired by hand rather than with
   * `AbortSignal.any()` so there is no polyfill to carry, and so a timeout is
   * distinguishable from a caller abort afterwards.
   */
  const controller = new AbortController();
  let timedOut = false;
  const forwardAbort = () => controller.abort(signal?.reason);

  if (signal?.aborted) {
    controller.abort(signal.reason);
  } else {
    signal?.addEventListener('abort', forwardAbort, { once: true });
  }

  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);

  let response: Response;
  try {
    response = await fetch(path, {
      method,
      headers,
      signal: controller.signal,
      ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    });
  } catch (error) {
    // Checked before rethrowing so a deadline reads as a timeout rather than as
    // the opaque "The operation was aborted" the platform would otherwise give.
    if (timedOut) throw new ApiTimeoutError(timeoutMs, path);
    throw error;
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', forwardAbort);
  }

  if (!response.ok) {
    // Non-2xx is a real failure, not an empty payload: surface the status so
    // callers can distinguish "not found" from "transcode still building".
    //
    // A 401 additionally means this client can do nothing until someone signs
    // in, so it is announced to the app rather than left for each screen to
    // rediscover as its own error.
    if (response.status === 401) {
      // A 401 additionally means this client can do nothing until someone signs
      // in, so it is announced to the app rather than left for each screen to
      // rediscover as its own error.
      notifyAuthLocked();
    }
    throw new ApiError(
      `Request failed: ${response.status} ${response.statusText}`,
      response.status,
      path,
    );
  }

  return (await response.json()) as T;
}

/**
 * Percent-encode each path segment separately. `encodeURIComponent` on the whole
 * path would escape the separators and turn `sub/dir/file.mkv` into a single
 * filename segment, which the server's `<path:filename>` routes would reject.
 */
export function encodePathSegments(value: string): string {
  return value.split('/').map(encodeURIComponent).join('/');
}

/**
 * `MovieListResponse` as the server actually sends it: the catalog entries
 * carry the extra fields documented in `spec-drift.ts`. The generated shape is
 * still the starting point - this only widens it.
 */
export function listMovies(options: { signal?: AbortSignal; deviceId?: string } = {}) {
  return request<MovieListResponseLive>('/api/movies', options);
}

/**
 * Details for one title.
 *
 * Given the probing deadline: this route stats and probes the file server-side,
 * so a cold title costs seconds where `/api/movies` costs milliseconds. Timing
 * it out on the default budget would fail the slowest titles deterministically.
 */
export function getMovieDetails(
  filename: string,
  options: {
    signal?: AbortSignal;
    deviceId?: string;
    timeoutMs?: number;
  } = {},
) {
  return request<MovieDetailsResponseLive>(
    `/api/movie/${encodePathSegments(filename)}`,
    { timeoutMs: MEDIA_PROBE_TIMEOUT_MS, ...options },
  );
}

export function getMediaInfo(
  filename: string,
  options: { signal?: AbortSignal; timeoutMs?: number } = {},
) {
  return request<MediaInfoResponse>(`/api/media-info/${encodePathSegments(filename)}`, {
    timeoutMs: MEDIA_PROBE_TIMEOUT_MS,
    ...options,
  });
}

export function getTranscodeStatus(
  filename: string,
  options: { signal?: AbortSignal; timeoutMs?: number } = {},
) {
  return request<TranscodeStatusResponse>(
    `/api/transcode-status/${encodePathSegments(filename)}`,
    { timeoutMs: MEDIA_PROBE_TIMEOUT_MS, ...options },
  );
}

/**
 * Persist a resume point.
 *
 * The device id MUST be sent. `GET /api/progress` resolves the position from
 * `device_watch_history` for the calling device, so a write without
 * `X-Device-Id` lands only in the shared `progress` table while the next
 * resume lookup reads the device-scoped row and finds nothing. Write and read
 * have to be scoped identically, or resume silently never works.
 */
export function setProgress(
  payload: { filename: string; position: number; duration: number },
  options: { signal?: AbortSignal; deviceId?: string } = {},
) {
  return request<unknown>('/api/progress', { ...options, method: 'POST', body: payload });
}

/**
 * Read the saved resume point. Scoped by `X-Device-Id`, so it must be called
 * with the same device id that wrote it.
 */
export function getProgress(
  filename: string,
  options: { signal?: AbortSignal; deviceId?: string } = {},
) {
  const query = new URLSearchParams({ filename });
  return request<{ position: number; duration: number }>(`/api/progress?${query}`, options);
}