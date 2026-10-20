// Capture the canonical PRNG and the deterministic camera shake.
import { mulberry32, shakeAt } from './src/lib/intro/timeline.ts';

const seeds = [0, 1, 7, 13, 2654435761 * 3 + 7, 2654435761 * 169 + 7,
  97531 * 63 + 13, 123456789, 4294967295, -1];
const streams = [];
for (const seed of seeds) {
  const r = mulberry32(seed);
  const vals = [];
  for (let i = 0; i < 12; i++) vals.push(r());
  streams.push([seed, vals]);
}

// The particle fields, which are the reason the PRNG's exactness matters.
const CONV = [];
for (let i = 0; i < 170; i++) {
  const r = mulberry32(i * 2654435761 + 7);
  // The draw order is the canonical's: angle, radius, width, speed, COLOUR.
  const a = r() * Math.PI * 2;
  const r0 = 0.42 + 0.72 * r();
  const s = 0.7 + 2.1 * r();
  const sp = 0.55 + 0.9 * r();
  const cv = r();
  const c = cv < 0.66 ? [255, 255, 255] : cv < 0.9 ? [255, 64, 84] : [120, 190, 255];
  CONV.push([a, r0, s, sp, c]);
}
const EMB = [];
for (let i = 0; i < 64; i++) {
  const r = mulberry32(i * 97531 + 13);
  // The draw order is the canonical's: x, y, size, COLOUR, speed, phase,
  // frequency, drift. The colour is the fourth draw - miss it and every
  // field after it is off by one.
  const x = r();
  const y = r();
  const s = 0.5 + 1.6 * r();
  const cv = r();
  const c = cv < 0.66 ? [255, 255, 255] : cv < 0.9 ? [255, 64, 84] : [120, 190, 255];
  const sp = 5 + 16 * r();
  const ph = r() * 6.283;
  const f = 0.5 + 1.7 * r();
  const dx = 0.3 + 0.7 * r();
  EMB.push([x, y, s, c, sp, ph, f, dx]);
}

const shakes = [];
for (let ms = 600; ms < 1050; ms += 7) {
  const s = shakeAt(ms / 1000, false);
  shakes.push([ms / 1000, s.x, s.y]);
}

console.log(JSON.stringify({ streams, CONV, EMB, shakes }));
