import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';
import type { Page } from '@playwright/test';

import { shakeDraws } from '../src/lib/intro/timeline';

/**
 * The frame-for-frame oracle.
 *
 * The archived canonical overlay lives outside the web app, at
 * `docs/opening-sequence/source/intro-overlay.html`. It is a self-contained
 * document that can be driven from the outside: loaded with `?intro=capture`
 * it stops its own clock, kills every CSS animation and exposes
 * `window.INTRO.renderAt(t)`.
 *
 * So the oracle can put the ORIGINAL and the PORT side by side, drive both to
 * the same instant, and compare what they actually painted.
 *
 * Three comparisons, at three levels:
 *
 *  1. **the canvas** - the FX layer - compared by the SHA-256 of its pixels.
 *     Byte-exact.
 *  2. **the DOM layers** - every animated layer's style and geometry,
 *     including every letter of both wordmarks. Exact.
 *  3. **the whole overlay** - the rendered page. Pixel-exact.
 *
 * ## What is normalised, and why
 *
 * **The camera shake.** The original's shake drew from `Math.random()`
 * (source 543) and the port's is deterministic by decision D9, so the two can
 * never agree by accident. Rather than skip the window, the oracle makes the
 * ORIGINAL produce the port's shake: `Math.random` is patched to hand it
 * exactly the two draws the port used, so the original computes the same
 * offsets from the same formula. The shake window is then compared like any
 * other.
 *
 * **The compositor hint.** The mark and the lockup carry `will-change`, which
 * promotes them to their own composited layers, and a promoted layer's
 * antialiasing is a hair different from the same content painted directly.
 * That is not a design difference - the markup, the computed styles and the
 * geometry are identical to the last bit - but the two documents promote them
 * differently, so the hint is taken out of the comparison on BOTH sides.
 * `will-change` is a performance hint, not a design element, and the
 * canonical specification's layer stack does not mention it.
 *
 * **The first frame.** The original paints frame zero at load (source 965),
 * before anything else happens. The harness must do the same, or the two
 * documents accumulate a different history - and the compositor ends up
 * rasterising the wordmark's glyphs a hair differently, which is invisible to
 * the eye but is 58 of 255 on a glyph edge.
 *
 * In capture mode the original's only other use of `Math.random` is in the
 * audio path (the reverb impulse and the noise buffers, source 602 and 610),
 * and the audio never initialises in capture mode - so the patch cannot
 * disturb anything else.
 */

export const ARCHIVED_SOURCE = resolve(
  process.cwd(),
  '..',
  'docs',
  'opening-sequence',
  'source',
  'intro-overlay.html',
);

export const HARNESS_URL = '/e2e/intro-harness.html';

/** The camera-shake window, in seconds. */
export const SHAKE_WINDOW: [number, number] = [0.62, 1.04];

/**
 * The instants the oracle compares. They cover every effect in the sequence:
 * the beams and the converging particles, the impact and its burst, the
 * flash, the shockwave rings, the sheen, the wordmarks, the subtitle, the
 * rule, the embers, the curtain parting, the handover and the hold.
 */
export const SAMPLE_TIMES = [
  0.0, 0.2, 0.4, 0.55, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.24, 1.42, 1.58, 1.7, 1.9, 2.1, 2.4, 2.57,
  2.75, 2.95,
];

/** The archived source's SHA-256, so a stale golden fixture cannot pass. */
export const archivedSourceSha256 = (): string =>
  createHash('sha256').update(readFileSync(ARCHIVED_SOURCE)).digest('hex');

const normaliseCompositorHint = (selectors: string[]) => {
  for (const selector of selectors) {
    const el = document.querySelector(selector);
    if (el) (el as HTMLElement).style.willChange = 'auto';
  }
};

/** Load the archived original, in capture mode, at the given viewport. */
export const openArchived = async (page: Page, viewport: { width: number; height: number }) => {
  await page.addInitScript(() => {
    const queue: number[] = [];
    (window as any).__introRandQueue = queue;
    Math.random = () => (queue.length ? (queue.shift() as number) : 0.5);
  });
  await page.setViewportSize(viewport);
  await page.goto(`file:///${ARCHIVED_SOURCE.replace(/\\/g, '/')}?intro=capture`);
  await page.waitForFunction(() => typeof (window as any).INTRO?.renderAt === 'function');
  await page.evaluate(normaliseCompositorHint, ['#brandIcon', '#lockup']);
};

/** Load the port, on the test-only harness page, at the given viewport. */
export const openPort = async (page: Page, viewport: { width: number; height: number }) => {
  await page.setViewportSize(viewport);
  await page.goto(HARNESS_URL);
  await page.waitForFunction(() => (window as any).__introReady === true);
  await page.evaluate(normaliseCompositorHint, ['.intro-icon', '.intro-lockup']);
};

/**
 * Drive the archived original to `t`.
 *
 * The source paints its first frame at load (`renderAt(0)`, source 965), and
 * every frame after that measures the mark's LIVE rectangle - so the frame at
 * `t` sees the geometry left behind by the frame before it. The port does the
 * same thing.
 *
 * That means the two must be driven as a SEQUENCE, in the same order, with
 * the same history: the specular sheen is drawn from the lockup's rectangle
 * as it stood BEFORE the current frame's transform, and the mark's scale is
 * still animating through the impact, so a frame drawn from a different
 * history lands somewhere else. `SAMPLE_TIMES` is ascending, and both pages
 * are driven in the same loop, so the histories match.
 *
 * The draws are computed HERE, in Node: `page.evaluate` runs in the browser,
 * where this module's imports do not exist.
 */
