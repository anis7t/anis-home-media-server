/**
 * Render the brand opening sequence to a video, for the Fire TV.
 *
 * ## Why a video exists
 *
 * The Fire TV's GPU is a 2015 PowerVR Rogue GE8300 with OpenGL ES 3.2 and no
 * Vulkan. Impeller - which compiles every pipeline at build time and removes
 * shader compilation jank by design - therefore cannot be used, and Skia on
 * OpenGL ES compiles each new draw program at runtime, inside the frame that
 * needs it. Measured on that television, the sequence's first frame's raster
 * took **1.09 seconds**, and the three-second sequence got **five frames**.
 *
 * A pre-rendered video removes the problem entirely: the GPU decodes frames
 * instead of generating them, which is how the streaming apps get their
 * smoothness - their openings are pre-rendered too.
 *
 * ## What is rendered, and from what
 *
 * The **harness** - the same page the picture oracle uses - which mounts the
 * real `BrandIntroOverlay` with the playback loop off. The overlay IS the
 * canonical: the oracle proves that the shipped application renders it
 * identically, pixel for pixel, outside the curtain's reveal band.
 *
 * The harness's own backdrop is the browser's default white, because the
 * archived original was a standalone document. The video needs something else:
 * the television's application is a **dark** app, and the curtain parts onto
 * whatever is behind it, so the video's backdrop is the application's own
 * background colour (#090b10) and the app fades in behind the video's last
 * quarter-second.
 *
 * The wordmark's typeface is whatever the capture machine's system font is.
 * The television's Flutter client uses the platform font, and the two are
 * different; this is a recorded divergence (see docs/OPENING_SEQUENCE.md).
 *
 * ## Usage
 *
 *   node scripts/capture-intro-video.mjs
 *
 * It needs the Vite dev server on http://localhost:5173 (the harness is a
 * dev-server page, and it is not part of the application bundle), and it
 * writes the MP4 into `flutter_client/assets/intro/`.
 */
import { createRequire } from 'node:module';
import { existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { execFileSync } from 'node:child_process';

const require = createRequire(resolve(process.cwd(), 'web', 'package.json'));
const { chromium } = require('playwright');

const ROOT = resolve(process.cwd());
const OUT_DIR = resolve(ROOT, 'flutter_client', 'assets', 'intro');
const FRAME_DIR = resolve(ROOT, 'build', 'intro-video-frames');

/** The dev server, which serves the harness. It binds the IPv6 loopback. */
const BASE = process.env.INTRO_VIDEO_BASE ?? 'http://localhost:5173';
const HARNESS = `${BASE}/e2e/intro-harness.html`;

/** The television's resolution. */
const WIDTH = 1920;
const HEIGHT = 1080;

/** The canonical's frame rate, and the sequence's length. */
const FPS = 60;
const SECONDS = 3.0;
const NFRAMES = Math.round(FPS * SECONDS);

/**
 * The application's own background colour.
 *
 * The curtain parts onto whatever is behind it, so the video's backdrop has to
 * be the colour the television's application is painted in - otherwise the
 * curtain would part onto white and then the app would appear over it.
 */
const BACKDROP = '#090b10';

/**
 * The canvas handover.
 *
 * The screenshot path only repaints when the DOM is damaged, so a canvas that
 * animates on its own is invisible to it. The canvas is therefore handed over
 * as an image for the duration of the capture - the same handover the frame
 * capture uses, and the same one the archived capture did.
 */
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

async function main() {
  if (!existsSync(resolve(ROOT, 'web', 'node_modules'))) {
    throw new Error('web/node_modules is missing - run `npm install` in web/ first.');
  }

  rmSync(FRAME_DIR, { recursive: true, force: true });
  mkdirSync(FRAME_DIR, { recursive: true });
  mkdirSync(OUT_DIR, { recursive: true });

  // The GPU on this host is chronically unstable - 42 queued WER kernel reports
  // and 22 GPU TDRs - and a hard system reset was triggered by headless
  // Chromium's GPU compositing during the brand-intro pixel oracle. Software
  // rasterisation is deterministic, which is what a capture needs.
  const browser = await chromium.launch({ args: ['--disable-gpu'] });
  try {
    const context = await browser.newContext({
      viewport: { width: WIDTH, height: HEIGHT },
      deviceScaleFactor: 1,
    });
    const page = await context.newPage();
    await page.goto(HARNESS, { waitUntil: 'networkidle' });
    await page.waitForFunction(() => typeof window.__intro?.renderAt === 'function');
    await page.waitForFunction(() => window.__introReady === true);

    // The backdrop the curtain will part onto.
    await page.addStyleTag({
      content: `html, body { background: ${BACKDROP} !important; }`,
    });

    // The fonts must be settled before the first frame: a wordmark drawn
    // before the typeface lands is rasterised with the fallback.
    await page.evaluate(() => document.fonts.ready);
    await page.waitForTimeout(250);

    // The frames are driven as an ASCENDING SEQUENCE, because the canonical
    // measures the mark's live rectangle - a frame drawn from a different
    // history lands somewhere else.
    for (let i = 0; i < NFRAMES; i++) {
      const t = i / FPS;
      await page.evaluate((time) => window.__intro.renderAt(time), t);
      await page.evaluate(SWAP);
      const buf = await page.screenshot({
        clip: { x: 0, y: 0, width: WIDTH, height: HEIGHT },
      });
      writeFileSync(resolve(FRAME_DIR, `f_${String(i).padStart(4, '0')}.png`), buf);
      if (i % 30 === 0) console.log(`  frame ${i}/${NFRAMES} (t=${t.toFixed(3)}s)`);
    }
    await context.close();
  } finally {
    await browser.close();
  }

  const out = resolve(OUT_DIR, 'intro-tv-1080p.mp4');
  // H.264 in yuv420p: the only profile every Android device decodes, and the
  // television's decoder is nine years old. The audio is the canonical's WAV,
  // played by the client beside the video, so this file carries none.
  execFileSync(
    'ffmpeg',
    [
      '-y', '-v', 'error',
      '-framerate', String(FPS),
      '-i', resolve(FRAME_DIR, 'f_%04d.png'),
      '-c:v', 'libx264',
      '-profile:v', 'high',
      '-level', '4.0',
      '-pix_fmt', 'yuv420p',
      '-crf', '20',
      '-preset', 'slow',
      '-movflags', '+faststart',
      '-r', String(FPS),
      out,
    ],
    { stdio: 'inherit' },
  );

  rmSync(FRAME_DIR, { recursive: true, force: true });
  console.log(`wrote ${out}`);
}

await main();
