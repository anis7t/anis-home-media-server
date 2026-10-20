/**
 * Verify the television's intro video against the canonical's reference frames.
 *
 * The video is rendered at 60 fps and the reference frames at 30 fps, and both
 * are driven from t = 0, so the reference frame at index `i` and the video's
 * frame at index `2 * i` are the SAME INSTANT - the comparison needs no
 * interpolation and no allowance for motion.
 *
 * What is compared is the window in which the curtain is **closed**: before it
 * the curtain is opaque, so the frame is a property of the sequence alone. The
 * frames after the parting are excluded on purpose - the video's backdrop is
 * the application's background colour, while the reference frames show the
 * application itself behind the parting curtain, so they are different by
 * construction there.
 *
 * The difference that remains is H.264's: a 20-bit-rate encode of a noisy
 * frame is not bit-identical to the frame that was encoded.
 *
 * Usage:
 *   node scripts/verify-intro-video.mjs
 */
import { createRequire } from 'node:module';
import { existsSync, readFileSync, rmSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { execFileSync } from 'node:child_process';

const require = createRequire(resolve(process.cwd(), 'web', 'package.json'));
const { chromium } = require('playwright');

const ROOT = resolve(process.cwd());
const VIDEO = resolve(ROOT, 'flutter_client', 'assets', 'intro', 'intro-tv-1080p.mp4');
const REFERENCE = resolve(ROOT, 'docs', 'opening-sequence', 'frames-shipped');
const FRAME_DIR = resolve(ROOT, 'build', 'intro-video-frames');

/** The reference frames are at 30 fps and the video at 60. */
const REFERENCE_FPS = 30;
const VIDEO_FPS = 60;

/** The last instant at which the curtain is closed. */
const CLOSED_CURTAIN = 1.9;

/** The per-pixel tolerance, the same one the frame capture uses. */
const TOLERANCE = 32;

/**
 * The mean error and the share of pixels that differ by more than the
 * tolerance.
 *
 * The browser is the only PNG decoder on this host, and the web's own oracle
 * does exactly this through a canvas.
 */
async function diffPngs(page, aPath, bPath, tolerance) {
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
      if (ia.width !== ib.width || ia.height !== ib.height) {
        return { sizeMismatch: true };
      }
      const cv = document.createElement('canvas');
      cv.width = ia.width;
      cv.height = ib.height;
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
      return { differing, maxDelta, pixels, share: differing / pixels, mean: sum / pixels };
    },
    [readFileSync(aPath).toString('base64'), readFileSync(bPath).toString('base64'), tolerance],
  );
}

async function main() {
  if (!existsSync(VIDEO)) throw new Error(`no video at ${VIDEO}`);
  if (!existsSync(REFERENCE)) throw new Error(`no reference frames at ${REFERENCE}`);

  rmSync(FRAME_DIR, { recursive: true, force: true });
  mkdirSync(FRAME_DIR, { recursive: true });
  execFileSync(
    'ffmpeg',
    ['-y', '-v', 'error', '-i', VIDEO, resolve(FRAME_DIR, 'v_%04d.png')],
    { stdio: 'inherit' },
  );

  const browser = await chromium.launch({ args: ['--disable-gpu'] });
  const page = await browser.newPage();
  const results = [];
  try {
    const last = Math.floor(CLOSED_CURTAIN * REFERENCE_FPS);
    for (let i = 0; i <= last; i++) {
      const ref = resolve(REFERENCE, `f_${String(i).padStart(4, '0')}.png`);
      // ffmpeg numbers the extracted frames from ONE, so the video's frame at
      // t = i/30 is the file v_<2i + 1>.png.
      const vid = resolve(
        FRAME_DIR,
        `v_${String(i * (VIDEO_FPS / REFERENCE_FPS) + 1).padStart(4, '0')}.png`,
      );
      if (!existsSync(ref) || !existsSync(vid)) continue;
      const r = await diffPngs(page, ref, vid, TOLERANCE);
      if (r.sizeMismatch) throw new Error(`size mismatch at frame ${i}`);
      results.push({ t: i / REFERENCE_FPS, ...r });
    }
  } finally {
    await browser.close();
  }

  const means = results.map((r) => r.mean);
  const shares = results.map((r) => r.share);
  const worst = results.reduce((a, b) => (b.mean > a.mean ? b : a));
  console.log(`compared ${results.length} frames (the closed-curtain window, t <= ${CLOSED_CURTAIN}s)`);
  console.log(`  the mean error: the worst ${worst.mean.toFixed(3)}/255 at t=${worst.t.toFixed(3)}s`);
  console.log(`  the mean of the means: ${(means.reduce((a, b) => a + b, 0) / means.length).toFixed(3)}/255`);
  console.log(`  the share of pixels differing by more than ${TOLERANCE}/255: the worst ${(Math.max(...shares) * 100).toFixed(4)}%`);
  rmSync(FRAME_DIR, { recursive: true, force: true });
}

await main();
