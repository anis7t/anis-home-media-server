/**
 * The brand opening sequence - timeline and maths.
 *
 * This is a faithful port of the archived canonical source,
 * `docs/opening-sequence/source/intro-overlay.html`. Every constant and every
 * helper below carries the source line it came from, because the source is
 * the authority: the canonical specification
 * (`docs/OPENING_SEQUENCE.md` Part I) says the source wins on any
 * disagreement, and the frame-for-frame oracle compares this code against
 * that file directly.
 *
 * Everything in this module is PURE. No DOM, no canvas, no clock, no
 * `Math.random`. The camera shake is deterministic here on purpose - the
 * original used `Math.random()`, which is what made a reproducible frame
 * oracle impossible (decision D9).
 */

// ── Section 1. the timeline (source 276-278) ───────────────────────────────────

export const T = {
  streak: 0.12,
  impact: 0.62,
  sheen: 0.74,
  w1: 0.8,
  w2: 0.92,
  sub: 1.24,
  rule: 1.42,
  settle: 1.58,
  curtain: 1.95,
  curtainEnd: 2.75,
} as const;

export const DURATION = 3.0;

/** The layer hands the app back at `curtain + 0.62` (source 840, 190). */
export const HANDOVER_AT = T.curtain + 0.62;

// ── Section 0. small math (source 250-258) ────────────────────────────────────

export const clamp = (v: number, a: number, b: number): number => (v < a ? a : v > b ? b : v);

export const lerp = (a: number, b: number, t: number): number => a + (b - a) * t;

export const eOutCubic = (t: number): number => 1 - Math.pow(1 - t, 3);

export const eOutQuint = (t: number): number => 1 - Math.pow(1 - t, 5);

export const eInOutCubic = (t: number): number =>
  t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;

export const eOutBack = (t: number): number => {
  const c1 = 1.9;
  const c3 = c1 + 1;
  return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2);
};

/** Progress of `t` through the window `[a, b]` (source 257). */
export const seg = (t: number, a: number, b: number): number =>
  b <= a ? (t >= b ? 1 : 0) : clamp((t - a) / (b - a), 0, 1);

/**
 * The source's PRNG (source 258).
 *
 * Note the shape: the whole body is INSIDE the returned closure, so `a` is
 * incremented and the mixing is redone on every call. Hoisting the
 * initialisation out of the closure - the obvious "tidier" port - produces a
 * completely different sequence, and every particle in the sequence then lands
 * somewhere else.
 */
export const mulberry32 = (seed: number): (() => number) => {
  let a = seed;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
};

// ── The seeded particle fields (source 341-347) ───────────────────────────────
//
// These are seeded once, from a fixed sequence, so they are identical on every
// run and on every machine. They are the reason the FX are reproducible.

export type Rgb = [number, number, number];

export interface ConvergingParticle {
  /** Angle around the mark. */
  a: number;
  /** Start radius, as a fraction of the stage diagonal. */
  r0: number;
  /** Stroke width. */
  s: number;
  /** Speed, and how bright the streak is. */
  sp: number;
  c: Rgb;
}

export interface Ember {
  x: number;
  y: number;
  s: number;
  c: Rgb;
  sp: number;
  ph: number;
  f: number;
  dx: number;
}

const pickColor = (v: number): Rgb =>
  v < 0.66 ? [255, 255, 255] : v < 0.9 ? [255, 64, 84] : [120, 190, 255];

const buildConverging = (): ConvergingParticle[] => {
  const out: ConvergingParticle[] = [];
  for (let i = 0; i < 170; i++) {
    const r = mulberry32(i * 2654435761 + 7);
    out.push({
      a: r() * Math.PI * 2,
      r0: 0.42 + 0.72 * r(),
      s: 0.7 + 2.1 * r(),
      sp: 0.55 + 0.9 * r(),
      c: pickColor(r()),
    });
  }
  return out;
};

const buildEmbers = (): Ember[] => {
  const out: Ember[] = [];
  for (let i = 0; i < 64; i++) {
    const r = mulberry32(i * 97531 + 13);
    out.push({
      x: r(),
      y: r(),
      s: 0.5 + 1.6 * r(),
      c: pickColor(r()),
      sp: 5 + 16 * r(),
      ph: r() * 6.283,
      f: 0.5 + 1.7 * r(),
      dx: 0.3 + 0.7 * r(),
    });
  }
  return out;
};

export const CONV: ConvergingParticle[] = buildConverging();
export const EMB: Ember[] = buildEmbers();

// ── The camera shake (source 541-544) - made deterministic (decision D9) ──────
//
// The original did `shakeX = (Math.random() * 2 - 1) * amp`, so two runs of the
// same `t` never agreed and no frame could ever be a byte oracle. The
// amplitude curve is unchanged; only the source of randomness is replaced, by a
// hash of the (millisecond-quantised) time.

const SHAKE_AMPLITUDE = 9;

/** A deterministic 0..1 hash of an integer, salted. */
const hash01 = (n: number, salt: number): number => {
  let x = Math.imul(n ^ salt, 0x27d4eb2d) >>> 0;
  x ^= x >>> 15;
  x = Math.imul(x, 0x85ebca6b) >>> 0;
  x ^= x >>> 13;
  x = Math.imul(x, 0xc2b2ae35) >>> 0;
  x ^= x >>> 16;
  return (x >>> 0) / 4294967296;
};

export interface Shake {
  x: number;
  y: number;
}

/**
 * The two random draws the camera shake makes at time `t`.
 *
 * The original drew them from `Math.random()` (source 543), which is why two
 * runs of the same instant never agreed and no frame could be a byte oracle
 * (decision D9). These are the same two draws, from a hash of the time
 * instead, so the FORM of the shake is untouched and only its source of
 * randomness changes.
 *
 * They are exported because the frame-for-frame oracle needs them: it makes
 * the archived original produce the SAME shake, by handing these two values
 * to the original's `Math.random`, so that the shake window can be compared
 * too rather than being skipped.
 */
export const shakeDraws = (t: number): [number, number] => {
  const ms = Math.round(t * 1000);
  return [hash01(ms, 0x9e3779b9), hash01(ms, 0x85ebca6b)];
};

/**
 * The camera shake at time `t`.
 *
 * Zero outside the impact window, and bounded by 9 px inside it, exactly as
 * the original. Deterministic: the same `t` always yields the same offsets.
 */
export const shakeAt = (t: number, reduced: boolean): Shake => {
  if (reduced || t < T.impact || t >= T.impact + 0.42) return { x: 0, y: 0 };
  const sq = 1 - seg(t, T.impact, T.impact + 0.42);
  const amp = SHAKE_AMPLITUDE * sq * sq;
  const [r1, r2] = shakeDraws(t);
  return { x: (r1 * 2 - 1) * amp, y: (r2 * 2 - 1) * amp };
};
