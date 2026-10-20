/**
 * Generate the canonical frame fixture.
 *
 * The Flutter client computes the same frame as the web's renderer, and this
 * is the fixture that says so: it holds, for every sampled instant, the
 * values the CANONICAL implementation rendered - parsed out of the very
 * strings it wrote to the DOM.
 *
 * Why the strings are the source: the original wrote pre-formatted values
 * (`scale(1.5500)`, `translateY(0.550em)`, `blur(7.00px)`), and the ROUNDING
 * IS PART OF THE RENDERING. So the fixture records the rounded values, and
 * the Dart port rounds the same way.
 *
 * The reference is the web's renderer, because it is pixel-identical to the
 * archived original - the web's oracle proves that, frame by frame.
 *
 * The web's module graph is loaded through the dev server, because its
 * imports are extensionless and Node's type-stripping cannot resolve them.
 *
 * Usage:  node scripts/gen-intro-frame-golden.mjs
 * Output: docs/opening-sequence/frame-golden.json
 */
import { writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';

// Playwright is the web project's dependency, not the repository's, so it is
// resolved from there.
const require = createRequire(resolve(process.cwd(), 'web', 'package.json'));
const { chromium } = require('playwright');

const DEV = process.env.INTRO_DEV_SERVER ?? 'http://localhost:5173';
const OUT = resolve(process.cwd(), 'docs', 'opening-sequence', 'frame-golden.json');

/** The design unit the fixture is generated for: 1920x1080 -> min/100. */
const U = 10.8;

/** The instants: a 0.05 s grid, plus every cue boundary. */
const CUES = [
  0, 0.12, 0.62, 0.74, 0.8, 0.92, 1.12, 1.24, 1.42, 1.58, 1.95, 2.57, 2.75,
];
const TIMES = new Set();
for (let i = 0; i <= 59; i++) TIMES.add(Number((i * 0.05).toFixed(2)));
for (const c of CUES) TIMES.add(c);
const instants = [...TIMES].sort((a, b) => a - b);

const num = (s) => {
  const v = parseFloat(s);
  if (!Number.isFinite(v)) throw new Error(`not a number: ${s}`);
  return v;
};
const between = (s, re, what) => {
  const m = s.match(re);
  if (!m) throw new Error(`no ${what} in ${s}`);
  return num(m[1]);
};

const parse = (t, f) => ({
  t,
  icon: {
    scale: between(f.icon.transform, /scale\(([-\d.]+)\)/, 'scale'),
    rotationDeg: between(f.icon.transform, /rotate\(([-\d.]+)deg\)/, 'rotation'),
    opacity: num(f.icon.opacity),
  },
  iconGlow: { opacity: num(f.iconGlow.opacity) },
  w1: {
    blurPx: f.w1.filter === 'none' ? null : between(f.w1.filter, /blur\(([-\d.]+)px\)/, 'blur'),
    letters: f.w1.letters.map((l) => ({
      translateYEm: between(l.transform, /translateY\(([-\d.]+)em\)/, 'translateY'),
      opacity: num(l.opacity),
    })),
  },
  w2: {
    blurPx: f.w2.filter === 'none' ? null : between(f.w2.filter, /blur\(([-\d.]+)px\)/, 'blur'),
    letters: f.w2.letters.map((l) => ({
      translateYEm: between(l.transform, /translateY\(([-\d.]+)em\)/, 'translateY'),
      opacity: num(l.opacity),
    })),
  },
  sub: {
    letterSpacingEm: num(f.sub.letterSpacing),
    opacity: num(f.sub.opacity),
    blurPx: f.sub.filter === 'none' ? null : between(f.sub.filter, /blur\(([-\d.]+)px\)/, 'blur'),
  },
  rule: { scaleX: between(f.rule.transform, /scaleX\(([-\d.]+)\)/, 'scaleX') },
  veilL: {
    translatePct: between(f.veilL.transform, /translate3d\(([-\d.]+)%/, 'translate'),
    featherPct: between(f.veilL.mask, /#000 ([-\d.]+)%/, 'feather'),
  },
  veilR: {
    translatePct: between(f.veilR.transform, /translate3d\(([-\d.]+)%/, 'translate'),
    featherPct: between(f.veilR.mask, /#000 ([-\d.]+)%/, 'feather'),
  },
  seam: { opacity: num(f.seam.opacity) },
  vignette: { opacity: num(f.vignette.opacity) },
  grain: { opacity: num(f.grain.opacity) },
  lockup: {
    translateXPx: between(f.lockup.transform, /translate\(([-\d.]+)px,/, 'translateX'),
    translateYPx: between(f.lockup.transform, /translate\([-\d.]+px,([-\d.]+)px\)/, 'translateY'),
    scale: between(f.lockup.transform, /scale\(([-\d.]+)\)/, 'scale'),
    opacity: num(f.lockup.opacity),
  },
  shake: { x: f.shake.x, y: f.shake.y },
});

const browser = await chromium.launch({ args: ['--disable-gpu'] });
const page = await browser.newPage();
try {
  await page.goto(`${DEV}/e2e/intro-harness.html`, { waitUntil: 'domcontentloaded' });
  const raw = await page.evaluate(
    async ({ times, u }) => {
      const mod = await import('/src/lib/intro/frame.ts');
      return times.map((t) => mod.computeFrame(t, { u, reduced: false }));
    },
    { times: instants, u: U },
  );
  const frames = raw.map((f, i) => parse(instants[i], f));
  const out = {
    _comment: [
      'The canonical frame, for every sampled instant.',
      '',
      'It is generated from the CANONICAL implementation - the web renderer, which',
      'is pixel-identical to the archived original - and it records the values that',
      'implementation RENDERED, parsed out of the strings it wrote to the DOM.',
      '',
      'The Flutter client computes the same frame and is asserted against this file',
      'by flutter_client/test/features/intro/intro_frame_golden_test.dart.',
      '',
      "`u` is the design unit the fixture was generated for: 1920x1080 -> ${U}.",
      "Every field except the lockup's vertical travel is independent of it.",
    ],
    u: U,
    frames,
  };
  writeFileSync(OUT, JSON.stringify(out, null, 1) + '\n');
  console.log(`wrote ${OUT} - ${frames.length} instants`);
} finally {
  await browser.close();
}
