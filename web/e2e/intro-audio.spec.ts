import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { expect, test } from '@playwright/test';

import { ARCHIVED_SOURCE, HARNESS_URL } from './intro-oracle';

/**
 * The score's oracle.
 *
 * ## What the reference is
 *
 * The obvious reference is `docs/opening-sequence/assets/intro-theme.wav` -
 * but that is the *Python* renderer's output (`render_intro_theme.py`), and
 * the web port is the original's *Web Audio*. The two are not the same
 * synthesis: the Python renderer sweeps a resonant LOW-PASS over its noise
 * beds, while the original's Web Audio uses a BAND-PASS, and the two filters
 * do not produce the same signal. The source's own comment that the Web Audio
 * "mirrors render_intro_theme.py 1:1" is about the composition, not the
 * samples.
 *
 * So the reference for THIS port is the original's own Web Audio - the
 * archived overlay, which exposes it as `window.INTRO.audio`.
 *
 * ## What is compared, and what that catches
 *
 * **The graph.** Every node the original's score creates, counted by kind, and
 * the port's count must match exactly. This is exact, deterministic, and it
 * is what caught the port's real defect: the original builds the riser
 * INLINE rather than through `noiseVoice`, so it has no high-pass and its
 * sweep ends at `t+0.60`. The port gave the riser a spurious 120 Hz high-pass
 * - one extra filter, and a quieter riser than the original's.
 *
 * **The signal.** The port's score is rendered and compared against the
 * reference WAV on the shape of the score over time, which is the level at
 * which two different synthesis engines can honestly be compared.
 *
 * **Reproducibility.** The port's noise is seeded, so two renders of the same
 * score are the same signal.
 */

const REFERENCE_WAV = resolve(
  process.cwd(),
  '..',
  'docs',
  'opening-sequence',
  'assets',
  'intro-theme.wav',
);

/** The nodes the score builds, by kind. */
const NODE_KINDS = {
  osc: 'createOscillator',
  buf: 'createBufferSource',
  gain: 'createGain',
  filt: 'createBiquadFilter',
  pan: 'createStereoPanner',
  conv: 'createConvolver',
  comp: 'createDynamicsCompressor',
  shaper: 'createWaveShaper',
} as const;

/**
 * The tolerance between two renders of the same score, in sample amplitude.
 *
 * The graph ends in a `ConvolverNode`, whose FFT convolution runs on a
 * separate thread; the order of its partitions is not guaranteed between
 * runs. The difference is therefore numerical, not musical.
 */
const RENDER_EPSILON = 1e-4;

/** The tolerance for the envelope comparison against the WAV, in dB. */
const ENVELOPE_TOLERANCE_DB = 16;

/** Serve the archived original from the dev server's own origin. */
const archivedOnDevServer = async (page: import('@playwright/test').Page) => {
  const archivedHtml = readFileSync(ARCHIVED_SOURCE, 'utf8');
  await page.route(
    (url) => url.pathname === '/__archived-intro.html',
    (route) => route.fulfill({ status: 200, contentType: 'text/html', body: archivedHtml }),
  );
  await page.goto('/__archived-intro.html?intro=capture');
  await page.waitForFunction(() => typeof (window as any).INTRO?.audio?.play === 'function');
};

