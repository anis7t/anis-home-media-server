/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

/**
 * The API and media origin.
 *
 * **There is only one.** The Flask backend is decommissioned (Phase 7E), and
 * the Rust service is the whole server: it serves `/api/*`, `/media/*`,
 * `/hls/*`, `/subtitles/*`, `/poster/*`, `/tmdb-*` and `/auth/*` itself.
 *
 * This configuration used to point the "Rust" routes at `:8001` and the
 * "Flask" routes at `:8000` - which were the two the wrong way round, and
 * `:8001` no longer runs anything. The dual-origin partition is therefore
 * gone: every proxied prefix goes to the one origin.
 *
 * Override with `MEDIA_SERVER_ORIGIN` to point the dev server elsewhere.
 */
const SERVER_ORIGIN = process.env.MEDIA_SERVER_ORIGIN ?? 'http://127.0.0.1:8000';

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    /**
     * Gate F & Phase 2R: the dev server proxies server-owned prefixes so the browser
     * sees a single same-origin application.
     *
     * **One origin.** The Flask backend is decommissioned (Phase 7E): the
     * Rust service is the whole server, and it serves every one of these
     * prefixes itself. The configuration used to partition them between a
     * "Rust" origin on :8001 (which no longer runs anything) and a "Flask"
     * origin on :8000 (which is the Rust service) - the two were the wrong way
     * round, and the partition is now gone.
     *
     * Vite evaluates proxy keys in insertion order, so the specific `/api/*`
     * prefixes MUST precede the catch-all `'/api'` rule.
     *
     * Only these prefixes are proxied. Everything else is Vite, and the HMR
     * websocket is untouched.
     */
    proxy: {
      // --- The server's own prefixes ---
      '/api/movies': { target: SERVER_ORIGIN, changeOrigin: true },
      '/api/movie': { target: SERVER_ORIGIN, changeOrigin: true },
      '/api/progress': { target: SERVER_ORIGIN, changeOrigin: true },
      '/api/system-status': { target: SERVER_ORIGIN, changeOrigin: true },
      '/api/seek-preview-meta': { target: SERVER_ORIGIN, changeOrigin: true },
      '/api/subtitles': { target: SERVER_ORIGIN, changeOrigin: true },
      '/api/upload-subtitle': { target: SERVER_ORIGIN, changeOrigin: true },
      '/api/transcode-status': { target: SERVER_ORIGIN, changeOrigin: true },
      '/api/transcodes': { target: SERVER_ORIGIN, changeOrigin: true },
      '/api/health': { target: SERVER_ORIGIN, changeOrigin: true },
      '/media': { target: SERVER_ORIGIN, changeOrigin: true },
      '/hls': { target: SERVER_ORIGIN, changeOrigin: true },
      '/seek-preview': { target: SERVER_ORIGIN, changeOrigin: true },
      '/preview-vtt': { target: SERVER_ORIGIN, changeOrigin: true },
      '/subtitles': { target: SERVER_ORIGIN, changeOrigin: true },
      '/tmdb-poster': { target: SERVER_ORIGIN, changeOrigin: true },
      '/tmdb-backdrop': { target: SERVER_ORIGIN, changeOrigin: true },
      '/poster': { target: SERVER_ORIGIN, changeOrigin: true },
      '/auth': { target: SERVER_ORIGIN, changeOrigin: true },

      // --- The catch-all, last ---
      '/api': { target: SERVER_ORIGIN, changeOrigin: true },
    },
  },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/test/setup.ts'],
    testTimeout: 15000,
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