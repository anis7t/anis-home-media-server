import { defineConfig, devices } from '@playwright/test';

/*
 * Gate C end-to-end layer. Runs against the dev server, which proxies the
 * server-owned prefixes to the running Flask service - so this exercises the
 * real API, real artwork routes and real byte-range streaming, not mocks.
 *
 * Side effect: the progress assertion writes a watch-history row. The E2E pins
 * `E2E_DEVICE_ID` so any row it creates is attributable and removable. It must
 * not be left pointing at a real device id.
 */
const DEVICE_ID = 'web_e2e_playwright';

export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: [['list']],
  use: {
    baseURL: 'http://localhost:5173',
    trace: 'retain-on-failure',
    /*
     * The GPU is disabled for every browser this config launches.
     *
     * This host's AMD graphics driver is chronically unstable - 42 queued WER
     * kernel reports from September 2025 to October 2026, including 22 GPU
     * TDRs - and on 2026-10-20 15:01 a hard system reset was triggered by
     * headless-Chromium GPU compositing during the brand-intro pixel oracle.
     * The full post-mortem is in
     * Handoffs/2026-10-20_15-45_opencode_system-restart-forensics.md.
     *
     * Software rasterisation is deterministic - which is what the pixel oracle
     * needs anyway, since it compares two renders of the same page in the
     * same browser - so the comparison stays exact and the GPU load goes away.
     *
     * Also: do not run a transcode and this harness concurrently. Both are
     * GPU-heavy, and running them together is how a TDR becomes a hard reset.
     */
    launchOptions: {
      args: ['--disable-gpu'],
    },
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:5173',
    reuseExistingServer: true,
    timeout: 120_000,
  },
});

export { DEVICE_ID };