/**
 * Isolate one frame of the intro, for diagnosis.
 *
 * Renders the harness at an exact instant, and compares it with:
 *   - the video's frame at the same instant, and
 *   - the reference frame at the same instant,
 * so that the two possible causes - the video's encoding, and the difference
 * between the harness and the application - can be told apart.
 *
 * Usage: node scripts/intro-frame-diff.mjs <t> [referenceFolder]
 */
import { createRequire } from 'node:module';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const require = createRequire(resolve(process.cwd(), 'web', 'package.json'));
const { chromium } = require('playwright');

const ROOT = resolve(process.cwd());
const T = Number(process.argv[2] ?? 0.6);
const REFERENCE = resolve(
  ROOT,
  'docs',
  'opening-sequence',
  process.argv[3] ?? 'frames-shipped',
);
const VIDEO = resolve(ROOT, 'flutter_client', 'assets', 'intro', 'intro-tv-1080p.mp4');

const SWAP = `(() => {
  const cv = document.querySelector('canvas.intro-fx');
  if (!cv || !cv.width) return 'no-canvas';
  let im = document.getElementById('__sw');
  if (!im) {
    im = document.createElement('img'); im.id = '__sw';
    im.style.cssText = 'position:absolute;left:0;top:0;width:100%;height:100%;z-index:9;pointer-events:none';
    cv.parentNode.insertBefore(im, cv);
  }
  im.src = cv.toDataURL('image/png');
  cv.style.visibility = 'hidden';
  return 'swapped';
})()`;

async function diff(page, aPath, bPath, tolerance = 32) {
  await page.goto('about:blank');
  return await page.evaluate(
    async ([a, b, tol]) => {
      const load = (d) =>
        new Promise((res) => {
          const i = new Image();
          i.onload = () => res(i);
          i.src = `data:image/png;base64,${d}`;
        });
      const ia = await load(a);
      const ib = await load(b);
      const cv = document.createElement('canvas');
      cv.width = ia.width;
      cv.height = ia.height;
      const cx = cv.getContext('2d', { willReadFrequently: true });
      const grab = (img) => {
        cx.clearRect(0, 0, cv.width, cv.height);
        cx.drawImage(img, 0, 0);
        return cx.getImageData(0, 0, cv.width, cv.height).data;
      };
      const da = grab(ia);
      const db = grab(ib);
      let differing = 0;
      let maxDelta = 0;
      let sum = 0;
      let pixels = 0;
      for (let i = 0; i < da.length; i += 4) {
        let d = 0;
        for (let k = 0; k < 4; k++) d = Math.max(d, Math.abs(da[i + k] - db[i + k]));
        sum += d;
        pixels++;
        if (d === 0) continue;
        if (d > maxDelta) maxDelta = d;
        if (d > tol) differing++;
      }
      return { differing, maxDelta, share: differing / pixels, mean: sum / pixels };
    },
    [readFileSync(aPath).toString('base64'), readFileSync(bPath).toString('base64'), tolerance],
  );
}

const browser = await chromium.launch({ args: ['--disable-gpu'] });
try {
  const context = await browser.newContext({
    viewport: { width: 1920, height: 1080 },
    deviceScaleFactor: 1,
  });
  const page = await context.newPage();
  await page.goto('http://localhost:5173/e2e/intro-harness.html', { waitUntil: 'networkidle' });
  await page.waitForFunction(() => window.__introReady === true);
  await page.addStyleTag({ content: 'html, body { background: #090b10 !important; }' });
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(250);
  await page.evaluate((t) => window.__intro.renderAt(t), T);
  await page.evaluate(SWAP);
  const buf = await page.screenshot({ clip: { x: 0, y: 0, width: 1920, height: 1080 } });
  const fresh = resolve(ROOT, 'build', 'vf', 'fresh.png');
  writeFileSync(fresh, buf);
  await context.close();

  const videoFrame = resolve(ROOT, 'build', 'vf', 'all', `v_${String(Math.round(T * 60) + 1).padStart(4, '0')}.png`);
  const referenceFrame = resolve(REFERENCE, `f_${String(Math.round(T * 30)).padStart(4, '0')}.png`);

  const cmp = await browser.newPage();
  const vsVideo = existsSync(videoFrame) ? await diff(cmp, fresh, videoFrame) : null;
  const vsReference = existsSync(referenceFrame) ? await diff(cmp, fresh, referenceFrame) : null;
  await cmp.close();

  console.log(`at t=${T}s`);
  console.log(`  the harness now  vs the video's frame: ${vsVideo ? `mean ${vsVideo.mean.toFixed(2)}/255, ${(vsVideo.share * 100).toFixed(3)}% over 32` : 'n/a'}`);
  console.log(`  the harness now  vs the reference:     ${vsReference ? `mean ${vsReference.mean.toFixed(2)}/255, ${(vsReference.share * 100).toFixed(3)}% over 32` : 'n/a'}`);
} finally {
  await browser.close();
}
