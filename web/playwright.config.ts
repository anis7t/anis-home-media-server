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