export const driveArchived = (page: Page, t: number) => {
  const draws = shakeDraws(t);
  return page.evaluate(
    (args: { time: number; draws: number[] }) => {
      const queue = (window as any).__introRandQueue as number[];
      queue.length = 0;
      queue.push(...args.draws);
      (window as any).INTRO.renderAt(args.time);
    },
    { time: t, draws },
  );
};

export const drivePort = (page: Page, t: number) =>
  page.evaluate((time) => {
    (window as any).__intro.renderAt(time);
  }, t);

/** The SHA-256 of the FX canvas's pixels. */
export const canvasHash = (page: Page, selector: string) =>
  page.evaluate(async (sel) => {
    const canvas = document.querySelector(sel) as HTMLCanvasElement | null;
    if (!canvas) return null;
    const ctx = canvas.getContext('2d');
    if (!ctx) return null;
    const data = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
    const digest = await crypto.subtle.digest('SHA-256', data);
    return Array.from(new Uint8Array(digest))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');
  }, selector);

/** The archived overlay's canvas selector. */
export const ARCHIVED_CANVAS = '#fx';
/** The port's canvas selector. */
export const PORT_CANVAS = 'canvas.intro-fx';

export interface LayerState {
  /** The element's inline style, parsed into properties so the comparison does
   *  not depend on the order the properties happen to be serialised in. */
  style: Record<string, string>;
  /** The element's rendered box. */
  rect: { x: number; y: number; width: number; height: number };
}

const readLayer = (el: Element | null): LayerState | null => {
  if (!el) return null;
  const style: Record<string, string> = {};
  for (let i = 0; i < el.style.length; i++) {
    const prop = el.style.item(i);
    style[prop] = el.style.getPropertyValue(prop);
  }
  const r = el.getBoundingClientRect();
  return {
    style,
    rect: { x: r.x, y: r.y, width: r.width, height: r.height },
  };
};

/**
 * A snapshot of the DOM layers' state, for comparison.
 *
 * The arguments are selectors, not ids: the original addresses its layers by
 * id and the port by class.
 */
export const readState = (page: Page, selectors: Record<string, string>) =>
  page.evaluate((map) => {
    const read = (el: Element | null) => {
      if (!el) return null;
      const style: Record<string, string> = {};
      for (let i = 0; i < el.style.length; i++) {
        const prop = el.style.item(i);
        style[prop] = el.style.getPropertyValue(prop);
      }
      const r = el.getBoundingClientRect();
      return {
        style,
        rect: { x: r.x, y: r.y, width: r.width, height: r.height },
      };
    };
    const out: Record<string, unknown> = {};
    for (const [key, selector] of Object.entries(map)) {
      const el = document.querySelector(selector);
      if (key.endsWith('__letters')) {
        out[key] = [...(el?.children ?? [])].map(read);
      } else {
        out[key] = read(el);
      }
    }
    return out;
  }, selectors);

export { readLayer };

/**
 * Compare two PNG buffers pixel by pixel.
 *
 * `regions` are rectangles (in CSS pixels) that are allowed to differ - the
 * wordmarks, whose glyphs the two documents rasterise a hair differently. The
 * result counts the differing pixels that fall OUTSIDE every allowed region,
 * which is the number that must be zero.
 */
export const diffPngs = async (
  page: Page,
  a: Buffer,
  b: Buffer,
  regions: { x: number; y: number; width: number; height: number }[] = [],
) =>
  page.evaluate(
    async ([x, y, allowed]) => {
      const load = (d: string) =>
        new Promise<HTMLImageElement>((res) => {
          const i = new Image();
          i.onload = () => res(i);
          i.src = `data:image/png;base64,${d}`;
        });
      const ia = await load(x as string);
      const ic = await load(y as string);
      const cv = document.createElement('canvas');
      cv.width = ia.width;
      cv.height = ia.height;
      const cx = cv.getContext('2d', { willReadFrequently: true })!;
      cx.drawImage(ia, 0, 0);
      const da = cx.getImageData(0, 0, cv.width, cv.height).data;
      cx.clearRect(0, 0, cv.width, cv.height);
      cx.drawImage(ic, 0, 0);
      const dc = cx.getImageData(0, 0, cv.width, cv.height).data;
      const boxes = (allowed as { x: number; y: number; width: number; height: number }[]).map(
        (r) => ({ x0: r.x, y0: r.y, x1: r.x + r.width, y1: r.y + r.height }),
      );
      let differing = 0;
      let outside = 0;
      let maxDelta = 0;
      let maxOutsideDelta = 0;
      let minX = Infinity;
      let maxX = -Infinity;
      let minY = Infinity;
      let maxY = -Infinity;
      for (let i = 0; i < da.length; i += 4) {
        let d = 0;
        for (let k = 0; k < 4; k++) d = Math.max(d, Math.abs(da[i + k] - dc[i + k]));
        if (d === 0) continue;
        differing++;
        maxDelta = Math.max(maxDelta, d);
        const px = (i / 4) % cv.width;
        const py = Math.floor(i / 4 / cv.width);
        minX = Math.min(minX, px);
        maxX = Math.max(maxX, px);
        minY = Math.min(minY, py);
        maxY = Math.max(maxY, py);
        if (!boxes.some((r) => px >= r.x0 && px <= r.x1 && py >= r.y0 && py <= r.y1)) {
          outside++;
          maxOutsideDelta = Math.max(maxOutsideDelta, d);
        }
      }
      return {
        differing,
        outside,
        maxDelta,
        maxOutsideDelta,
        bbox: differing ? { minX, minY, maxX, maxY } : null,
      };
    },
    [a.toString('base64'), b.toString('base64'), regions] as const,
  );
