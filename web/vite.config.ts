/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

/**
 * Rust native API & media streaming engine origin. Defaults to loopback:8001.
 * Override with RUST_API_ORIGIN to point the dev server elsewhere.
 */
const RUST_ORIGIN = process.env.RUST_API_ORIGIN ?? 'http://127.0.0.1:8001';

/**
 * Flask origin for unmigrated services (OAuth, Cast, Devices, Storage, TMDb artwork proxy).
 * Defaults to the deployed service on loopback:8000.
 * Override with MEDIA_SERVER_ORIGIN to point the dev server elsewhere.
 */
const FLASK_ORIGIN = process.env.MEDIA_SERVER_ORIGIN ?? 'http://127.0.0.1:8000';

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    /**
     * Gate F & Phase 2R: the dev server proxies server-owned prefixes so the browser
     * sees a single same-origin application.
     *
     * Dual-Origin Partitioning:
     * - Migrated high-throughput endpoints (movies, streaming, HLS, live previews,
     *   subtitles, progress, transcode status, and system telemetry) route directly
     *   to the native Rust engine on :8001.
     * - Unmigrated endpoints (OAuth authentication, Google Cast / DLNA, device fleet
     *   management, admin storage policies, library scanner trigger, and TMDb artwork
     *   caching) fall through to the Python Flask backend on :8000.
     *
     * Vite evaluates proxy keys in insertion order. Specific `/api/*` prefixes directed
     * to Rust MUST precede the catch-all `'/api'` fallback rule for Flask.
     *
     * Only these prefixes are proxied. Everything else is Vite, and the HMR
     * websocket is untouched.
     */
    proxy: {
      // --- Rust Engine Migrated Endpoints (:8001) ---
      '/api/movies': { target: RUST_ORIGIN, changeOrigin: true },
      '/api/movie': { target: RUST_ORIGIN, changeOrigin: true },
      '/api/progress': { target: RUST_ORIGIN, changeOrigin: true },
      '/api/system-status': { target: RUST_ORIGIN, changeOrigin: true },
      '/api/seek-preview-meta': { target: RUST_ORIGIN, changeOrigin: true },
      '/api/subtitles': { target: RUST_ORIGIN, changeOrigin: true },
      '/api/upload-subtitle': { target: RUST_ORIGIN, changeOrigin: true },
      '/api/transcode-status': { target: RUST_ORIGIN, changeOrigin: true },
      '/api/transcodes': { target: RUST_ORIGIN, changeOrigin: true },
      '/api/health': { target: RUST_ORIGIN, changeOrigin: true },
      '/media': { target: RUST_ORIGIN, changeOrigin: true },
      '/hls': { target: RUST_ORIGIN, changeOrigin: true },
      '/seek-preview': { target: RUST_ORIGIN, changeOrigin: true },
      '/preview-vtt': { target: RUST_ORIGIN, changeOrigin: true },
      '/subtitles': { target: RUST_ORIGIN, changeOrigin: true },

      // --- Flask Backend Unmigrated Endpoints (:8000) ---
      '/api': { target: FLASK_ORIGIN, changeOrigin: true },
      '/tmdb-poster': { target: FLASK_ORIGIN, changeOrigin: true },
      '/tmdb-backdrop': { target: FLASK_ORIGIN, changeOrigin: true },
      '/poster': { target: FLASK_ORIGIN, changeOrigin: true },
      '/auth': { target: FLASK_ORIGIN, changeOrigin: true },
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