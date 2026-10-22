import { expect, test } from '@playwright/test';

/*
 * Gate C: one end-to-end walk of the slice - library -> detail -> playback ->
 * progress persisted.
 *
 * This is the only layer that loads a real image and a real media byte range,
 * which is exactly where the two integration bugs this suite now guards
 * against were invisible to unit tests: artwork served as `text/html`, and a
 * seconds/milliseconds mismatch that stopped progress being written at all.
 */

const DEVICE_ID = 'web_e2e_playwright';

/** First movie card on the library grid, with its title. */
async function firstCard(page: import('@playwright/test').Page) {
  const card = page.getByTestId('movie-card').first();
  await expect(card).toBeVisible({ timeout: 20_000 });
  const title = (await card.locator('h3').textContent())?.trim() ?? '';
  const href = await card.getAttribute('href');
  expect(title).not.toBe('');
  expect(href).toContain('/movie/');
  return { card, title };
}

test.describe('library -> detail -> playback -> progress', () => {
  test('walks the slice and persists a resume point', async ({ page }) => {
    // Pin the device id so the watch-history row this test creates is
    // attributable and can be removed afterwards.
    await page.addInitScript((id) => {
      window.localStorage.setItem('media-server.device-id', id);
    }, DEVICE_ID);

    // --- Library ---------------------------------------------------------
    await page.goto('/');
    const { title } = await firstCard(page);

    // Artwork must actually decode. A 200 with `text/html` (what Vite's SPA
    // fallback returns for an unproxied route) yields naturalWidth 0.
    const poster = page.getByTestId('movie-card').first().locator('img');
    await expect(poster).toBeVisible();
    await expect
      .poll(async () => poster.evaluate((img: HTMLImageElement) => img.naturalWidth), {
        timeout: 20_000,
      })
      .toBeGreaterThan(0);

    // --- Detail ----------------------------------------------------------
    await page.getByTestId('movie-card').first().click();
    await expect(page).toHaveURL(/\/movie\//);
    await expect(page.getByRole('heading', { name: title, level: 1 })).toBeVisible();

    // --- Playback --------------------------------------------------------
    // By test id, not accessible name: the brand wordmark contains "PLAY".
    await page.getByTestId('play-button').click();
    const player = page.getByTestId('player');
    await expect(player).toBeVisible({ timeout: 30_000 });

    // The probe picks the mode; assert it is one of the two the server can
    // legitimately return rather than hard-coding one.
    await expect(player).toHaveAttribute('data-mode', /^(direct|hls)$/);

    const video = page.locator('video');
    await expect(video).toBeAttached();

    // A real byte-range/HLS fetch must produce real media metadata.
    await expect
      .poll(async () => video.evaluate((el: HTMLVideoElement) => el.duration), {
        timeout: 30_000,
      })
      .toBeGreaterThan(0);

    // --- Progress persisted ----------------------------------------------
    // Drive the position past the 5s throttle and confirm the resume read
    // sees it. This is the assertion that failed when the throttle compared
    // seconds against a millisecond constant.
    await video.evaluate(async (el: HTMLVideoElement) => {
      el.muted = true;
      el.currentTime = 0;
      await el.play().catch(() => undefined);
    });

    await expect
      .poll(
        async () => {
          const response = await page.request.get(
            `/api/progress?filename=${encodeURIComponent(currentFilename(page))}`,
            { headers: { 'X-Device-Id': DEVICE_ID } },
          );
          const body = (await response.json()) as { position: number };
          return body.position;
        },
        { timeout: 45_000 },
      )
      .toBeGreaterThan(0);
  });
});

/** Read the filename back out of the player route. */
function currentFilename(page: import('@playwright/test').Page): string {
  const splat = new URL(page.url()).pathname.replace(/^\/watch\//, '');
  return decodeURIComponent(splat);
}