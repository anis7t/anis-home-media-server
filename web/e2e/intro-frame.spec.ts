import { expect, test } from '@playwright/test';
import {
  ARCHIVED_CANVAS,
  HARNESS_URL,
  PORT_CANVAS,
  SAMPLE_TIMES,
  canvasHash,
  diffPngs,
  driveArchived,
  drivePort,
  openArchived,
  openPort,
  readState,
  curtainRevealBand,
} from './intro-oracle';

/**
 * The frame-for-frame oracle.
 *
 * The original overlay and the port are driven to the same instant and what
 * they painted is compared:
 *
 *  - the FX canvas, by the SHA-256 of its pixels - byte-exact;
 *  - every DOM layer's style and geometry, including every letter of both
 *    wordmarks - exact;
 *  - the rendered page, pixel by pixel - exact.
 *
 * Not "equal within a tolerance": the rendered overlay must be the SAME
 * PICTURE as the archived original's, at every sampled instant, in both
 * orientations.
 *
 * See `intro-oracle.ts` for what is normalised and why.
 */

/**
 * The viewports the sweep covers.
 *
 * The design is resolution-independent by construction - everything is in the
 * design unit, `min(w, h) / 100`, with clamps - and the archived original is
 * a standalone document that can be laid out at ANY viewport. So the
 * comparison is not a tolerance against a reference that only exists at two
 * aspects: it is the archived original and the port, side by side, at every
 * aspect, and they must be the same picture.
 */
const VIEWPORTS = [
  { name: 'landscape', width: 1920, height: 1080 },
  { name: 'portrait', width: 1080, height: 1920 },
  { name: 'ultrawide', width: 2560, height: 1080 },
  { name: 'tablet', width: 1024, height: 1366 },
  { name: 'phone-tall', width: 1080, height: 2400 },
];

/** The original's layers, by id. */
const ARCHIVED_LAYERS = {
  icon: '#brandIcon',
  glow: '#iconGlow',
  w1: '#w1',
  'w1__letters': '#w1 span',
  w2: '#w2',
  'w2__letters': '#w2 span',
  sub: '#sub',
  rule: '#rule',
  veilL: '#veilL',
  veilR: '#veilR',
  seam: '#seam',
  vignette: '#vignette',
  grain: '#grain',
  lockup: '#lockup',
};

/** The port's equivalents, by class. */
const PORT_LAYERS = {
  icon: '.intro-icon',
  glow: '.intro-icon-glow',
  w1: '.intro-w1',
  'w1__letters': '.intro-w1 .intro-lt',
  w2: '.intro-w2',
  'w2__letters': '.intro-w2 .intro-lt',
  sub: '.intro-sub',
  rule: '.intro-rule',
  veilL: '.intro-veil-l',
  veilR: '.intro-veil-r',
  seam: '.intro-seam',
  vignette: '.intro-vignette',
  grain: '.intro-grain',
  lockup: '.intro-lockup',
};

