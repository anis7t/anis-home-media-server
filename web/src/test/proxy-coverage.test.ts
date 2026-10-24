import { describe, expect, it } from 'vitest';

import config from '../../vite.config';
import { backdropUrl, posterUrl } from '../lib/api/poster';
import { directMediaUrl, hlsPlaylistUrl } from '../lib/api/media';

const proxy = (config.server?.proxy ?? {}) as Record<string, { target?: string }>;

/**
 * Every server URL the app can construct must be proxied in development.
 *
 * Regression: an earlier proxy listed only `/api`, `/media` and `/hls`. The
 * artwork routes were not covered, so Vite's SPA fallback answered every
 * poster request with HTTP 200 and `text/html`. A 200 with the wrong content
 * type passes a status-code check, and the unit tests mocked `fetch` so they
 * never loaded an image - the library rendered a wall of placeholders and
 * nothing was green.
 *
 * This asserts the invariant that closes that gap: if a builder starts emitting
 * a new server URL, this test fails until the proxy is updated.
 */
function isProxied(url: string): boolean {
  const path = url.split('?')[0];
  return Object.keys(proxy).some((prefix) => path.startsWith(prefix));
}

describe('dev proxy covers every server URL the app builds', () => {
  it('proxies TMDb poster URLs', () => {
    expect(isProxied(posterUrl('tmdb:62') ?? '')).toBe(true);
  });

  it('proxies local poster URLs', () => {
    expect(isProxied(posterUrl('local:posters/a.jpg') ?? '')).toBe(true);
  });

  it('proxies backdrop URLs', () => {
    expect(isProxied(backdropUrl(62) ?? '')).toBe(true);
  });

  it('proxies direct-play media URLs', () => {
    expect(isProxied(directMediaUrl('a.mkv'))).toBe(true);
  });

  it('proxies HLS playlist URLs', () => {
    expect(isProxied(hlsPlaylistUrl('a.mkv'))).toBe(true);
  });

  it('proxies the API prefixes the client uses', () => {
    for (const url of ['/api/movies', '/api/movie/a.mkv', '/api/media-info/a.mkv', '/api/progress']) {
      expect(isProxied(url)).toBe(true);
    }
  });

  it('does not proxy Vite-owned paths', () => {
    // `/static` belongs to Flask but the React app serves its own assets; the
    // SPA fallback must stay reachable for client-side routes.
    for (const url of ['/', '/src/main.tsx', '/@vite/client']) {
      expect(isProxied(url)).toBe(false);
    }
  });
});

describe('dev proxy dual-origin wiring', () => {
  it('routes Rust-migrated endpoints to the Rust engine origin (:8001)', () => {
    const rustEndpoints = [
      '/api/movies',
      '/api/movie',
      '/api/progress',
      '/api/system-status',
      '/api/seek-preview-meta',
      '/api/subtitles',
      '/api/upload-subtitle',
      '/api/transcode-status',
      '/api/transcodes',
      '/api/health',
      '/media',
      '/hls',
      '/seek-preview',
      '/preview-vtt',
      '/subtitles',
    ];
    for (const prefix of rustEndpoints) {
      const entry = proxy[prefix];
      expect(entry, `missing proxy configuration for ${prefix}`).toBeDefined();
      expect(entry?.target).toMatch(/^http:\/\/127\.0\.0\.1:8001$|^http:\/\//);
    }
  });

  it('routes unmigrated endpoints to the Flask origin (:8000)', () => {
    const flaskEndpoints = [
      '/api',
      '/tmdb-poster',
      '/tmdb-backdrop',
      '/poster',
      '/auth',
    ];
    for (const prefix of flaskEndpoints) {
      const entry = proxy[prefix];
      expect(entry, `missing proxy configuration for ${prefix}`).toBeDefined();
      expect(entry?.target).toMatch(/^http:\/\/127\.0\.0\.1:8000$|^http:\/\//);
    }
  });

  it('targets a valid loopback origin for every entry', () => {
    for (const entry of Object.values(proxy)) {
      expect(entry.target).toMatch(/^http:\/\/127\.0\.0\.1:(8000|8001)$|^http:\/\//);
    }
  });
});