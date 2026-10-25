import { expect, test, type Page } from '@playwright/test';

/*
 * Issue 14.4: the QR code was reported as cropped.
 *
 * The reported panel was the Add-device pairing QR, which was removed with
 * the pairing-token surface in d6d6786 (Issue 14.6). The only QR left is the
 * signed-out sign-in panel on /account.
 *
 * That panel renders through `qrcode` with `width: 0`. The library does not
 * treat zero as "fill the element" - it falls back to its default scale of 4
 * and writes an inline canvas size. A production-shaped pairing URL is 193
 * characters / 57 modules, so the canvas is 236 x 236 px while the card clamps
 * to 160-220 px and clips with `overflow-hidden`. This probe measures that.
 *
 * The API is mocked so the test creates no real pair session, consumes no
 * QR rate-limit budget, and never reaches the backend.
 */

const QR_ID = `qr_${'a'.repeat(64)}`;
const SIG = 'b'.repeat(64);

/* 193 characters, 57 modules at error-correction M - the real shape. */
const QR_URL = `https://media.anisparvez.in/remotelogin?qr_id=${QR_ID}&code=ABCDE&sig=${SIG}`;

const SESSION = {
  qr_id: QR_ID,
  code: 'ABCDE',
  sig: SIG,
  expires_at: Math.floor(Date.now() / 1000) + 120,
  qr_url: QR_URL,
  login_url: 'https://media.anisparvez.in/remotelogin',
};

interface LayoutMetrics {
  canvas: { x: number; y: number; width: number; height: number; right: number; bottom: number };
  card: { x: number; y: number; width: number; height: number; right: number; bottom: number };
  canvasBitmap: { width: number; height: number };
  cardOverflow: string;
  doc: { scrollWidth: number; clientWidth: number };
}

async function mockApi(page: Page, signedIn: boolean): Promise<void> {
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
                oauth_configured: true,
              }
            : { authenticated: false, oauth_configured: true },
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
      // EventSource. Abort it; the hook closes on error and keeps the QR on
      // the countdown fallback, which is exactly what the layout needs.
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

async function measure(page: Page): Promise<LayoutMetrics> {
  return page.evaluate(() => {
    const canvas = document.querySelector<HTMLCanvasElement>(
      'canvas[aria-label="QR code to sign in on this device"]',
    );
    if (!canvas) throw new Error('QR canvas not found');
    const card = canvas.parentElement;
    if (!card) throw new Error('QR card not found');

    const rect = (el: Element) => {
      const r = el.getBoundingClientRect();
      return {
        x: r.x,
        y: r.y,
        width: r.width,
        height: r.height,
        right: r.right,
        bottom: r.bottom,
      };
    };

    return {
      canvas: rect(canvas),
      card: rect(card),
      canvasBitmap: { width: canvas.width, height: canvas.height },
      cardOverflow: getComputedStyle(card).overflow,
      doc: {
        scrollWidth: document.documentElement.scrollWidth,
        clientWidth: document.documentElement.clientWidth,
      },
    };
  });
}

function expectFits(metrics: LayoutMetrics, width: number): void {
  // Log the numbers so a failure explains itself.
  console.log(`[qr-layout ${width}px]`, JSON.stringify(metrics));

  expect(metrics.cardOverflow, 'the card must still clip its rounded corners').toBe('hidden');
  expect(metrics.doc.scrollWidth, 'no horizontal overflow').toBeLessThanOrEqual(
    metrics.doc.clientWidth,
  );

  // The whole canvas has to sit inside the card. A one-pixel tolerance keeps
  // fractional layout from failing the assertion for a sub-pixel edge. This
  // is the actual 14.4 regression: the old canvas was 236 px inside a card
  // that clamped to 160-220 px.
  expect(metrics.canvas.x, `canvas left at ${width}px`).toBeGreaterThanOrEqual(
    metrics.card.x - 1,
  );
  expect(metrics.canvas.y, `canvas top at ${width}px`).toBeGreaterThanOrEqual(
    metrics.card.y - 1,
  );
  expect(metrics.canvas.right, `canvas right at ${width}px`).toBeLessThanOrEqual(
    metrics.card.right + 1,
  );
  expect(metrics.canvas.bottom, `canvas bottom at ${width}px`).toBeLessThanOrEqual(
    metrics.card.bottom + 1,
  );

  expect(metrics.canvasBitmap.width, 'canvas bitmap must be non-empty').toBeGreaterThan(0);
  expect(metrics.canvasBitmap.height, 'canvas bitmap must be non-empty').toBeGreaterThan(0);

  // The card itself must stay large enough to scan the 57-module payload.
  expect(metrics.card.width, `card width at ${width}px`).toBeGreaterThanOrEqual(220);
  expect(metrics.card.height, `card height at ${width}px`).toBeGreaterThanOrEqual(220);
}

const VIEWPORTS = [
  { width: 390, height: 844 },
  { width: 768, height: 1024 },
  { width: 1280, height: 800 },
] as const;

test.describe('Issue 14.4 - QR layout', () => {
  for (const viewport of VIEWPORTS) {
    test(`signed-out QR fits inside its card at ${viewport.width}px`, async ({
      page,
    }, info) => {
      await page.setViewportSize(viewport);
      await mockApi(page, false);
      await page.goto('/account?intro=off');

      const canvas = page.locator('canvas[aria-label="QR code to sign in on this device"]');
      await expect(canvas).toBeVisible({ timeout: 15_000 });

      // Wait for the dynamic `qrcode` import to paint the bitmap.
      await expect
        .poll(
          async () =>
            canvas.evaluate((el: HTMLCanvasElement) => el.width > 0 && el.height > 0),
          { timeout: 15_000 },
        )
        .toBe(true);

      const metrics = await measure(page);
      await page.screenshot({
        path: info.outputPath(`qr-signed-out-${viewport.width}.png`),
        fullPage: true,
      });
      await info.attach(`qr-layout-${viewport.width}.json`, {
        body: JSON.stringify(metrics, null, 2),
        contentType: 'application/json',
      });

      expectFits(metrics, viewport.width);
    });
  }

  test('signed-in /account renders no QR and requests no pair session', async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1280, height: 800 });

    const qrCreateRequests: string[] = [];
    page.on('request', (request) => {
      if (request.method() === 'POST' && new URL(request.url()).pathname === '/api/auth/qr') {
        qrCreateRequests.push(request.url());
      }
    });

    await mockApi(page, true);
    await page.goto('/account?intro=off');

    await expect(page.getByRole('heading', { name: 'Active Session' })).toBeVisible({
      timeout: 15_000,
    });
    await expect(
      page.locator('canvas[aria-label="QR code to sign in on this device"]'),
    ).toHaveCount(0);
    await expect(page.locator('section[aria-label="QR Device Sign-In"]')).toHaveCount(0);

    expect(qrCreateRequests).toHaveLength(0);
  });
});