test.describe('the brand intro score', () => {
  test('builds the same graph as the original Web Audio', async ({ browser }) => {
    const page = await browser.newPage();
    try {
      await archivedOnDevServer(page);

      const counts = await page.evaluate(async (kinds) => {
        const mod = await import('/src/lib/intro/timeline.ts');
        const audio = await import('/src/lib/intro/audio.ts');

        const blank = () => {
          const c: Record<string, number> = {};
          for (const k of Object.keys(kinds)) c[k] = 0;
          return c;
        };
        const install = (ctx: OfflineAudioContext, c: Record<string, number>) => {
          for (const [k, name] of Object.entries(kinds)) {
            const original = (ctx as unknown as Record<string, (...a: unknown[]) => unknown>)[name].bind(ctx);
            (ctx as unknown as Record<string, unknown>)[name] = (...a: unknown[]) => {
              c[k]++;
              return original(...a);
            };
          }
        };

        // The original's score.
        const originalCounts = blank();
        let captured: OfflineAudioContext | null = null;
        window.Math.random = mod.mulberry32(0x1f7a3c);
        window.AudioContext = class {
          constructor() {
            captured = new OfflineAudioContext(2, Math.floor(44100 * 3.3), 44100);
            install(captured, originalCounts);
            return captured;
          }
        };
        (window as any).INTRO.audio.play();
        await (captured as unknown as OfflineAudioContext).startRendering();

        // The port's score, on the same PRNG.
        const portCounts = blank();
        const OAC = window.OfflineAudioContext;
        window.OfflineAudioContext = class extends OAC {
          constructor(...a: unknown[]) {
            super(...(a as [number, number, number]));
            install(this as unknown as OfflineAudioContext, portCounts);
          }
        };
        await audio.renderScoreOffline(44100, 3.3, audio.RAMP);

        return { original: originalCounts, port: portCounts };
      }, NODE_KINDS);

      // The port must build exactly the score the original builds: the same
      // oscillators, the same noise buffers, the same gains, the same
      // filters, the same panners, the same reverb, the same compressor and
      // the same saturation.
      expect(counts.port).toEqual(counts.original);
    } finally {
      await page.close();
    }
  });

  test('renders reproducibly', async ({ browser }) => {
    const page = await browser.newPage();
    try {
      await page.goto(HARNESS_URL);
      const result = await page.evaluate(async () => {
        const mod = await import('/src/lib/intro/audio.ts');
        const a = await mod.renderScoreOffline();
        const b = await mod.renderScoreOffline();
        const da = a.getChannelData(0);
        const db = b.getChannelData(0);
        let maxDiff = 0;
        for (let i = 0; i < Math.min(da.length, db.length); i++) {
          const d = Math.abs(da[i] - db[i]);
          if (d > maxDiff) maxDiff = d;
        }
        return { maxDiff, length: a.length, rate: a.sampleRate };
      });

      // The noise is seeded, so two renders of the same score are the same
      // signal - up to the ConvolverNode's threaded convolution.
      expect(result.maxDiff).toBeLessThanOrEqual(RENDER_EPSILON);
      expect(result.length).toBeGreaterThan(130000);
      expect(result.rate).toBe(44100);
    } finally {
      await page.close();
    }
  });

  test('has the same shape as the reference WAV', async ({ browser }) => {
    const page = await browser.newPage();
    const wav = readFileSync(REFERENCE_WAV).toString('base64');
    try {
      await page.goto(HARNESS_URL);

      const rows = await page.evaluate(async (wavBase64) => {
        const mod = await import('/src/lib/intro/audio.ts');
        // The WAV's score starts at its first sample, so the render must too.
        const port = await mod.renderScoreOffline(44100, 3.1, 0);
        const decodeCtx = new OfflineAudioContext(2, 1, 44100);
        const raw = Uint8Array.from(atob(wavBase64), (c) => c.charCodeAt(0));
        const reference = await decodeCtx.decodeAudioData(raw.buffer);

        const envelope = (buf: AudioBuffer, n: number) => {
          const d = buf.getChannelData(0);
          const w = Math.floor(d.length / n);
          const out: number[] = [];
          for (let k = 0; k < n; k++) {
            let s = 0;
            for (let i = k * w; i < (k + 1) * w; i++) s += d[i] * d[i];
            out.push(Math.sqrt(s / w));
          }
          return out;
        };

        const N = 20;
        const p = envelope(port, N);
        const r = envelope(reference, N);
        const db = (v: number) => (v > 0 ? 20 * Math.log10(v) : -120);
        return p.map((v, i) => ({
          portDb: db(v),
          refDb: db(r[i]),
          deltaDb: db(v) - db(r[i]),
          refLevel: db(r[i]),
        }));
      }, wav);

      const report = rows
        .map(
          (r, i) =>
            `  window ${String(i).padStart(2)}  port ${r.portDb.toFixed(1)} dB   ` +
            `ref ${r.refDb.toFixed(1)} dB   delta ${r.deltaDb >= 0 ? '+' : ''}${r.deltaDb.toFixed(1)} dB`,
        )
        .join('\n');
      console.log(`\nThe score's envelope, against intro-theme.wav:\n${report}\n`);

      for (const [i, row] of rows.entries()) {
        // A window the reference is essentially silent in cannot be compared
        // by a ratio; the port must simply be silent there too.
        if (row.refLevel < -60) {
          expect(row.portDb, `window ${i} should be silent in both`).toBeLessThan(-50);
          continue;
        }
        expect(
          Math.abs(row.deltaDb),
          `the score's envelope differs from the reference in window ${i} ` +
            `(port ${row.portDb.toFixed(1)} dB, ref ${row.refDb.toFixed(1)} dB)`,
        ).toBeLessThanOrEqual(ENVELOPE_TOLERANCE_DB);
      }
    } finally {
      await page.close();
    }
  });
});
