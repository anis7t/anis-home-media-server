import { expect, test, type Page } from '@playwright/test';

/*
 * Issue 14.5: the signed-out header's "Sign in" control used to start Google
 * immediately. It now opens a chooser. The QR entry is a link to /account,
 * where the existing QrSignInPanel owns the pair-session lifecycle.
 *
 * The API is mocked, so opening the menu creates no real pair session and the
 * test does not consume the QR rate-limit budget. The one POST the test expects
 * is the one /account makes when it mounts.
 */

const QR_ID = `qr_${'a'.repeat(64)}`;
const SIG = 'b'.repeat(64);
const QR_URL = `https://media.anisparvez.in/remotelogin?qr_id=${QR_ID}&code=ABCDE&sig=${SIG}`;

const SESSION = {
  qr_id: QR_ID,
  code: 'ABCDE',
  sig: SIG,
  expires_at: Math.floor(Date.now() / 1000) + 120,
  qr_url: QR_URL,
  login_url: 'https://media.anisparvez.in/remotelogin',
};

interface MockOptions {
  readonly signedIn?: boolean;
  readonly oauthConfigured?: boolean;
}

async function mockApi(page: Page, options: MockOptions = {}): Promise<void> {
  const { signedIn = false, oauthConfigured = true } = options;

  await page.route('**/api/**', async (route) => {
    const request = route.request();
    const url = new URL(request.url());

    // `**/api/**` also matches Vite module paths such as
    // /src/lib/api/account.ts. Only the server's own /api/ prefix is mocked.
    if (!url.pathname.startsWith('/api/')) {
      await route.continue();
      return;
    }

    if (url.pathname === '/api/auth/me') {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(
          signedIn
            ? {
                authenticated: true,
                email: 'e2e@example.test',
                name: 'E2E',
                role: 'viewer',
                oauth_configured: oauthConfigured,
              }
            : { authenticated: false, oauth_configured: oauthConfigured },
        ),
      });
      return;
    }

    if (url.pathname === '/api/auth/qr' && request.method() === 'POST') {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(SESSION),
      });
      return;
    }

    if (url.pathname.endsWith('/wait')) {
      // EventSource. Abort it; the hook keeps the QR on the countdown fallback,
      // which is all this test needs.
      await route.abort();
      return;
    }

    if (url.pathname === '/api/transcodes') {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ transcodes: [] }),
      });
      return;
    }

    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: '{}',
    });
  });
}

test.describe('Issue 14.5 - header sign-in menu', () => {
  test('desktop shows Google and QR, and QR navigates to the existing panel', async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1280, height: 800 });

    const qrCreates: string[] = [];
    page.on('request', (request) => {
      if (
        request.method() === 'POST' &&
        new URL(request.url()).pathname === '/api/auth/qr'
      ) {
        qrCreates.push(request.url());
      }
    });

    await mockApi(page, { signedIn: false });
    await page.goto('/?intro=off');

    const trigger = page.getByRole('button', { name: 'Sign in' });
    await expect(trigger).toHaveAttribute('aria-haspopup', 'menu');

    await trigger.click();

    await expect(page.getByRole('menu')).toBeVisible();
    await expect(
      page.getByRole('menuitem', { name: /continue with google/i }),
    ).toBeVisible();
    const qrItem = page.getByRole('menuitem', { name: /sign in with qr code/i });
    await expect(qrItem).toBeVisible();

    // Opening the menu must not mint a pair session. Only /account may.
    expect(qrCreates).toHaveLength(0);

    await qrItem.click();
    await expect(page).toHaveURL(/\/account$/);
    await expect(
      page.getByRole('heading', { name: /sign in to anis' home media server/i }),
    ).toBeVisible({ timeout: 15_000 });
    await expect(
      page.locator('canvas[aria-label="QR code to sign in on this device"]'),
    ).toBeVisible({ timeout: 15_000 });

    // StrictMode can mount the effect twice in the dev server, so the exact
    // count is not stable; "at least one" is the contract.
    await expect.poll(() => qrCreates.length, { timeout: 15_000 }).toBeGreaterThan(0);
  });

  test('the menu stays inside a 390px viewport', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await mockApi(page, { signedIn: false });
    await page.goto('/?intro=off');

    await page.getByRole('button', { name: 'Sign in' }).click();
    const menu = page.getByRole('menu');
    await expect(menu).toBeVisible();

    const box = await menu.boundingBox();
    expect(box).not.toBeNull();
    expect(box!.x).toBeGreaterThanOrEqual(0);
    expect(box!.x + box!.width).toBeLessThanOrEqual(390);

    const documentWidth = await page.evaluate(() => ({
      scroll: document.documentElement.scrollWidth,
      client: document.documentElement.clientWidth,
    }));
    expect(documentWidth.scroll).toBeLessThanOrEqual(documentWidth.client);
  });

  test('OAuth unconfigured offers the Admin PIN instead of Google', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await mockApi(page, { signedIn: false, oauthConfigured: false });
    await page.goto('/?intro=off');

    await page.getByRole('button', { name: 'Sign in' }).click();

    await expect(
      page.getByRole('menuitem', { name: /sign in with admin pin/i }),
    ).toBeVisible();
    await expect(
      page.getByRole('menuitem', { name: /continue with google/i }),
    ).toHaveCount(0);
    await expect(
      page.getByRole('menuitem', { name: /sign in with qr code/i }),
    ).toBeVisible();
  });

  test('signed-in header keeps the avatar menu and offers no sign-in menu', async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await mockApi(page, { signedIn: true });
    await page.goto('/?intro=off');

    await expect(
      page.getByRole('button', { name: 'Open account menu' }),
    ).toBeVisible();
    await expect(page.getByRole('button', { name: 'Sign in' })).toHaveCount(0);
  });

  test.describe('phone browser', () => {
    test.use({
      userAgent:
        'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
      viewport: { width: 412, height: 915 },
      isMobile: true,
      hasTouch: true,
      deviceScaleFactor: 2.625,
    });

    test('hides the QR option and keeps a direct Google button', async ({ page }) => {
      await mockApi(page, { signedIn: false });
      await page.goto('/?intro=off');

      const trigger = page.getByRole('button', { name: 'Sign in' });
      await expect(trigger).toBeVisible();
      await expect(trigger).not.toHaveAttribute('aria-haspopup', 'menu');
      await expect(
        page.getByRole('menuitem', { name: /sign in with qr code/i }),
      ).toHaveCount(0);
    });
  });
});