test.describe('brand intro - frame for frame against the archived original', () => {
  for (const viewport of VIEWPORTS) {
    test.describe(viewport.name, () => {
      test('the FX canvas is pixel-identical at every sampled instant', async ({ browser }) => {
        const archived = await browser.newPage({ deviceScaleFactor: 1 });
        const port = await browser.newPage({ deviceScaleFactor: 1 });
        try {
          await openArchived(archived, viewport);
          await openPort(port, viewport);

          for (const t of SAMPLE_TIMES) {
            await driveArchived(archived, t);
            await drivePort(port, t);

            const a = await canvasHash(archived, ARCHIVED_CANVAS);
            const b = await canvasHash(port, PORT_CANVAS);

            expect(b, `the port produced no canvas at t=${t}`).not.toBeNull();
            expect(
              b,
              `the FX canvas differs from the original at t=${t} (${viewport.name})`,
            ).toBe(a);
          }
        } finally {
          await archived.close();
          await port.close();
        }
      });

      test('the rendered overlay is pixel-identical at every sampled instant', async ({
        browser,
      }) => {
        test.setTimeout(180_000);
        const archived = await browser.newPage({ deviceScaleFactor: 1 });
        const port = await browser.newPage({ deviceScaleFactor: 1 });
        try {
          await openArchived(archived, viewport);
          await openPort(port, viewport);

          for (const t of SAMPLE_TIMES) {
            await driveArchived(archived, t);
            await drivePort(port, t);

            const a = await archived.screenshot();
            const b = await port.screenshot();
            if (a.equals(b)) continue;

            const diff = await diffPngs(port, a, b);
            expect(
              diff.differing,
              `the rendered overlay differs from the original at t=${t} ` +
                `(${viewport.name}): ${diff.differing} pixels, max channel delta ` +
                `${diff.maxDelta}, bbox ${JSON.stringify(diff.bbox)}`,
            ).toBe(0);
          }
        } finally {
          await archived.close();
          await port.close();
        }
      });
    });
  }

  test('every DOM layer matches the original exactly', async ({ browser }) => {
    const viewport = { width: 1920, height: 1080 };
    const archived = await browser.newPage({ deviceScaleFactor: 1 });
    const port = await browser.newPage({ deviceScaleFactor: 1 });
    try {
      await openArchived(archived, viewport);
      await openPort(port, viewport);

      for (const t of SAMPLE_TIMES) {
        await driveArchived(archived, t);
        await drivePort(port, t);

        const a = await readState(archived, ARCHIVED_LAYERS);
        const b = await readState(port, PORT_LAYERS);

        for (const key of Object.keys(a)) {
          expect(b[key], `the "${key}" layer differs at t=${t}`).toEqual(a[key]);
        }
      }
    } finally {
      await archived.close();
      await port.close();
    }
  });

  /*
   * The shipped app, not the harness.
   *
   * Everything above compares the archived original against the test-only
   * harness page. This compares the harness against the REAL application, in
   * its `?intro=capture` mode, driven through the same `window.__INTRO__` handle.
   *
   * It is what makes the verified thing the thing that ships.
   *
   * While the curtain is closed the comparison is total: the curtain is
   * opaque, so the app's library page, its header and its scrollbar are
   * invisible to it. Once the curtain PARTS, the gap between the halves is
   * the one place the page beneath can show through - so the differing pixels
   * are required to fall inside that gap, and nowhere else. The gap is read
   * from the harness's own curtain halves.
   */
  test('the shipped app in capture mode renders the overlay identically', async ({
    browser,
  }) => {
    test.setTimeout(180_000);
    const viewport = { width: 1920, height: 1080 };
    const app = await browser.newPage({ deviceScaleFactor: 1 });
    const harness = await browser.newPage({ deviceScaleFactor: 1 });
    try {
      await app.setViewportSize(viewport);
      await app.goto('/?intro=capture');
      await app.waitForFunction(
        () => typeof (window as any).__INTRO__?.renderAt === 'function',
        null,
        { timeout: 30_000 },
      );

      await harness.setViewportSize(viewport);
      await harness.goto(HARNESS_URL);
      await harness.waitForFunction(() => (window as any).__introReady === true);

      for (const t of SAMPLE_TIMES) {
        await app.evaluate((time) => (window as any).__INTRO__.renderAt(time), t);
        await harness.evaluate((time) => (window as any).__intro.renderAt(time), t);

        const a = await app.screenshot();
        const b = await harness.screenshot();
        if (a.equals(b)) continue;

        // The one band of the page the curtain does not fully hide: the gap
        // between the halves plus the feathered inner edges.
        const band = await curtainRevealBand(harness, t);

        const diff = await diffPngs(app, a, b, [band]);
        expect(
          diff.outside,
          `the shipped app's overlay differs from the harness outside the curtain's ` +
            `reveal band at t=${t}: ${diff.outside} pixels, max channel delta ` +
            `${diff.maxOutsideDelta}, bbox ${JSON.stringify(diff.bbox)}, band ` +
            `${JSON.stringify(band)}`,
        ).toBe(0);
      }
    } finally {
      await app.close();
      await harness.close();
    }
  });
});
