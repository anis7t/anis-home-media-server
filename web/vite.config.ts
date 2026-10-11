/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

/**
 * Flask origin. Defaults to the deployed service on loopback.
 * Override with MEDIA_SERVER_ORIGIN to point the dev server elsewhere.
 */
const FLASK_ORIGIN = process.env.MEDIA_SERVER_ORIGIN ?? 'http://127.0.0.1:8000';

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    /**
     * Gate F: the dev server proxies the server-owned prefixes so the browser
     * sees a single same-origin application.
     *
     * This is why no CORS change is needed for `/api/*`. The server's
     * `CORS_PATHS` in `app/routes/media.py` stays exactly `('/media/', '/hls/')`,
     * which is the deliberate scoping documented in AGENTS.md for Cast
     * receivers. Widening it to cover `/api/*` would have been the wrong fix:
     * it would have changed production behaviour to suit a dev convenience.
     *
     * The list below was enumerated from the app's own `url_map` rather than
     * written from memory. An earlier version listed only `/api`, `/media` and
     * `/hls`, which left `/tmdb-poster/*` and `/poster/*` to Vite's SPA
     * fallback: those requests returned HTTP 200 with `text/html`, every poster
     * failed to decode, and the library rendered a wall of placeholders. A 200
     * with the wrong content type is exactly the failure a status-code check
     * cannot see, and mocked unit tests cannot see either - they never load an
     * image.
     *
     * Only these prefixes are proxied. Everything else is Vite, and the HMR
     * websocket is untouched.
     */
    proxy: {
      // REST API.
      '/api': { target: FLASK_ORIGIN, changeOrigin: true },
      // Byte-range direct play.
      '/media': { target: FLASK_ORIGIN, changeOrigin: true },
      // HLS playlists and segments.
      '/hls': { target: FLASK_ORIGIN, changeOrigin: true },
      // Artwork. Missing these is invisible until the grid renders empty.
      '/tmdb-poster': { target: FLASK_ORIGIN, changeOrigin: true },
      '/tmdb-backdrop': { target: FLASK_ORIGIN, changeOrigin: true },
      '/poster': { target: FLASK_ORIGIN, changeOrigin: true },
      // Seek-preview thumbnails and subtitles, used by later slices.
      '/seek-preview': { target: FLASK_ORIGIN, changeOrigin: true },
      '/subtitles': { target: FLASK_ORIGIN, changeOrigin: true },
      // Sign-in. Without this the browser hits Vite's SPA fallback for
      // /auth/google and gets index.html instead of the redirect to Google, so
      // sign-in silently does nothing in development.
      '/auth': { target: FLASK_ORIGIN, changeOrigin: true },
    },
  },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/test/setup.ts'],
    css: false,
    // Vitest's default include also matches the Playwright specs under `e2e/`,
    // which then fail with "Playwright Test did not expect test.describe() to
    // be called here". The two runners own separate trees.
    include: ['src/**/*.{test,spec}.{ts,tsx}'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'html'],
      // Gate C: coverage is scoped to the two features in this slice, not the
      // whole app - a whole-app threshold would reward writing tests for
      // generated scaffolding nobody hand-maintains.
      include: ['src/features/**', 'src/lib/**'],
    },
  },
});