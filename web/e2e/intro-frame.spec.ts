import { expect, test } from '@playwright/test';
import {
  ARCHIVED_CANVAS,
  PORT_CANVAS,
  SAMPLE_TIMES,
  canvasHash,
  diffPngs,
  driveArchived,
  drivePort,
  openArchived,
  openPort,
  readState,
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

const VIEWPORTS = [
  { name: 'landscape', width: 1920, height: 1080 },
  { name: 'portrait', width: 1080, height: 1920 },
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
});
