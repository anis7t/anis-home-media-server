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

/** Header the server uses to scope watch progress and presence per device. */
const DEVICE_HEADER = 'X-Device-Id';

interface RequestOptions {
  readonly signal?: AbortSignal;
  readonly deviceId?: string;
  readonly method?: 'GET' | 'POST';
  readonly body?: unknown;
}

async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const { signal, deviceId, method = 'GET', body } = options;

  const headers: Record<string, string> = {};
  if (deviceId) headers[DEVICE_HEADER] = deviceId;
  if (body !== undefined) headers['Content-Type'] = 'application/json';

  const response = await fetch(path, {
    method,
    headers,
    signal,
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });

  if (!response.ok) {
    // Non-2xx is a real failure, not an empty payload: surface the status so
    // callers can distinguish "not found" from "transcode still building".
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

export function getMovieDetails(
  filename: string,
  options: { signal?: AbortSignal; deviceId?: string } = {},
) {
  return request<MovieDetailsResponseLive>(`/api/movie/${encodePathSegments(filename)}`, options);
}

export function getMediaInfo(
  filename: string,
  options: { signal?: AbortSignal } = {},
) {
  return request<MediaInfoResponse>(`/api/media-info/${encodePathSegments(filename)}`, options);
}

export function getTranscodeStatus(
  filename: string,
  options: { signal?: AbortSignal } = {},
) {
  return request<TranscodeStatusResponse>(
    `/api/transcode-status/${encodePathSegments(filename)}`,
    options,
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